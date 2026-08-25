import XCTest
@testable import FoldwallCore

final class SourceTestTests: XCTestCase {

    /// 空清單不是失敗：key 可能是對的，只是這個關鍵字沒東西。
    func testEmptyResultIsNotAFailure() {
        XCTAssertEqual(SourceTestResult.fromCount(0), .empty)
        XCTAssertEqual(SourceTestResult.fromCount(7), .passed(count: 7))
    }

    /// 之前填錯 key 的來源只會安靜地什麼都不給，要翻 log 才看得出來。
    func testMissingKeyReadsAsPlainLanguage() {
        let result = SourceTestResult.fromError(RemoteSourceError.missingKey(.pexels))
        XCTAssertEqual(result, .failed(reason: "缺少 API key"))
    }

    func testHTTPStatusesExplainThemselves() {
        for (code, expected) in [(401, "key 不對或沒有權限"), (404, "路由或網址不存在"),
                                 (429, "超出速率上限，稍後再試")] {
            let result = SourceTestResult.fromError(RemoteSourceError.httpStatus(code))
            guard case .failed(let reason) = result else { return XCTFail("\(code) 應為失敗") }
            XCTAssertTrue(reason.contains(expected), "\(code) 的說明沒講到重點：\(reason)")
        }
    }

    func testMalformedResponseHintsAtTheWrongURL() {
        let result = SourceTestResult.fromError(RemoteSourceError.malformedResponse(.rss))
        guard case .failed(let reason) = result else { return XCTFail() }
        XCTAssertTrue(reason.contains("不是這個來源的網址"))
    }

    func testOnlyFinishedStatesAreConclusive() {
        XCTAssertFalse(SourceTestResult.untested.isConclusive)
        XCTAssertFalse(SourceTestResult.testing.isConclusive)
        XCTAssertTrue(SourceTestResult.passed(count: 1).isConclusive)
        XCTAssertTrue(SourceTestResult.empty.isConclusive)
        XCTAssertTrue(SourceTestResult.failed(reason: "x").isConclusive)
    }

    func testEveryStateHasSymbolAndSummary() {
        let states: [SourceTestResult] = [.untested, .testing, .passed(count: 3), .empty,
                                          .failed(reason: "壞了")]
        for state in states {
            XCTAssertFalse(state.symbol.isEmpty)
            XCTAssertFalse(state.summary.isEmpty)
        }
    }
}
