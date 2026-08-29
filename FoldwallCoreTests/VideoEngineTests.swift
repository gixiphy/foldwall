import XCTest
@testable import FoldwallCore

final class VideoEngineTests: XCTestCase {

    /// 兩條路的差別必須是明確的旗標，不能靠散在各處的 if 判斷。
    func testOnlyTheExtensionNeedsDeploymentAndSupportsLockScreen() {
        XCTAssertFalse(VideoEngine.desktopWindow.needsDeployment,
                       "桌面視窗直接播來源檔，拷貝是那條路才有的成本")
        XCTAssertTrue(VideoEngine.systemExtension.needsDeployment)

        XCTAssertFalse(VideoEngine.desktopWindow.supportsLockScreen,
                       "鎖屏畫面不歸 app 管")
        XCTAssertTrue(VideoEngine.systemExtension.supportsLockScreen)
    }

    func testEveryEngineExplainsItself() {
        for engine in VideoEngine.allCases {
            XCTAssertFalse(engine.displayName.isEmpty)
            XCTAssertFalse(engine.summary.isEmpty)
        }
        XCTAssertTrue(VideoEngine.desktopWindow.summary.contains("鎖屏"),
                      "取捨要寫在使用者看得到的地方")
    }

    func testEnginesSurviveEncoding() throws {
        for engine in VideoEngine.allCases {
            let data = try JSONEncoder().encode(engine)
            XCTAssertEqual(try JSONDecoder().decode(VideoEngine.self, from: data), engine)
        }
        for layer in DesktopVideoLayer.allCases {
            let data = try JSONEncoder().encode(layer)
            XCTAssertEqual(try JSONDecoder().decode(DesktopVideoLayer.self, from: data), layer)
        }
    }
}

final class VideoScaleModeTests: XCTestCase {

    /// 使用者看得到的四個選項，名稱要跟「系統設定 → 桌布」對得上。
    func testEveryScaleModeExplainsItself() {
        for scale in VideoScaleMode.allCases {
            XCTAssertFalse(scale.displayName.isEmpty)
            XCTAssertFalse(scale.summary.isEmpty)
        }
        XCTAssertEqual(VideoScaleMode.fill.displayName, "填滿螢幕")
        XCTAssertEqual(VideoScaleMode.fit.displayName, "符合螢幕大小")
        XCTAssertEqual(VideoScaleMode.matchHeight.displayName, "填滿高度")
        XCTAssertEqual(VideoScaleMode.matchWidth.displayName, "填滿寬度")
    }

    /// **沒有拉扁那一種。** 桌布把每支影片都變形不是選項，所以「擴充至填滿螢幕」
    /// （0.6.3 短暫做過）已經移除，剩下的每一種都保持長寬比。
    func testNoModeDistortsTheVideo() {
        XCTAssertNil(VideoScaleMode(rawValue: "stretch"))
        XCTAssertFalse(VideoScaleMode.allCases.contains { $0.displayName.contains("擴充") })
    }

    /// 舊設定與舊備份裡還躺著 `"stretch"`。解不開的話整份設定會壞掉，
    /// 所以認不得的值一律當 `.fill`。
    func testUnknownRawValueDecodesAsFill() throws {
        let data = Data("\"stretch\"".utf8)
        XCTAssertEqual(try JSONDecoder().decode(VideoScaleMode.self, from: data), .fill)
    }

    /// `random` 不是一種縮放，是「從那三種抽一種」——不能出現在可抽的池裡，
    /// 否則抽到它就得再抽一次，遲早有人寫成無窮迴圈。
    func testRandomIsNotOneOfTheConcreteChoices() {
        XCTAssertEqual(VideoScaleMode.concrete, [.fill, .fit])
        XCTAssertFalse(VideoScaleMode.concrete.contains(.random))
        // 「填滿高度／寬度」對任何一支影片來說結果都是 fill 或 fit 其中之一，
        // 放進抽籤池只會改機率，不會多出一種看得出差別的畫面。
        XCTAssertFalse(VideoScaleMode.concrete.contains(.matchHeight))
        XCTAssertFalse(VideoScaleMode.concrete.contains(.matchWidth))
    }

