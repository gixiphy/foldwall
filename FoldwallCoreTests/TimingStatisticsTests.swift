import CoreMedia
import XCTest
@testable import FoldwallCore

final class TimingStatisticsTests: XCTestCase {

    private static let frame24 = CMTime(value: 1, timescale: 24)

    private func sample(_ frameIndex: Int, duration: CMTime? = frame24,
                        timescale: Int32 = 24) -> VideoAnalyzer.SampleTiming {
        VideoAnalyzer.SampleTiming(
            presentationTimeStamp: CMTime(value: CMTimeValue(frameIndex), timescale: timescale),
            duration: duration)
    }

    private func constant(_ count: Int) -> [VideoAnalyzer.SampleTiming] {
        (0 ..< count).map { sample($0) }
    }

    // MARK: - 固定幀率

    func testConstantFrameRateIsNotReportedAsVariable() {
        let analysis = TimingStatistics.analyze(constant(48))

        XCTAssertEqual(analysis.sampleCount, 48)
        XCTAssertFalse(analysis.isVariableFrameRate)
        XCTAssertEqual(analysis.medianIntervalSeconds ?? 0, 1.0 / 24.0, accuracy: 1e-9)
        XCTAssertEqual(analysis.samplesMissingDuration, 0)
        XCTAssertEqual(analysis.nonMonotonicPresentationCount, 0)
        XCTAssertFalse(analysis.hasBFrames)
    }

    func testFirstAndLastCoverTheWholeTrack() {
        let analysis = TimingStatistics.analyze(constant(24))

        XCTAssertEqual(analysis.firstPresentationSeconds ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(analysis.lastPresentationEndSeconds ?? 0, 1.0, accuracy: 1e-9,
                       "最後一格的結尾是它的 PTS 加它自己的長度")
    }

    // MARK: - 可變幀率

    func testUnevenIntervalsAreReportedAsVariable() {
        var samples = constant(12)
        // 抽掉一格 → 那個位置的間隔變成兩倍。
        samples.remove(at: 5)
        let analysis = TimingStatistics.analyze(samples)

        XCTAssertTrue(analysis.isVariableFrameRate)
        XCTAssertEqual(analysis.maxIntervalSeconds ?? 0, 2.0 / 24.0, accuracy: 1e-9)
        XCTAssertEqual(analysis.minIntervalSeconds ?? 0, 1.0 / 24.0, accuracy: 1e-9)
    }

    /// 23.976 在 24000 時基下每格是 1001，換算過去會有整數誤差。
    /// 那不是可變幀率。
    func testTimescaleRoundingIsNotMistakenForVariableFrameRate() {
        let samples = (0 ..< 48).map {
            VideoAnalyzer.SampleTiming(
                presentationTimeStamp: CMTime(value: CMTimeValue(1001 * $0), timescale: 24000),
                duration: CMTime(value: 1001, timescale: 24000))
        }
        XCTAssertFalse(TimingStatistics.analyze(samples).isVariableFrameRate)
    }

    // MARK: - B-frame 與壞掉的時間戳

    /// 解碼順序裡 PTS 往回走是**正常的**。記下來是因為它影響循環終點怎麼算，
    /// 不是因為它有問題。
    func testDecodeOrderReorderingIsReportedAsBFramesNotAsBroken() {
        let samples = [0, 2, 1, 4, 3, 6, 5].map { sample($0) }
        let analysis = TimingStatistics.analyze(samples)

        XCTAssertTrue(analysis.hasBFrames)
        XCTAssertEqual(analysis.nonMonotonicPresentationCount, 0,
                       "重排序不是壞掉的時間戳，兩者不能混為一談")
        XCTAssertFalse(analysis.isVariableFrameRate)
    }

    /// 兩格宣稱在同一時刻呈現——這個才是壞掉的。
    func testDuplicatePresentationTimesAreCountedAsBroken() {
        let samples = [0, 1, 1, 2, 3, 3, 3].map { sample($0) }
        let analysis = TimingStatistics.analyze(samples)

        XCTAssertEqual(analysis.nonMonotonicPresentationCount, 3,
                       "1 重複一次、3 重複兩次")
    }

    // MARK: - 缺長度

    func testSamplesWithoutADurationAreCounted() {
        var samples = constant(10)
        samples[3].duration = nil
        samples[7].duration = nil
        XCTAssertEqual(TimingStatistics.analyze(samples).samplesMissingDuration, 2)
    }

    func testLastSampleWithoutADurationFallsBackToTheTrack() {
        var samples = constant(10)
        samples[9].duration = nil
        let analysis = TimingStatistics.analyze(samples, nominalFrameDuration: Self.frame24)

        XCTAssertEqual(analysis.lastPresentationEndSeconds ?? 0, 10.0 / 24.0, accuracy: 1e-9)
    }

    func testLastSampleWithNoDurationAnywhereFallsBackToTheMeasuredMedian() {
        var samples = constant(10)
        samples[9].duration = nil
        let analysis = TimingStatistics.analyze(samples)

        XCTAssertEqual(analysis.lastPresentationEndSeconds ?? 0, 10.0 / 24.0, accuracy: 1e-6,
                       "量到的中位間隔是最後一層退路，不能押 1/60")
    }

    func testASingleSampleHasNoIntervalsAtAll() {
        let analysis = TimingStatistics.analyze([sample(0)])

        XCTAssertEqual(analysis.sampleCount, 1)
        XCTAssertNil(analysis.medianIntervalSeconds, "一格算不出間隔，就不要編一個出來")
        XCTAssertFalse(analysis.isVariableFrameRate)
    }

    func testEmptyInputIsSafe() {
        let analysis = TimingStatistics.analyze([])
        XCTAssertEqual(analysis.sampleCount, 0)
        XCTAssertNil(analysis.firstPresentationSeconds)
        XCTAssertNil(analysis.lastPresentationEndSeconds)
    }

    func testInvalidPresentationTimesAreIgnoredNotCountedAsZero() {
        var samples = constant(6)
        samples.append(VideoAnalyzer.SampleTiming(presentationTimeStamp: .invalid, duration: nil))
        let analysis = TimingStatistics.analyze(samples)

        XCTAssertEqual(analysis.sampleCount, 7)
        XCTAssertEqual(analysis.firstPresentationSeconds ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(analysis.maxIntervalSeconds ?? 0, 1.0 / 24.0, accuracy: 1e-9,
                       "無效的 PTS 不能被當成 0 而在統計裡生出一個巨大的間隔")
    }

    // MARK: - 接到分類

    func testAnalysisFeedsTheRiskClassification() {
        var samples = constant(24)
        samples.remove(at: 5)
        samples[0].duration = nil

        var profile = VideoSourceProfile(sourceKey: "x")
        profile.isLocal = true
        profile.timing = TimingStatistics.analyze(samples)

        let risks = profile.risks(screenRefreshHz: 60)
        XCTAssertTrue(risks.contains(.variableFrameRate))
        XCTAssertTrue(risks.contains(.missingSampleDurations))
        XCTAssertFalse(risks.contains(.unknownTiming))
    }
}
