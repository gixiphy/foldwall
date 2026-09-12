import CoreMedia
import XCTest
@testable import FoldwallCore

/// 一個 CMSampleBuffer 不等於一格。這組鎖住「空 buffer 不算格、多格 buffer 要展開」。
final class SampleBufferTimingTests: XCTestCase {

    private static let frame = CMTime(value: 1, timescale: 30)

    private func timing(_ frameIndex: Int, duration: CMTime = frame) -> CMSampleTimingInfo {
        CMSampleTimingInfo(duration: duration,
                           presentationTimeStamp: CMTime(value: CMTimeValue(frameIndex), timescale: 30),
                           decodeTimeStamp: .invalid)
    }

    /// AVAssetReader 在格式切換與檔尾會交出零格的 buffer，時間戳無效。
    /// 以前它被記成「一格、沒帶長度」，於是 VFR 與缺長度都誤報。
    func testAnEmptyBufferIsNotAFrame() {
        let empty = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid,
                                       decodeTimeStamp: .invalid)
        XCTAssertEqual(VideoAnalyzer.sampleTimings(sampleCount: 0, timings: [empty]), [])
        XCTAssertEqual(VideoAnalyzer.sampleTimings(sampleCount: 0, timings: []), [])
    }

    /// 就算有一格，沒給任何時間資訊也記不出東西——不編造。
    func testNoTimingInfoYieldsNothing() {
        XCTAssertEqual(VideoAnalyzer.sampleTimings(sampleCount: 1, timings: []), [])
    }

    func testOneSampleOneTiming() {
        let result = VideoAnalyzer.sampleTimings(sampleCount: 1, timings: [timing(7)])
        XCTAssertEqual(result, [VideoAnalyzer.SampleTiming(
            presentationTimeStamp: CMTime(value: 7, timescale: 30), duration: Self.frame)])
    }

    /// 一格一筆：照抄。
    func testPerSampleTimingsAreMappedOneToOne() {
        let result = VideoAnalyzer.sampleTimings(sampleCount: 3, timings: [timing(0), timing(2), timing(1)])
        XCTAssertEqual(result.map(\.presentationTimeStamp.value), [0, 2, 1], "保持解碼順序，B-frame 的重排要留給統計看")
        XCTAssertEqual(result.count, 3)
    }

    /// 一筆代表全部：CoreMedia 的契約是所有格同長度、時間戳連續，要展開成 N 格。
    /// 以前只記一格，格數少算、間隔統計也少一段。
    func testASharedTimingIsExpandedToEverySample() {
        let result = VideoAnalyzer.sampleTimings(sampleCount: 4, timings: [timing(10)])
        XCTAssertEqual(result.map(\.presentationTimeStamp.value), [10, 11, 12, 13])
        XCTAssertTrue(result.allSatisfy { $0.duration == Self.frame })
    }

    /// 一筆代表多格但沒帶長度：其他格的時間戳算不出來，只回第一格，不編等距值。
    func testASharedTimingWithoutADurationOnlyYieldsTheFirstSample() {
        let result = VideoAnalyzer.sampleTimings(sampleCount: 4, timings: [timing(10, duration: .invalid)])
        XCTAssertEqual(result, [VideoAnalyzer.SampleTiming(
            presentationTimeStamp: CMTime(value: 10, timescale: 30), duration: nil)])
    }

    /// 零長度跟沒帶長度一樣是「沒有」——`samplesMissingDuration` 要數得到它。
    func testZeroDurationCountsAsMissing() {
        let result = VideoAnalyzer.sampleTimings(sampleCount: 1, timings: [timing(0, duration: .zero)])
        XCTAssertNil(result.first?.duration)
    }

    /// 展開後餵進統計：四格等距不是 VFR，也沒有缺長度。以前的版本會把它算成一格。
    func testExpandedSamplesFeedTheStatisticsCorrectly() {
        let samples = VideoAnalyzer.sampleTimings(sampleCount: 4, timings: [timing(0)])
            + VideoAnalyzer.sampleTimings(sampleCount: 0, timings: [])
            + VideoAnalyzer.sampleTimings(sampleCount: 4, timings: [timing(4)])
        let analysis = TimingStatistics.analyze(samples)
        XCTAssertEqual(analysis.sampleCount, 8)
        XCTAssertEqual(analysis.samplesMissingDuration, 0)
        XCTAssertFalse(analysis.isVariableFrameRate)
    }
}
