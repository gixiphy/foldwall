import XCTest
@testable import FoldwallCore

final class SchedulerTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func makeScheduler(minutes: Int = 5) -> Scheduler {
        Scheduler(intervalMinutes: minutes, now: start)
    }

    private func later(_ minutes: Double) -> Date {
        start.addingTimeInterval(minutes * 60)
    }

    // MARK: - 基本排程

    func testTickBeforeDueDoesNothing() {
        var s = makeScheduler()
        XCTAssertEqual(s.handle(.tick(now: later(1))), .none)
    }

    func testTickAtDueRefreshesAndReschedules() {
        var s = makeScheduler()
        XCTAssertEqual(s.handle(.tick(now: later(5))), .refresh)
        XCTAssertEqual(s.nextDue, later(10), "跑完要排下一輪")
        XCTAssertEqual(s.handle(.tick(now: later(6))), .none)
    }

    // MARK: - 暫停語意

    func testPausedTickDoesNothing() {
        var s = makeScheduler()
        _ = s.handle(.pause)
        XCTAssertEqual(s.handle(.tick(now: later(99))), .none, "暫停中排程不得換桌布")
    }

    func testNextWhilePausedIsSingleShotAndStaysPaused() {
        var s = makeScheduler()
        _ = s.handle(.pause)
        XCTAssertEqual(s.handle(.userNext(now: later(1))), .refresh, "暫停中按下一張仍應換一張")
        XCTAssertTrue(s.isPaused, "單發之後仍維持暫停")
        XCTAssertEqual(s.handle(.tick(now: later(99))), .none)
    }

    func testResumeRefreshesImmediately() {
        var s = makeScheduler()
        _ = s.handle(.pause)
        XCTAssertEqual(s.handle(.resume(now: later(3))), .refresh, "恢復要立即刷新一輪")
        XCTAssertFalse(s.isPaused)
        XCTAssertEqual(s.nextDue, later(8), "再回排程")
    }

    func testUserNextResetsCountdown() {
        var s = makeScheduler()
        XCTAssertEqual(s.handle(.userNext(now: later(2))), .refresh)
        XCTAssertEqual(s.nextDue, later(7), "手動換張後重新計時")
    }

    // MARK: - 睡醒 catch-up

    func testWakeBeforeDueDoesNotRefresh() {
        var s = makeScheduler(minutes: 1440)
        XCTAssertEqual(s.handle(.wake(now: later(60))), .none,
                       "選每天的人不該每次睡醒就被換桌布")
    }

    func testWakeAfterDueCatchesUp() {
        var s = makeScheduler(minutes: 5)
        XCTAssertEqual(s.handle(.wake(now: later(42))), .refresh, "睡過頭要補一輪")
        XCTAssertEqual(s.nextDue, later(47))
    }

    func testWakeWhilePausedDoesNothing() {
        var s = makeScheduler()
        _ = s.handle(.pause)
        XCTAssertEqual(s.handle(.wake(now: later(99))), .none)
    }

    // MARK: - 熱插拔與間隔

    func testScreensChangedRefreshesWithoutResettingCountdown() {
        var s = makeScheduler()
        XCTAssertEqual(s.handle(.screensChanged(now: later(2))), .refresh, "新螢幕要立刻有桌布")
        XCTAssertEqual(s.nextDue, later(5), "熱插拔不重設排程")
    }

    func testScreensChangedWhilePausedDoesNothing() {
        var s = makeScheduler()
        _ = s.handle(.pause)
        XCTAssertEqual(s.handle(.screensChanged(now: later(2))), .none)
    }

    func testIntervalChangeReschedulesFromNow() {
        var s = makeScheduler(minutes: 5)
        XCTAssertEqual(s.handle(.intervalChanged(minutes: 60, now: later(1))), .none)
        XCTAssertEqual(s.nextDue, later(61))
        XCTAssertEqual(s.handle(.tick(now: later(30))), .none)
        XCTAssertEqual(s.handle(.tick(now: later(61))), .refresh)
    }

    func testIntervalOptionsAreTheFixedFive() {
        XCTAssertEqual(Scheduler.intervalOptions, [5, 15, 30, 60, 1440])
    }
}

extension SchedulerTests {

    /// 選單與設定視窗共用同一份標籤，兩邊不會講不一樣的話。
    ///
    /// **不比對 `intervalLabel` 的回傳字面**：它跟著跑測試那台機器的語言走，
    /// 寫死中文的話在英文系統上會紅。字面改成鎖定語言直接查字串表，
    /// 兩種語言各鎖一次——少翻一條會退回中文，在這裡就會被抓到。
    func testIntervalLabelsAreHumanReadable() {
        XCTAssertEqual(coreString("%lld 分鐘", "zh-Hant"), "%lld 分鐘")
        XCTAssertEqual(coreString("%lld 分鐘", "en"), "%lld minutes")
        XCTAssertEqual(coreString("1 小時", "zh-Hant"), "1 小時")
        XCTAssertEqual(coreString("1 小時", "en"), "1 hour")
        XCTAssertEqual(coreString("每天", "zh-Hant"), "每天")
        XCTAssertEqual(coreString("每天", "en"), "Daily")

        // 三個分支確實各走各的，沒有兩個撞在一起
        XCTAssertEqual(Set([5, 60, 1440].map(Scheduler.intervalLabel)).count, 3)
    }

