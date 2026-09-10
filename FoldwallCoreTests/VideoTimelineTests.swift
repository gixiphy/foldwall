import CoreMedia
import XCTest
@testable import FoldwallCore

/// 時間軸的驗收重點：**多輪之後不能有累積空隙、重疊或漂移**，
/// 而且長度推不出來時不可以憑空押一個值。
final class VideoTimelineTests: XCTestCase {

    // MARK: - 工具

    /// 24 fps，一格 1/24 秒。
    private static let frame24 = CMTime(value: 1, timescale: 24)

    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 24000)
    }

    /// 走完一輪固定幀率的片源，回傳這一輪送出的每一格。
    @discardableResult
    private func playOneLoop(
        _ timeline: inout LoopTimeline,
        start: CMTime,
        frameCount: Int,
        frameDuration: CMTime,
        sampleDuration: CMTime? = nil
    ) -> [RetimedSample] {
        (0 ..< frameCount).map { index in
            let pts = CMTimeAdd(start, CMTimeMultiply(frameDuration, multiplier: Int32(index)))
            return timeline.admit(pts: pts, dts: pts,
                                  duration: sampleDuration ?? frameDuration)
        }
    }

    // MARK: - 起點正規化

    func testFirstLoopOfAZeroStartTrackNeedsNoRetiming() {
        var timeline = LoopTimeline(track: VideoTrackTiming(
            start: .zero, duration: CMTime(value: 2, timescale: 1),
            nominalFrameDuration: Self.frame24))

        let samples = playOneLoop(&timeline, start: .zero, frameCount: 48,
                                  frameDuration: Self.frame24)

        XCTAssertEqual(timeline.offset, .zero)
        XCTAssertFalse(samples[0].needsRetiming,
                       "偏移是 0 的時候不該逼呼叫端去複製一份 sample")
        XCTAssertEqual(samples[0].presentationTimeStamp, .zero)
    }

    /// 這是舊程式碼的錯：起點非零時，第一輪原樣送出，
    /// 第二輪就整個往後推了「起點」那麼長。
    func testNonZeroTrackStartIsMappedToZeroOnTheFirstLoop() {
        let start = CMTime(value: 1, timescale: 2)   // 0.5 秒
        var timeline = LoopTimeline(track: VideoTrackTiming(
            start: start, duration: CMTime(value: 2, timescale: 1),
            nominalFrameDuration: Self.frame24))

        let samples = playOneLoop(&timeline, start: start, frameCount: 48,
                                  frameDuration: Self.frame24)

        XCTAssertTrue(samples[0].needsRetiming)
        XCTAssertEqual(samples[0].presentationTimeStamp.seconds, 0, accuracy: 1e-9,
                       "第一格必須落在輸出時間軸的 0，否則 timebase 從 0 起跑會判定它遲到")
        XCTAssertEqual(timeline.lastEnqueuedEnd.seconds, 2.0, accuracy: 1e-9)
    }

    func testSecondLoopContinuesWithoutAGapOrOverlap() {
        let start = CMTime(value: 1, timescale: 2)
        var timeline = LoopTimeline(track: VideoTrackTiming(
            start: start, duration: CMTime(value: 2, timescale: 1),
            nominalFrameDuration: Self.frame24))

        playOneLoop(&timeline, start: start, frameCount: 48, frameDuration: Self.frame24)
        XCTAssertTrue(timeline.advanceToNextLoop())

        let second = playOneLoop(&timeline, start: start, frameCount: 48,
                                 frameDuration: Self.frame24)

        XCTAssertEqual(second[0].presentationTimeStamp.seconds, 2.0, accuracy: 1e-9,
                       "第二輪的第一格要正好接在第一輪的結束時間上")
    }

    func testTwentyLoopsAccumulateNoDrift() {
        let start = CMTime(value: 1, timescale: 2)
        let duration = CMTime(value: 2, timescale: 1)
        var timeline = LoopTimeline(track: VideoTrackTiming(
            start: start, duration: duration, nominalFrameDuration: Self.frame24))

        for _ in 0 ..< 20 {
            playOneLoop(&timeline, start: start, frameCount: 48, frameDuration: Self.frame24)
            XCTAssertTrue(timeline.advanceToNextLoop())
        }

        XCTAssertEqual(timeline.loopBase.seconds, 40.0, accuracy: 1e-9,
                       "20 輪 × 2 秒＝40 秒。差一格都代表每輪都在漏或重疊。")
        XCTAssertEqual(timeline.lastLoopDrift, .zero,
                       "實際蓋到的範圍與宣告長度一致時漂移應該是 0")
    }

    // MARK: - 一格多長

    func testSampleDurationWins() {
        var timeline = LoopTimeline(track: VideoTrackTiming(
            start: .zero, duration: CMTime(value: 1, timescale: 1),
            nominalFrameDuration: Self.frame24))

        let sample = timeline.admit(pts: .zero, dts: .zero,
                                    duration: CMTime(value: 1, timescale: 30))

        XCTAssertFalse(sample.durationWasDerived)
        XCTAssertEqual(sample.end.seconds, 1.0 / 30.0, accuracy: 1e-9)
    }

    /// 舊程式碼在這裡押 1/60。片源是 24 fps 的話每一格就多算了 1/40 秒。
    func testMissingSampleDurationFallsBackToTheTrackNotToOneSixtieth() {
        var timeline = LoopTimeline(track: VideoTrackTiming(
            start: .zero, duration: CMTime(value: 1, timescale: 1),
            nominalFrameDuration: Self.frame24))

        let sample = timeline.admit(pts: .zero, dts: .zero, duration: .invalid)

        XCTAssertTrue(sample.durationWasDerived)
        XCTAssertEqual(sample.end.seconds, 1.0 / 24.0, accuracy: 1e-9)
        XCTAssertNotEqual(sample.end.seconds, 1.0 / 60.0, accuracy: 1e-12)
    }

    func testMissingDurationAndNoTrackInfoFallsBackToObservedInterval() {
        var timeline = LoopTimeline(track: VideoTrackTiming(
            start: .zero, duration: CMTime(value: 1, timescale: 1)))

        // 前幾格沒有長度也沒有窗口，只能原地結束；窗口填起來之後就推得出 1/24。
        for index in 0 ..< 6 {
            let pts = CMTimeMultiply(Self.frame24, multiplier: Int32(index))
            _ = timeline.admit(pts: pts, dts: pts, duration: .invalid)
        }
        let seventh = timeline.admit(
            pts: CMTimeMultiply(Self.frame24, multiplier: 6),
            dts: CMTimeMultiply(Self.frame24, multiplier: 6), duration: .invalid)

        XCTAssertTrue(seventh.durationWasDerived)
        XCTAssertEqual(CMTimeSubtract(seventh.end, seventh.presentationTimeStamp).seconds,
                       1.0 / 24.0, accuracy: 1e-9,
                       "軌道沒給幀率時要用觀察到的呈現間隔，不能用解碼順序相鄰 PTS 相減")
    }

    func testFirstSampleWithNoDurationAnywhereDoesNotInventOne() {
        var timeline = LoopTimeline(track: VideoTrackTiming(
            start: .zero, duration: .invalid))

        let sample = timeline.admit(pts: .zero, dts: .zero, duration: .invalid)

        XCTAssertEqual(sample.end, sample.presentationTimeStamp,
                       "推不出來就是推不出來。押一個值只會讓每一輪都錯一點。")
        XCTAssertTrue(sample.durationWasDerived)
        XCTAssertEqual(timeline.derivedDurationCount, 1)
    }

    // MARK: - B-frame 與壞掉的時間戳

    func testLoopEndTakesTheMaximumNotTheLastDecodedSample() {
        var timeline = LoopTimeline(track: VideoTrackTiming(
            start: .zero, duration: CMTime(value: 1, timescale: 1),
            nominalFrameDuration: Self.frame24))

        // 解碼順序 I P B：P 的 PTS 在 B 後面。
        let i = CMTime(value: 0, timescale: 24)
        let p = CMTime(value: 2, timescale: 24)
        let b = CMTime(value: 1, timescale: 24)
        _ = timeline.admit(pts: i, dts: i, duration: Self.frame24)
        _ = timeline.admit(pts: p, dts: CMTime(value: 1, timescale: 24), duration: Self.frame24)
        _ = timeline.admit(pts: b, dts: CMTime(value: 2, timescale: 24), duration: Self.frame24)

        XCTAssertEqual(timeline.lastEnqueuedEnd.seconds, 3.0 / 24.0, accuracy: 1e-9,
                       "呈現順序的最後一格是 P，不是解碼順序最後進來的 B")
    }

    func testDecodeTimestampsGetTheSameOffsetAsPresentation() {
        var timeline = LoopTimeline(track: VideoTrackTiming(
            start: .zero, duration: CMTime(value: 1, timescale: 1),
            nominalFrameDuration: Self.frame24))
        playOneLoop(&timeline, start: .zero, frameCount: 24, frameDuration: Self.frame24)
        timeline.advanceToNextLoop()

        let pts = CMTime(value: 2, timescale: 24)
        let dts = CMTime(value: 1, timescale: 24)
        let sample = timeline.admit(pts: pts, dts: dts, duration: Self.frame24)

        XCTAssertEqual(CMTimeSubtract(sample.presentationTimeStamp, sample.decodeTimeStamp),
                       CMTimeSubtract(pts, dts),
                       "PTS 與 DTS 的間距就是解碼重排序的距離，偏移必須一視同仁")
    }

    func testSamplesWithoutAPresentationTimestampDoNotPoisonTheTimeline() {
        var timeline = LoopTimeline(track: VideoTrackTiming(
            start: .zero, duration: CMTime(value: 1, timescale: 1),
            nominalFrameDuration: Self.frame24))
        playOneLoop(&timeline, start: .zero, frameCount: 24, frameDuration: Self.frame24)
        let before = timeline.lastEnqueuedEnd

        _ = timeline.admit(pts: .invalid, dts: .invalid, duration: .invalid)

        XCTAssertEqual(timeline.lastEnqueuedEnd, before)
        XCTAssertTrue(timeline.lastEnqueuedEnd.isNumeric)
    }

    func testInvalidTrackDurationIsTreatedAsUnknownNotAsZero() {
        let track = VideoTrackTiming(start: .zero, duration: CMTime(seconds: -3, preferredTimescale: 600))
        XCTAssertFalse(track.hasKnownDuration)
        XCTAssertFalse(track.end.isNumeric)
    }

    // MARK: - 換輪

    func testAnEmptyLoopStillAdvancesSoThePipelineCannotSpin() {
        var timeline = LoopTimeline(track: VideoTrackTiming(
            start: .zero, duration: CMTime(value: 2, timescale: 1),
            nominalFrameDuration: Self.frame24))

        let advanced = timeline.advanceToNextLoop()

        XCTAssertFalse(advanced, "一格都沒讀到就不是正常結束，呼叫端要知道")
        XCTAssertEqual(timeline.loopBase.seconds, 2.0, accuracy: 1e-9,
                       "還是得往前，否則下一輪整個蓋在這一輪上面")
    }

    func testShortLoopRecordsDriftAgainstTheDeclaredDuration() {
        var timeline = LoopTimeline(track: VideoTrackTiming(
            start: .zero, duration: CMTime(value: 2, timescale: 1),
            nominalFrameDuration: Self.frame24))

        // 只有 47 格：實際蓋到 47/24 秒，宣告是 2 秒。
        playOneLoop(&timeline, start: .zero, frameCount: 47, frameDuration: Self.frame24)
        timeline.advanceToNextLoop()

        XCTAssertEqual(timeline.lastLoopDrift.seconds, 47.0 / 24.0 - 2.0, accuracy: 1e-9)
        XCTAssertLessThan(timeline.lastLoopDrift.seconds, 0)
    }

    func testRebaseClearsEverything() {
        var timeline = LoopTimeline(track: VideoTrackTiming(
            start: CMTime(value: 1, timescale: 2), duration: CMTime(value: 2, timescale: 1),
            nominalFrameDuration: Self.frame24))
        playOneLoop(&timeline, start: CMTime(value: 1, timescale: 2), frameCount: 48,
                    frameDuration: Self.frame24)
        timeline.advanceToNextLoop()

        timeline.rebase(to: VideoTrackTiming(start: .zero, duration: CMTime(value: 5, timescale: 1)))

        XCTAssertEqual(timeline.loopBase, .zero)
        XCTAssertEqual(timeline.lastEnqueuedEnd, .zero)
        XCTAssertEqual(timeline.loopCount, 0)
        XCTAssertEqual(timeline.offset, .zero)
    }

    // MARK: - 恢復位置

    /// 舊程式碼把累積時間直接當檔案內的 seek 位置，播過第一輪之後
    /// 那個值就超出檔長了。
    func testResumePositionIsFileRelativeNotAccumulated() {
        let start = CMTime(value: 1, timescale: 2)
        var timeline = LoopTimeline(track: VideoTrackTiming(
            start: start, duration: CMTime(value: 2, timescale: 1),
            nominalFrameDuration: Self.frame24))

        for _ in 0 ..< 3 {
            playOneLoop(&timeline, start: start, frameCount: 48, frameDuration: Self.frame24)
            timeline.advanceToNextLoop()
        }
        // 第四輪播到一半：輸出時間軸 6.0 + 0.75 = 6.75。
        let position = timeline.filePosition(forTimelineTime: seconds(6.75))

        XCTAssertEqual(position.seconds, 0.5 + 0.75, accuracy: 1e-6,
                       "檔案裡的位置是「這一輪過了多久」加上軌道起點")
        XCTAssertLessThan(position.seconds, 2.5, "不可以超出檔尾")
    }

    func testResumePositionNearTheEndRestartsFromTheTrackStart() {
        let track = VideoTrackTiming(start: .zero, duration: CMTime(value: 2, timescale: 1),
                                     nominalFrameDuration: Self.frame24)
        let timeline = LoopTimeline(track: track)

        XCTAssertEqual(timeline.filePosition(forTimelineTime: seconds(1.999)), .zero,
                       "剩不到一格的內容，seek 過去只會立刻 EOF")
    }

    func testResumePositionOutOfRangeFallsBackToTheStart() {
        let track = VideoTrackTiming(start: CMTime(value: 1, timescale: 2),
                                     duration: CMTime(value: 2, timescale: 1))
        let timeline = LoopTimeline(track: track)

        XCTAssertEqual(timeline.filePosition(forTimelineTime: seconds(-5)), track.start)
        XCTAssertEqual(timeline.filePosition(forTimelineTime: .invalid), track.start)
    }

    func testResumeReadingRealignsTheTimeline() {
        let start = CMTime(value: 1, timescale: 2)
        var timeline = LoopTimeline(track: VideoTrackTiming(
            start: start, duration: CMTime(value: 2, timescale: 1),
            nominalFrameDuration: Self.frame24))
        playOneLoop(&timeline, start: start, frameCount: 48, frameDuration: Self.frame24)
        timeline.advanceToNextLoop()

        // 在輸出時間軸 2.75 暫停 → 檔案位置 1.25 → 從那裡接著讀。
        let resumeAt = seconds(2.75)
        let position = timeline.filePosition(forTimelineTime: resumeAt)
        timeline.resumeReading(atFilePosition: position, timelineTime: resumeAt)

        let next = timeline.admit(pts: position, dts: position, duration: Self.frame24)
        XCTAssertEqual(next.presentationTimeStamp.seconds, 2.75, accuracy: 1e-6,
                       "接著讀的第一格要落在暫停的那個時刻，不能跳回 0 也不能往前跳一段")
    }

    // MARK: - 可變幀率

    func testConstantFrameRateIsNotFlaggedAsVariable() {
        var estimator = PresentationIntervalEstimator()
        for index in 0 ..< 12 {
            estimator.note(CMTimeMultiply(Self.frame24, multiplier: Int32(index)))
        }
        XCTAssertFalse(estimator.looksVariable)
        XCTAssertEqual(estimator.estimate?.seconds ?? 0, 1.0 / 24.0, accuracy: 1e-9)
    }

    func testUnevenIntervalsAreFlaggedAsVariable() {
        var estimator = PresentationIntervalEstimator()
        var time = CMTime.zero
        for index in 0 ..< 12 {
            estimator.note(time)
            // 一格、一格、兩格……交錯
            let step = index % 3 == 2
                ? CMTimeMultiply(Self.frame24, multiplier: 2)
                : Self.frame24
            time = CMTimeAdd(time, step)
        }
        XCTAssertTrue(estimator.looksVariable)
    }

    func testEstimatorIgnoresDecodeOrderReordering() {
        var estimator = PresentationIntervalEstimator()
        // 解碼順序 0, 2, 1, 4, 3 …：相鄰相減會是負的，排序之後才是一格。
        for pts in [0, 2, 1, 4, 3, 6, 5] {
            estimator.note(CMTimeMultiply(Self.frame24, multiplier: Int32(pts)))
        }
        XCTAssertEqual(estimator.estimate?.seconds ?? 0, 1.0 / 24.0, accuracy: 1e-9)
    }
}
