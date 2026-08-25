import XCTest
@testable import FoldwallCore

final class SmokeTests: XCTestCase {
    func testCoreLinks() {
        XCTAssertFalse(FoldwallCore.version.isEmpty)
    }
}
