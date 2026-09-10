import XCTest
@testable import FoldwallCore

final class VideoSourceProfileTests: XCTestCase {

    private func profile(fps: Double?, width: Int = 1920, height: Int = 1080) -> VideoSourceProfile {
        var value = VideoSourceProfile(sourceKey: "/tmp/a.mp4")
        value.nominalFrameRate = fps
        value.pixelWidth = width
        value.pixelHeight = height
        value.isLocal = true
        return value
    }

    // MARK: - 呈現節奏

    /// 這是「有些片正常、有些會抖」最常見的成因，而且**不是播放器故障**。
    func testTwentyFourFpsOnSixtyHertzIsFlaggedAsACadenceMismatch() {
        XCTAssertTrue(profile(fps: 24).risks(screenRefreshHz: 60).contains(.refreshCadenceMismatch))
        XCTAssertTrue(profile(fps: 25).risks(screenRefreshHz: 60).contains(.refreshCadenceMismatch))
    }

    func testEvenlyDividingFrameRatesAreNotFlagged() {
        XCTAssertFalse(profile(fps: 30).risks(screenRefreshHz: 60).contains(.refreshCadenceMismatch))
        XCTAssertFalse(profile(fps: 60).risks(screenRefreshHz: 60).contains(.refreshCadenceMismatch))
        XCTAssertFalse(profile(fps: 24).risks(screenRefreshHz: 120).contains(.refreshCadenceMismatch))
    }

    /// 29.97 播在 59.94 上是整除的，不能因為小數就誤判。
    func testBroadcastRatesAreTreatedAsMatching() {
        XCTAssertFalse(profile(fps: 29.97).risks(screenRefreshHz: 59.94).contains(.refreshCadenceMismatch))
        XCTAssertFalse(profile(fps: 23.976).risks(screenRefreshHz: 47.952).contains(.refreshCadenceMismatch))
    }

    func testFrameRateAboveRefreshIsItsOwnFinding() {
        let risks = profile(fps: 120).risks(screenRefreshHz: 60)
        XCTAssertTrue(risks.contains(.frameRateAboveRefresh))
        XCTAssertFalse(risks.contains(.refreshCadenceMismatch),
                       "高於更新率是另一回事，不要同時報兩種讓人不知道要看哪個")
    }

    /// 螢幕更新率不知道的時候**不要假設 60**——那會憑空生出一條錯的線索。
    func testUnknownRefreshRateProducesNoCadenceFinding() {
        let risks = profile(fps: 24).risks(screenRefreshHz: nil)
        XCTAssertFalse(risks.contains(.refreshCadenceMismatch))
        XCTAssertFalse(risks.contains(.frameRateAboveRefresh))
    }

    /// 播放進度正常不等於沒有掉幀。量不到就要說量不到。
    func testMissingTimingIsReportedAsUnknownNotAsHealthy() {
        var value = VideoSourceProfile(sourceKey: "x")
        value.isLocal = true
        XCTAssertTrue(value.risks(screenRefreshHz: 60).contains(.unknownTiming))
    }

    // MARK: - 時間戳

    func testTimingAnalysisDrivesTheTimestampFindings() {
        var value = profile(fps: 30)
        value.timing = VideoSourceProfile.TimingAnalysis(
            sampleCount: 300, medianIntervalSeconds: 1.0 / 30.0,
            isVariableFrameRate: true, samplesMissingDuration: 4,
            nonMonotonicPresentationCount: 2)

        let risks = value.risks(screenRefreshHz: 60)
        XCTAssertTrue(risks.contains(.variableFrameRate))
        XCTAssertTrue(risks.contains(.missingSampleDurations))
        XCTAssertTrue(risks.contains(.nonMonotonicTimestamps))
        XCTAssertFalse(risks.contains(.unknownTiming))
    }

    func testMeasuredIntervalOverridesTheDeclaredFrameRate() {
        var value = profile(fps: 60)
        value.timing = VideoSourceProfile.TimingAnalysis(
            sampleCount: 240, medianIntervalSeconds: 1.0 / 24.0)

        XCTAssertEqual(value.effectiveFrameRate ?? 0, 24, accuracy: 1e-6,
                       "容器宣告 60 但實際間隔是 24——要相信量到的那個")
        XCTAssertTrue(value.risks(screenRefreshHz: 60).contains(.refreshCadenceMismatch))
    }

    func testNonZeroTrackStartIsFlagged() {
        var value = profile(fps: 30)
        value.trackStartSeconds = 0.5
        XCTAssertTrue(value.risks(screenRefreshHz: 60).contains(.nonZeroTimelineStart))

        value.trackStartSeconds = 0
        XCTAssertFalse(value.risks(screenRefreshHz: 60).contains(.nonZeroTimelineStart))
    }

    // MARK: - 負載與來源

    func testOversizedOrHighBitrateSourcesAreFlagged() {
        XCTAssertTrue(profile(fps: 30, width: 7680, height: 4320)
            .risks(screenRefreshHz: 60).contains(.highDecodeLoad))

        var bitrate = profile(fps: 30)
        bitrate.estimatedDataRate = 80_000_000
        XCTAssertTrue(bitrate.risks(screenRefreshHz: 60).contains(.highDecodeLoad))

        XCTAssertFalse(profile(fps: 30).risks(screenRefreshHz: 60).contains(.highDecodeLoad))
    }

