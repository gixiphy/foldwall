import XCTest
@testable import FoldwallCore

final class VideoBufferPolicyTests: XCTestCase {

    private let localFile = URL(filePath: "/Users/x/Movies/a.mp4")
    private let mounted = URL(filePath: "/Volumes/NAS/Movies/a.mp4")
    private let stream = URL(string: "https://example.com/a.mp4")!

    func testHttpIsAlwaysAStream() {
        XCTAssertEqual(VideoBufferPolicy.location(for: stream, isLocalVolume: true), .remoteStream,
                       "http 網址不會因為卷資訊說什麼就變成本機檔")
        XCTAssertEqual(VideoBufferPolicy.location(for: stream, isLocalVolume: nil), .remoteStream)
    }

    func testFilesOnALocalVolumeAreLocal() {
        XCTAssertEqual(VideoBufferPolicy.location(for: localFile, isLocalVolume: true), .localDisk)
    }

    /// 掛載的 SMB 看起來就是個檔案路徑。誤判成本機就是播到一半卡住。
    func testFilesOnAMountedVolumeAreNetworked() {
        XCTAssertEqual(VideoBufferPolicy.location(for: mounted, isLocalVolume: false), .networkVolume)
    }

    /// 猜錯的代價不對稱：把網路當本機會卡住，把本機當網路只是多預讀一點。
    func testUnknownVolumeIsTreatedAsNetworked() {
        XCTAssertEqual(VideoBufferPolicy.location(for: mounted, isLocalVolume: nil), .networkVolume)
    }

    func testLocalBuffersLessThanNetwork() {
        let local = VideoBufferPolicy.forwardBufferSeconds(for: .localDisk)
        let network = VideoBufferPolicy.forwardBufferSeconds(for: .networkVolume)
        let stream = VideoBufferPolicy.forwardBufferSeconds(for: .remoteStream)

        XCTAssertLessThan(local, network, "本機檔預讀 10 秒是拿記憶體換不會用到的進度")
        XCTAssertGreaterThan(network, 10, "10 秒擋不住一次 SMB 抽風——那是舊的固定值")
        XCTAssertGreaterThan(stream, 10)
    }

    func testEveryLocationHasAPositiveBudgetAndAName() {
        for location in VideoSourceLocation.allCases {
            XCTAssertGreaterThan(VideoBufferPolicy.forwardBufferSeconds(for: location), 0)
            XCTAssertFalse(location.displayName.isEmpty)
        }
    }

    func testOnlyLocalDiskCountsAsNotNetworked() {
        XCTAssertFalse(VideoSourceLocation.localDisk.isNetworked)
        XCTAssertTrue(VideoSourceLocation.networkVolume.isNetworked)
        XCTAssertTrue(VideoSourceLocation.remoteStream.isNetworked)
    }
}
