import XCTest
@testable import FoldwallCore

final class SystemWallpaperAccessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL.temporaryDirectory.appending(path: "foldwall-access-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try FileManager.default.removeItem(at: root)
    }

    func testReadableDirectoryIsGranted() {
        XCTAssertEqual(SystemWallpaperAccess.check(directory: root), .granted)
    }

    func testMissingContainerNeedsNothing() throws {
        XCTAssertEqual(SystemWallpaperAccess.check(directory: root.appending(path: "missing")), .notNeeded)
        let file = root.appending(path: "file")
        try Data().write(to: file)
        XCTAssertEqual(SystemWallpaperAccess.check(directory: file), .notNeeded)
    }

    func testUnreadableDirectoryIsDenied() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        XCTAssertEqual(SystemWallpaperAccess.check(directory: root), .denied)
    }

    func testDefaultLocationIsTheImageExtensionCache() throws {
        let home = root.appending(path: "home")
        XCTAssertEqual(SystemWallpaperAccess.check(home: home), .notNeeded)
        try FileManager.default.createDirectory(
            at: WallpaperImageCache.defaultDirectory(home: home), withIntermediateDirectories: true)
        XCTAssertEqual(SystemWallpaperAccess.check(home: home), .granted)
    }
}
