import XCTest
@testable import FoldwallCore

final class PowerPolicyTests: XCTestCase {

    func testTierTable() {
        let cases: [(thermal: ProcessInfo.ThermalState, battery: Bool, occluded: Bool, game: Bool, expected: PowerTier)] = [
            (.nominal, false, false, false, .full),
            (.fair,    false, false, false, .full),
            (.nominal, true,  false, false, .reduced),
            (.serious, false, false, false, .reduced),
            (.serious, true,  false, false, .reduced),
            (.critical, false, false, false, .paused),
            (.nominal, false, true,  false, .paused),
            (.nominal, false, false, true,  .paused),
            (.critical, true, true,  true,  .paused),
        ]

        for c in cases {
            XCTAssertEqual(
                PowerPolicy.tier(thermal: c.thermal, onBattery: c.battery,
                                 occluded: c.occluded, gameMode: c.game),
                c.expected,
                "thermal=\(c.thermal) battery=\(c.battery) occluded=\(c.occluded) game=\(c.game)"
            )
        }
    }

    func testPausedBeatsReduced() {
        XCTAssertEqual(
            PowerPolicy.tier(thermal: .serious, onBattery: true, occluded: true, gameMode: false),
            .paused,
            "暫停條件優先於降載"
        )
    }
}