    /// 「填滿高度」＝影片的高貼齊螢幕。影片比螢幕寬時左右會滿出去，那正是 aspectFill；
    /// 反過來留左右黑邊，那正是 aspectFit。這條等式是不用自己算 layer 框的理由。
    func testMatchHeightReducesToFillOnlyWhenTheVideoIsWider() {
        let ultrawide = 32.0 / 9      // 螢幕
        let cinema = 21.0 / 9         // 比 16:9 寬，但比螢幕窄
        let portrait = 9.0 / 16

        XCTAssertEqual(
            VideoScaleMode.matchHeight.resolved(videoAspect: 40.0 / 9, screenAspect: ultrawide),
            .fill, "比螢幕還寬 → 貼齊高度就會左右滿出去")
        XCTAssertEqual(
            VideoScaleMode.matchHeight.resolved(videoAspect: cinema, screenAspect: ultrawide),
            .fit, "比螢幕窄 → 貼齊高度會留左右黑邊")
        XCTAssertEqual(
            VideoScaleMode.matchHeight.resolved(videoAspect: portrait, screenAspect: ultrawide),
            .fit)
    }

    /// 「填滿寬度」是對稱的那一半。
    func testMatchWidthIsTheMirrorOfMatchHeight() {
        let screen = 16.0 / 10
        for video in [9.0 / 16, 1.0, 16.0 / 9, 32.0 / 9] {
            let height = VideoScaleMode.matchHeight.resolved(
                videoAspect: video, screenAspect: screen)
            let width = VideoScaleMode.matchWidth.resolved(
                videoAspect: video, screenAspect: screen)
            XCTAssertNotEqual(height, width,
                              "同一支影片不可能兩邊都貼齊又都滿出去（正方形螢幕除外）")
        }
    }

    /// 長寬比還不知道（第一格還沒解出來）時退回填滿——那是舊行為，
    /// 也是唯一不留黑邊的選擇。拿到比例再改一次 gravity 就好，不必重播。
    func testUnknownAspectFallsBackToFill() {
        XCTAssertEqual(
            VideoScaleMode.matchHeight.resolved(videoAspect: nil, screenAspect: 16.0 / 9), .fill)
        XCTAssertEqual(
            VideoScaleMode.matchWidth.resolved(videoAspect: 0, screenAspect: 16.0 / 9), .fill)
        XCTAssertEqual(
            VideoScaleMode.matchHeight.resolved(videoAspect: .nan, screenAspect: 16.0 / 9), .fill)
        XCTAssertEqual(
            VideoScaleMode.matchWidth.resolved(videoAspect: 1.5, screenAspect: 0), .fill)
    }

    /// 其他模式不受長寬比影響——化簡只針對「填滿高度／寬度」。
    func testOtherModesIgnoreAspectRatios() {
        for scale in [VideoScaleMode.fill, .fit, .random] {
            XCTAssertEqual(scale.resolved(videoAspect: 9.0 / 16, screenAspect: 32.0 / 9), scale)
        }
        XCTAssertFalse(VideoScaleMode.fill.needsVideoAspect)
        XCTAssertTrue(VideoScaleMode.matchHeight.needsVideoAspect)
        XCTAssertTrue(VideoScaleMode.matchWidth.needsVideoAspect)
    }

    func testFixedModesResolveToThemselves() {
        for scale in VideoScaleMode.allCases where scale != .random {
            XCTAssertEqual(scale.resolved(seed: 1), scale)
            XCTAssertEqual(scale.resolved(seed: 999), scale, "固定的縮放不該看 seed")
        }
    }

    /// 同一支影片在同一台螢幕上永遠抽到同一種：畫面重新套用設定的時機很多，
    /// 每次重擲的話播到一半會突然換一種縮放。
    func testRandomIsStableForTheSameScreenAndVideo() {
        let seed = VideoScaleMode.seed(displayUUID: "SCREEN-1", video: "/videos/a.mp4")
        let first = VideoScaleMode.random.resolved(seed: seed)
        for _ in 0..<20 {
            XCTAssertEqual(VideoScaleMode.random.resolved(seed: seed), first)
        }
        XCTAssertTrue(VideoScaleMode.concrete.contains(first), "抽出來的必須是具體的縮放")
    }

