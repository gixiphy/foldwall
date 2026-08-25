import XCTest
@testable import FoldwallCore

final class SourceRuleTests: XCTestCase {

    // MARK: - 條件

    func testBatteryRuleOnlyFiresOnBattery() {
        let rule = SourceRule(condition: .onBattery, effects: .disableRemote)
        XCTAssertEqual(SourceRuleEngine.effects(rules: [rule], context: RuleContext(onBattery: true)),
                       .disableRemote)
        XCTAssertEqual(SourceRuleEngine.effects(rules: [rule], context: RuleContext(onBattery: false)),
                       [])
    }

    func testFocusRuleMatchesSpecificMode() {
        let rule = SourceRule(condition: .focusMode("com.apple.focus.work"), effects: .pauseVideo)
        let working = RuleContext(activeFocusModeID: "com.apple.focus.work")
        let personal = RuleContext(activeFocusModeID: "com.apple.focus.personal-time")

        XCTAssertEqual(SourceRuleEngine.effects(rules: [rule], context: working), .pauseVideo)
        XCTAssertEqual(SourceRuleEngine.effects(rules: [rule], context: personal), [])
    }

    func testAnyFocusMatchesEveryMode() {
        let rule = SourceRule(condition: .anyFocus, effects: .pauseRotation)
        XCTAssertEqual(
            SourceRuleEngine.effects(rules: [rule],
                                     context: RuleContext(activeFocusModeID: "com.apple.sleep.sleep-mode")),
            .pauseRotation)
        XCTAssertEqual(SourceRuleEngine.effects(rules: [rule], context: RuleContext()), [],
                       "沒開專注模式就不該成立")
    }

    func testDisabledRuleIsIgnored() {
        let rule = SourceRule(condition: .onBattery, effects: .pauseVideo, isEnabled: false)
        XCTAssertEqual(SourceRuleEngine.effects(rules: [rule], context: RuleContext(onBattery: true)), [])
    }

    /// 多條同時成立就聯集：「任一條說要停，就停」比優先序好預測。
    func testMultipleMatchingRulesUnionTheirEffects() {
        let rules = [
            SourceRule(condition: .onBattery, effects: [.disableRemote, .disableFolders]),
            SourceRule(condition: .focusMode("com.apple.focus.work"), effects: .pauseVideo),
        ]
        let context = RuleContext(onBattery: true, activeFocusModeID: "com.apple.focus.work")
        XCTAssertEqual(SourceRuleEngine.effects(rules: rules, context: context),
                       [.disableRemote, .disableFolders, .pauseVideo])
    }

    func testActiveRulesReportsWhichOnesFired() {
        let battery = SourceRule(condition: .onBattery, effects: .disableRemote)
        let work = SourceRule(condition: .focusMode("com.apple.focus.work"), effects: .pauseVideo)
        let active = SourceRuleEngine.activeRules(rules: [battery, work],
                                                  context: RuleContext(onBattery: true))
        XCTAssertEqual(active.map(\.id), [battery.id])
    }

    func testNoRulesMeansNoEffects() {
        XCTAssertEqual(SourceRuleEngine.effects(rules: [], context: RuleContext(onBattery: true)), [])
    }

    /// 設定要長期躺在 UserDefaults 裡，格式得是穩定且看得懂的形狀——
    /// 不能是 Swift 預設那個綁編譯器實作的 `{"focusMode":{"_0":"..."}}`。
    func testConditionEncodesToStableShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let battery = try encoder.encode(RuleCondition.onBattery)
        XCTAssertEqual(String(decoding: battery, as: UTF8.self), #"{"type":"onBattery"}"#)

        let work = try encoder.encode(RuleCondition.focusMode("com.apple.focus.work"))
        XCTAssertEqual(String(decoding: work, as: UTF8.self),
                       #"{"mode":"com.apple.focus.work","type":"focusMode"}"#)
    }

    func testRulesSurviveEncoding() throws {
        let rules = [
            SourceRule(condition: .onBattery, effects: [.disableRemote, .pauseRotation]),
            SourceRule(condition: .focusMode("com.apple.focus.work"), effects: .pauseVideo),
            SourceRule(condition: .anyFocus, effects: []),
        ]
        let data = try JSONEncoder().encode(rules)
        XCTAssertEqual(try JSONDecoder().decode([SourceRule].self, from: data), rules)
    }
}

/// 專注模式的檔案格式沒有任何保證——這組測試用的是 2026-08-25 從
/// macOS 26.6.2 實機抓下來的真實結構。macOS 改格式時這裡會先紅。
final class FocusModeParserTests: XCTestCase {

    func testParsesModeNamesFromRealStructure() {
        let data = Data("""
        {"data":[{"modeConfigurations":{
          "com.apple.focus.work":{"mode":{"name":"工作","modeIdentifier":"com.apple.focus.work"}},
          "com.apple.sleep.sleep-mode":{"mode":{"name":"睡眠"}},
          "com.apple.donotdisturb.mode.default":{"mode":{"name":"Do Not Disturb"}}}}],
         "header":{"version":8}}
        """.utf8)
        let modes = FocusModeParser.modes(configurations: data)
        XCTAssertEqual(modes.count, 3)
        XCTAssertEqual(modes.first { $0.id == "com.apple.focus.work" }?.name, "工作")
    }

    func testMissingNameFallsBackToIdentifier() {
        let data = Data("""
        {"data":[{"modeConfigurations":{"com.apple.focus.custom":{"mode":{}}}}]}
        """.utf8)
        XCTAssertEqual(FocusModeParser.modes(configurations: data).first?.name,
                       "com.apple.focus.custom")
    }

    func testActiveModeComesFromAssertionRecords() {
        let data = Data("""
        {"data":[{"storeAssertionRecords":[
          {"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.work"}}]}]}
        """.utf8)
        XCTAssertEqual(FocusModeParser.activeModeID(assertions: data), "com.apple.focus.work")
    }

    /// 這條是實機踩出來的：檔案裡同時有 `storeInvalidationRecords`（**已結束**的歷史），
    /// 讀錯就會永遠以為某個模式還開著。實機當下沒開專注模式，該回 nil。
    func testInvalidationRecordsAreNotMistakenForActiveMode() {
        let data = Data("""
        {"data":[{"storeInvalidationRecords":[
          {"invalidationAssertion":{"assertionDetails":
            {"assertionDetailsModeIdentifier":"com.apple.focus.work"}}}],
          "storeInvalidationRequestRecords":[]}],
         "header":{"version":8}}
        """.utf8)
        XCTAssertNil(FocusModeParser.activeModeID(assertions: data),
                     "已結束的紀錄不是啟用中的模式")
    }

    /// 格式沒有保證：解不出來就當成「沒開專注模式」，不能讓桌布壞掉。
    func testGarbageIsToleratedNotFatal() {
        XCTAssertNil(FocusModeParser.activeModeID(assertions: Data("not json".utf8)))
        XCTAssertTrue(FocusModeParser.modes(configurations: Data("not json".utf8)).isEmpty)
        XCTAssertNil(FocusModeParser.activeModeID(assertions: Data()))
    }
}