    func testEveryIntervalOptionHasALabel() {
        for minutes in Scheduler.intervalOptions {
            XCTAssertFalse(Scheduler.intervalLabel(minutes).isEmpty)
        }
    }

    func testEveryEffectHasADisplayName() {
        for effect in PostProcess.allCases {
            XCTAssertFalse(effect.displayName.isEmpty, "\(effect) 沒有可顯示的名稱")
        }
        XCTAssertEqual(coreString("灰階", "zh-Hant"), "灰階")
        XCTAssertEqual(coreString("灰階", "en"), "Grayscale")
    }

    /// 每一條中文都要有對應的英文，而且英文裡不能還留著中文。
    ///
    /// `String(localized:)` 查不到 key 就把 key 原樣回傳，而 key 是中文——
    /// 漏翻一條的症狀是「英文介面裡冒出一句中文」，不是壞掉，所以編譯與執行都不會抱怨。
    /// 這條測試是唯一會抓到它的地方。
    func testEveryCoreStringIsTranslatedToEnglish() throws {
        let zh = try table("zh-Hant")
        let en = try table("en")

        XCTAssertEqual(Set(zh.keys), Set(en.keys), "兩種語言的 key 必須一模一樣")
        for (key, value) in en {
            XCTAssertFalse(
                value.contains(where: \.isCJK),
                "「\(key)」的英文還是中文：\(value)")
        }
    }

    /// 每一條中文都要有對應的簡體，而且簡體裡不能還留著繁體字。
    ///
    /// 漏翻的症狀跟英文那條一樣安靜：查不到 key 就回傳 key，而 key 是繁體，
    /// 於是簡體介面裡冒出一句繁體。編譯與執行都不會抱怨。
    ///
    /// key 集合比對抓的是「整條沒翻」——沒有 zh-Hans 那一欄的字串
    /// 根本不會被編進 zh-Hans.strings。字元比對抓的是「翻一半」。
    func testEveryCoreStringIsTranslatedToSimplified() throws {
        let hant = try table("zh-Hant")
        let hans = try table("zh-Hans")

        // 不用 XCTAssertEqual 比兩個 Set：失敗訊息會把整份字串表印兩遍，
        // 真正少的那幾條反而找不到。
        let missing = Set(hant.keys).subtracting(hans.keys)
        XCTAssertTrue(missing.isEmpty, "這幾條沒有簡體：\(missing.sorted())")
        for (key, value) in hans {
            let leftovers = value.filter(Self.traditionalOnly.contains)
            XCTAssertTrue(
                leftovers.isEmpty,
                "「\(key)」的簡體還留著繁體字「\(leftovers)」：\(value)")
        }
    }

    /// 只在繁體用的字。不求完整——挑的是這個 app 的字串裡出現頻率最高的那些，
    /// 夠讓「複製繁體過去忘了改」當場失敗就行。
    private static let traditionalOnly: Set<Character> = [
        "個", "們", "來", "時", "後", "說", "讀", "點", "為", "與", "體", "麼",
        "樣", "機", "對", "從", "應", "當", "現", "發", "過", "進", "還", "連",
        "邊", "選", "錯", "錄", "長", "間", "際", "隨", "難", "電", "靜", "頁",
        "項", "預", "頭", "題", "類", "顯", "驗", "資", "夾", "檔", "螢", "網",
        "設", "統", "開", "關", "數", "圖", "備", "傳", "價", "兩", "區",
        "單", "圓", "實", "寫", "專", "尋", "層", "帳", "幾", "庫", "張", "強",
        "換", "擇", "斷", "書", "會", "東", "條", "業", "標", "權", "沒", "測",
        "滿", "無", "狀", "畫", "碼", "種", "稱", "筆", "紙", "組", "結", "給",
        "線", "縮", "總", "續", "舊", "蓋", "處", "號", "術", "補", "裝", "裡",
        "製", "見", "規", "視", "覽", "訊", "許", "詢", "試", "話", "該", "認",
        "誤", "請", "證", "護", "變", "讓", "負", "責", "費", "貼", "質", "軌",
        "載", "輪", "輸", "適", "遠", "釋", "鈕", "鋪", "鍵", "鎖", "鐘", "鑰",
        "閉", "階", "離", "雲", "響", "順", "須", "顆", "額", "飽", "齊", "齡",
    ]

    /// Core 的字串表在 framework 自己的 bundle 裡。
    ///
    /// **不能用 `String(localized:locale:)` 換語言**：那個 locale 只管數字與日期
    /// 怎麼格式化，查哪一份 .lproj 仍然跟著跑測試那台機器的系統語言走
    /// （實測傳 en 進去照樣回中文）。要指定語言只能自己開對應的 .lproj 子 bundle。
    private func coreString(_ key: String, _ language: String) -> String {
        guard let path = Bundle.foldwallCore.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return "找不到 \(language).lproj" }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    /// 整份字串表。編譯後的 .strings 是 binary plist，直接讀得出來。
    private func table(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(
            Bundle.foldwallCore.url(forResource: "Localizable", withExtension: "strings",
                                    subdirectory: "\(language).lproj"),
            "\(language) 的字串表沒有被建進 framework")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }
}

private extension Character {
    /// 中日韓統一表意文字。用來抓「英文欄位裡還留著中文」。
    var isCJK: Bool { unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
}