    /// 不同影片要抽得出不同縮放，否則「隨機」等於固定一種。
    func testRandomVariesAcrossVideos() {
        let picks = Set((0..<50).map { index in
            VideoScaleMode.random.resolved(
                seed: VideoScaleMode.seed(displayUUID: "SCREEN-1",
                                          video: "/videos/\(index).mp4"))
        })
        XCTAssertGreaterThan(picks.count, 1)
    }

    /// 螢幕不同也要分得開：兩台播同一支時抽到一樣的話，多螢幕看起來就沒在隨機。
    func testSeedSeparatesScreenFromVideo() {
        XCTAssertNotEqual(
            VideoScaleMode.seed(displayUUID: "A", video: "BC"),
            VideoScaleMode.seed(displayUUID: "AB", video: "C"),
            "螢幕與影片之間要有分隔，不能直接字串相接")
        XCTAssertNotEqual(
            VideoScaleMode.seed(displayUUID: "SCREEN-1", video: "/videos/a.mp4"),
            VideoScaleMode.seed(displayUUID: "SCREEN-2", video: "/videos/a.mp4"))
    }

    func testScaleModesSurviveEncoding() throws {
        for scale in VideoScaleMode.allCases {
            let data = try JSONEncoder().encode(scale)
            XCTAssertEqual(try JSONDecoder().decode(VideoScaleMode.self, from: data), scale)
        }
    }
}

final class VideoPlaybackPlanTests: XCTestCase {

    private func video(_ name: String) -> URL { URL(filePath: "/videos/\(name)") }

    func testEveryMarkedScreenGetsSomethingToPlay() {
        let plan = VideoPlaybackPlan.assign(
            screens: ["A", "B"], videos: [video("1.mp4"), video("2.mp4")])
        XCTAssertEqual(Set(plan.keys), ["A", "B"])
    }

    /// 兩台螢幕不該播到同一部——那看起來像壞掉。
    func testTwoScreensGetDifferentVideos() {
        let plan = VideoPlaybackPlan.assign(
            screens: ["A", "B"], videos: [video("1.mp4"), video("2.mp4"), video("3.mp4")])
        XCTAssertNotEqual(plan["A"], plan["B"])
    }

    /// 只有一支影片時只能重複，但不能留空螢幕。
    func testSingleVideoIsReusedRatherThanLeavingAScreenBlank() {
        let plan = VideoPlaybackPlan.assign(screens: ["A", "B"], videos: [video("1.mp4")])
        XCTAssertEqual(plan["A"], video("1.mp4"))
        XCTAssertEqual(plan["B"], video("1.mp4"))
    }

    /// cycle 前進就換一批，這是「每次螢幕亮起看到新的」的來源。
    func testCycleShiftsTheSelection() {
        let videos = (1...4).map { video("\($0).mp4") }
        let first = VideoPlaybackPlan.assign(screens: ["A"], videos: videos, cycle: 0)
        let second = VideoPlaybackPlan.assign(screens: ["A"], videos: videos, cycle: 1)
        XCTAssertNotEqual(first["A"], second["A"])
    }

    func testStableOrderRegardlessOfInputOrder() {
        let videos = [video("b.mp4"), video("a.mp4"), video("c.mp4")]
        let forward = VideoPlaybackPlan.assign(screens: ["A"], videos: videos)
        let reversed = VideoPlaybackPlan.assign(screens: ["A"], videos: videos.reversed())
        XCTAssertEqual(forward, reversed, "順序不該影響播到哪一支")
    }

    // MARK: - 黏著：影片不跟著蒙太奇換

    /// 這條是回報的 bug：assign 的位置由池的**內容**決定，而池每輪都在變
    /// （下載落地、快取淘汰、索引重掃、失敗冷卻），所以 cycle 沒動影片也會被換掉。
    func testKeepingSurvivesPoolChanges() {
        let a = video("a.mp4"), b = video("b.mp4"), c = video("c.mp4")
        let current = ["S1": b]

        // 池多了一支、少了一支、順序也變了——正在播的那支仍在池裡就該續播
        let plan = VideoPlaybackPlan.keeping(
            current: current, screens: ["S1"], videos: [c, b, a], cycle: 0)
        XCTAssertEqual(plan["S1"], b, "還在池裡就繼續播，不要重新選")
    }