    func testRemoteAndHDRAreFlaggedSeparately() {
        var value = profile(fps: 30)
        value.isLocal = false
        value.isHDR = true
        let risks = value.risks(screenRefreshHz: 60)
        XCTAssertTrue(risks.contains(.remoteSource))
        XCTAssertTrue(risks.contains(.hdrTonemapping))
    }

    func testUnknownLocalityIsNotReportedAsRemote() {
        var value = VideoSourceProfile(sourceKey: "x")
        value.nominalFrameRate = 30
        XCTAssertFalse(value.risks(screenRefreshHz: 60).contains(.remoteSource))
    }

    func testEveryRiskExplainsItself() {
        for risk in PlaybackRisk.allCases {
            XCTAssertFalse(risk.summary.isEmpty)
        }
    }

    // MARK: - 長寬比與新鮮度

    func testDisplayAspectUsesTheRotatedSize() {
        var value = VideoSourceProfile(sourceKey: "x")
        value.pixelWidth = 1920
        value.pixelHeight = 1080
        value.displayWidth = 1080
        value.displayHeight = 1920
        XCTAssertEqual(value.displayAspect ?? 0, 1080.0 / 1920.0, accuracy: 1e-9,
                       "直拍影片的顯示尺寸是直的，不能拿 naturalSize 算")
    }

    func testDegenerateSizesGiveNoAspect() {
        var value = VideoSourceProfile(sourceKey: "x")
        value.displayWidth = 0
        value.displayHeight = 1080
        XCTAssertNil(value.displayAspect)
    }

    func testAnalysisGoesStaleWhenTheFileChanges() {
        var value = VideoSourceProfile(sourceKey: "x")
        let stamp = Date()
        value.fileSize = 1000
        value.contentModified = stamp
        value.analyzedAt = stamp

        XCTAssertTrue(value.isFresh(fileSize: 1000, contentModified: stamp))
        XCTAssertFalse(value.isFresh(fileSize: 2000, contentModified: stamp))
        XCTAssertFalse(value.isFresh(fileSize: 1000, contentModified: stamp.addingTimeInterval(60)))
    }

    func testNeverAnalyzedIsNeverFresh() {
        var value = VideoSourceProfile(sourceKey: "x")
        value.fileSize = 1000
        XCTAssertFalse(value.isFresh(fileSize: 1000, contentModified: nil))
    }

    func testProfileSurvivesEncoding() throws {
        var value = profile(fps: 24)
        value.codec = "hvc1"
        value.timing = VideoSourceProfile.TimingAnalysis(sampleCount: 10, hasBFrames: true)
        value.optimizedVariant = .init(filename: "optimized.mov", reason: .oversizedResolution)

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(VideoSourceProfile.self, from: data)
        XCTAssertEqual(decoded, value)
    }
}

final class PlaybackEventLogTests: XCTestCase {

    private func event(_ kind: PlaybackEvent.Kind, surface: String = "A",
                       at offset: TimeInterval) -> PlaybackEvent {
        PlaybackEvent(kind: kind, engine: "desktopWindow", surface: surface, session: 1,
                      at: Date(timeIntervalSince1970: offset))
    }

    func testTheLogHasACeilingAndSaysWhatItDropped() {
        var log = PlaybackEventLog(capacity: 4)
        for index in 0 ..< 10 {
            log.record(event(.loopBoundary, at: Double(index)))
        }
        XCTAssertEqual(log.all.count, 4, "桌布跑一整天，無上限的紀錄就是記憶體洩漏")
        XCTAssertEqual(log.droppedCount, 6)
        XCTAssertEqual(log.all.first?.at.timeIntervalSince1970, 6)
    }

    func testStallsArePairedWithTheirRecovery() {
        var log = PlaybackEventLog()
        log.record(event(.started, at: 0))
        log.record(event(.stalled, at: 10))
        log.record(event(.resumed, at: 13))
        log.record(event(.stalled, at: 20))
        log.record(event(.resumed, at: 21))

        let summary = log.stallSummary(surface: "A")
        XCTAssertEqual(summary.count, 2)
        XCTAssertEqual(summary.totalSeconds, 4, accuracy: 1e-9)
        XCTAssertEqual(summary.unmatched, 0)
    }

    /// 還在停頓中、或停頓期間換了片——那段長度是不知道的，不能當成 0。
    func testAnUnfinishedStallIsCountedAsUnmatchedNotAsZero() {
        var log = PlaybackEventLog()
        log.record(event(.stalled, at: 10))
        log.record(event(.switched, at: 12))
        log.record(event(.stalled, at: 20))

        let summary = log.stallSummary(surface: "A")
        XCTAssertEqual(summary.count, 0)
        XCTAssertEqual(summary.totalSeconds, 0)
        XCTAssertEqual(summary.unmatched, 2)
    }

    func testSurfacesAreKeptApart() {
        var log = PlaybackEventLog()
        log.record(event(.stalled, surface: "A", at: 10))
        log.record(event(.resumed, surface: "B", at: 11))
        log.record(event(.resumed, surface: "A", at: 15))

        XCTAssertEqual(log.events(surface: "A").count, 2)
        XCTAssertEqual(log.stallSummary(surface: "A").totalSeconds, 5, accuracy: 1e-9)
        XCTAssertEqual(log.stallSummary(surface: "B").count, 0)
    }

    func testCountsGroupByKind() {
        var log = PlaybackEventLog()
        log.record(event(.loopBoundary, at: 1))
        log.record(event(.loopBoundary, at: 2))
        log.record(event(.failed, at: 3))
        XCTAssertEqual(log.counts[.loopBoundary], 2)
        XCTAssertEqual(log.counts[.failed], 1)
    }
}
