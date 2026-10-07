// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RadaresCore

final class WarnPolicyTests: XCTestCase {
    func testTheDesignTable() {
        let table: [(Double, Double)] = [(50, 347.2), (80, 555.6), (90, 625), (100, 694.4), (120, 833.3), (144, 1000)]
        for (kmh, metres) in table {
            XCTAssertEqual(WarnPolicy.warnDistance(speed: kmh / 3.6), metres, accuracy: 0.1, "\(kmh) km/h")
        }
    }

    func testClampEdges() {
        XCTAssertEqual(WarnPolicy.warnDistance(speed: 0), Thresholds.warnFloorM)
        XCTAssertEqual(WarnPolicy.warnDistance(speed: 30 / 3.6), Thresholds.warnFloorM, "a 30 zone would be 208 m at 25 s")
        XCTAssertEqual(WarnPolicy.warnDistance(speed: 11.99), Thresholds.warnFloorM)
        XCTAssertEqual(WarnPolicy.warnDistance(speed: 12.01), 300.25, accuracy: 0.01)
        XCTAssertEqual(WarnPolicy.warnDistance(speed: 200 / 3.6), Thresholds.warnCapM)
        XCTAssertEqual(WarnPolicy.warnDistance(speed: -5), Thresholds.warnFloorM)
    }

    func testMedianIgnoresOneSpikyFix() {
        XCTAssertEqual(WarnPolicy.medianSpeed([30, 90, 31]), 31)
        XCTAssertEqual(WarnPolicy.medianSpeed([30, 31, 0]), 30)
        XCTAssertEqual(WarnPolicy.medianSpeed([10, 20, 30, 31, 32]), 31, "only the last three count")
    }

    func testMedianOfFewerSpeeds() {
        XCTAssertNil(WarnPolicy.medianSpeed([]))
        XCTAssertEqual(WarnPolicy.medianSpeed([20]), 20)
        XCTAssertEqual(WarnPolicy.medianSpeed([20, 30]), 25)
    }
}