    func testKeepingReassignsWhenCurrentVideoIsGone() {
        let a = video("a.mp4"), b = video("b.mp4")
        let plan = VideoPlaybackPlan.keeping(
            current: ["S1": video("deleted.mp4")], screens: ["S1"], videos: [a, b])
        XCTAssertNotNil(plan["S1"])
        XCTAssertTrue([a, b].contains(plan["S1"]!), "原本那支不見了才重新選")
    }

    func testKeepingFillsScreensThatArePlayingNothing() {
        let a = video("a.mp4"), b = video("b.mp4")
        let plan = VideoPlaybackPlan.keeping(
            current: ["S1": a], screens: ["S1", "S2"], videos: [a, b])
        XCTAssertEqual(plan["S1"], a, "S1 續播")
        XCTAssertEqual(plan["S2"], b, "S2 拿沒被沿用的那支")
    }

    /// 兩台螢幕不該播到同一支——即使 current 裡兩台都記著同一支。
    func testKeepingDoesNotLetTwoScreensShareOneVideo() {
        let a = video("a.mp4"), b = video("b.mp4")
        let plan = VideoPlaybackPlan.keeping(
            current: ["S1": a, "S2": a], screens: ["S1", "S2"], videos: [a, b])
        XCTAssertNotEqual(plan["S1"], plan["S2"])
    }

    /// 只有一支影片時只能重複，但不能留空螢幕。
    func testKeepingReusesWhenThereIsOnlyOneVideo() {
        let a = video("a.mp4")
        let plan = VideoPlaybackPlan.keeping(
            current: ["S1": a], screens: ["S1", "S2"], videos: [a])
        XCTAssertEqual(plan["S1"], a)
        XCTAssertEqual(plan["S2"], a)
    }

    func testKeepingWithEmptyInputsIsSafe() {
        XCTAssertTrue(VideoPlaybackPlan.keeping(current: [:], screens: [], videos: [video("1.mp4")]).isEmpty)
        XCTAssertTrue(VideoPlaybackPlan.keeping(current: [:], screens: ["A"], videos: []).isEmpty)
    }

    func testEmptyInputsAreSafe() {
        XCTAssertTrue(VideoPlaybackPlan.assign(screens: [], videos: [video("1.mp4")]).isEmpty)
        XCTAssertTrue(VideoPlaybackPlan.assign(screens: ["A"], videos: []).isEmpty)
    }

    // MARK: - 播完接下一支

    /// 全部循環：照 absoluteString 的順序往前一步。
    func testRepeatAllWalksTheLibraryInOrder() {
        let videos = (1...3).map { video("\($0).mp4") }
        var current = videos[0]
        var seen = [current]
        for _ in 0..<2 {
            current = VideoPlaybackPlan.next(
                after: current, screen: "A", videos: videos, mode: .repeatAll)!
            seen.append(current)
        }
        XCTAssertEqual(seen, videos, "一支接一支，不跳號")
    }

    /// 走到底要回到第一支，不是停在那裡。
    func testRepeatAllWrapsAtTheEnd() {
        let videos = (1...3).map { video("\($0).mp4") }
        XCTAssertEqual(
            VideoPlaybackPlan.next(after: videos[2], screen: "A", videos: videos, mode: .repeatAll),
            videos[0])
    }

    /// 這台還沒在播（剛勾「此螢幕改用影片」）就從第一支開始——不是第二支。
    func testNextFromNothingStartsAtTheBeginning() {
        let videos = (1...3).map { video("\($0).mp4") }
        XCTAssertEqual(
            VideoPlaybackPlan.next(after: nil, screen: "A", videos: videos, mode: .repeatAll),
            videos[0])
    }

    /// 正在播的那支已經不在池裡（被刪、進冷卻）：從頭接，不要回 nil。
    func testNextRecoversWhenCurrentLeftThePool() {
        let videos = (1...3).map { video("\($0).mp4") }
        let next = VideoPlaybackPlan.next(
            after: video("deleted.mp4"), screen: "A", videos: videos, mode: .repeatAll)
        XCTAssertEqual(next, videos[0])
    }

    /// 別台螢幕正在播的要避開——兩台播同一支看起來像壞掉。
    func testNextAvoidsWhatAnotherScreenIsPlaying() {
        let videos = (1...3).map { video("\($0).mp4") }
        let next = VideoPlaybackPlan.next(
            after: videos[0], screen: "A", videos: videos,
            busy: [videos[1]], mode: .repeatAll)
        XCTAssertEqual(next, videos[2], "順位下一支被別台佔了就再往前一步")
    }

    /// 只有一支影片：只能重播它。重播好過黑畫面。
    func testNextRepeatsTheOnlyVideoRatherThanGivingUp() {
        let only = video("1.mp4")
        XCTAssertEqual(
            VideoPlaybackPlan.next(after: only, screen: "A", videos: [only], mode: .repeatAll),
            only)
        XCTAssertEqual(
            VideoPlaybackPlan.next(after: only, screen: "A", videos: [only], mode: .shuffle),
            only)
    }

    /// 池空了就回 nil，呼叫端維持現狀（不要拿 nil 當「停播」用）。
    func testNextWithAnEmptyPoolIsNil() {
        XCTAssertNil(VideoPlaybackPlan.next(
            after: video("1.mp4"), screen: "A", videos: [], mode: .shuffle))
    }

    /// 隨機不能抽到剛播完那支——連兩次同一支看起來像卡住。
    func testShuffleNeverPicksTheClipThatJustFinished() {
        let videos = (1...5).map { video("\($0).mp4") }
        for nonce in UInt64(0)..<50 {
            let next = VideoPlaybackPlan.next(
                after: videos[2], screen: "A", videos: videos, mode: .shuffle, nonce: nonce)
            XCTAssertNotEqual(next, videos[2])
        }
    }

    /// 同 nonce 同結果：測試要穩，不然這條規則沒人守得住。
    func testShuffleIsDeterministicForTheSameNonce() {
        let videos = (1...8).map { video("\($0).mp4") }
        let first = VideoPlaybackPlan.next(
            after: videos[0], screen: "A", videos: videos, mode: .shuffle, nonce: 42)
        let again = VideoPlaybackPlan.next(
            after: videos[0], screen: "A", videos: videos, mode: .shuffle, nonce: 42)
        XCTAssertEqual(first, again)
    }

    /// 隨機真的會散開，不是每次都同一支。
    func testShuffleActuallySpreadsAcrossTheLibrary() {
        let videos = (1...8).map { video("\($0).mp4") }
        let picks = Set((0..<40).map { nonce in
            VideoPlaybackPlan.next(after: videos[0], screen: "A", videos: videos,
                                   mode: .shuffle, nonce: UInt64(nonce))
        })
        XCTAssertGreaterThan(picks.count, 2, "抽 40 次只抽到兩支以內，那不叫隨機")
    }

    /// 兩台螢幕同時換片不該撞在一起。
    func testShuffleKeepsTwoScreensApart() {
        let videos = (1...6).map { video("\($0).mp4") }
        let a = VideoPlaybackPlan.next(
            after: videos[0], screen: "A", videos: videos, mode: .shuffle, nonce: 7)!
        let b = VideoPlaybackPlan.next(
            after: videos[1], screen: "B", videos: videos, busy: [a], mode: .shuffle, nonce: 7)
        XCTAssertNotEqual(a, b)
    }

    /// 單片循環也答得出「下一支」：播完不會問，但使用者按「下一片」時會。
    func testRepeatOneStillAnswersManualNext() {
        let videos = (1...3).map { video("\($0).mp4") }
        XCTAssertEqual(
            VideoPlaybackPlan.next(after: videos[0], screen: "A", videos: videos, mode: .repeatOne),
            videos[1])
    }
}

final class VideoPlaybackModeTests: XCTestCase {

    /// 只有單片循環走 AVPlayerLooper——這個旗標決定引擎怎麼建 player。
    func testOnlyRepeatOneStaysOnTheSameClip() {
        XCTAssertFalse(VideoPlaybackMode.repeatOne.advancesAtEnd)
        XCTAssertTrue(VideoPlaybackMode.repeatAll.advancesAtEnd)
        XCTAssertTrue(VideoPlaybackMode.shuffle.advancesAtEnd)
    }

    func testEveryModeExplainsItself() {
        for mode in VideoPlaybackMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
            XCTAssertFalse(mode.summary.isEmpty)
        }
    }

    func testModesSurviveEncoding() throws {
        for mode in VideoPlaybackMode.allCases {
            let data = try JSONEncoder().encode(mode)
            XCTAssertEqual(try JSONDecoder().decode(VideoPlaybackMode.self, from: data), mode)
        }
    }
}
