// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RadaresCore

final class DrivingDetectorTests: XCTestCase {
    let p = Coordinate.at(41.3, -1.9)

    func fix(_ seconds: Double, speed: Double?, stationary: Bool = false) -> Fix {
        makeFix(p, t: t0.addingTimeInterval(seconds), speed: speed, course: 0, stationary: stationary)
    }

    func testThreeFastFixesStartADrive() {
        var d = DrivingDetector()
        XCTAssertEqual(d.ingest(fix(0, speed: 7)), .none)
        XCTAssertEqual(d.ingest(fix(1, speed: 2)), .none, "a slow fix does not count")
        XCTAssertEqual(d.ingest(fix(2, speed: 7)), .none)
        XCTAssertEqual(d.ingest(fix(3, speed: 6)), .started)
        XCTAssertEqual(d.phase, .driving)
        XCTAssertEqual(d.ingest(fix(4, speed: 30)), .none)
    }

    func testStationaryResetsTheCountAndPausesADrive() {
        var d = DrivingDetector()
        _ = d.ingest(fix(0, speed: 7))
        _ = d.ingest(fix(1, speed: 7))
        XCTAssertEqual(d.ingest(fix(2, speed: 0, stationary: true)), .none)
        XCTAssertEqual(d.ingest(fix(3, speed: 7)), .none, "the count restarted")
        _ = d.ingest(fix(4, speed: 7))
        XCTAssertEqual(d.ingest(fix(5, speed: 7)), .started)
        XCTAssertEqual(d.ingest(fix(6, speed: 0, stationary: true)), .paused)
        XCTAssertEqual(d.phase, .paused(since: t0.addingTimeInterval(6)))
    }

    func testTwoMinutesUnderOneMetrePerSecondPauses() {
        var d = DrivingDetector()
        for s in 0..<3 { _ = d.ingest(fix(Double(s), speed: 10)) }
        for s in 3..<122 { XCTAssertEqual(d.ingest(fix(Double(s), speed: 0.5)), .none, "\(s)") }
        XCTAssertEqual(d.ingest(fix(123, speed: 0.5)), .paused)

        var jam = DrivingDetector()
        for s in 0..<3 { _ = jam.ingest(fix(Double(s), speed: 10)) }
        for s in 3..<100 { _ = jam.ingest(fix(Double(s), speed: 0.5)) }
        XCTAssertEqual(jam.ingest(fix(100, speed: 2)), .none, "a creep resets the slow clock")
        for s in 101..<220 { XCTAssertEqual(jam.ingest(fix(Double(s), speed: 0.5)), .none, "\(s)") }
    }

    func testResumeWithinTenMinutesContinuesTheDrive() {
        var d = DrivingDetector()
        for s in 0..<3 { _ = d.ingest(fix(Double(s), speed: 10)) }
        XCTAssertEqual(d.ingest(fix(3, speed: 0, stationary: true)), .paused)
        XCTAssertEqual(d.ingest(fix(200, speed: 2)), .none, "under 3 m/s is not a resume")
        XCTAssertEqual(d.ingest(fix(9 * 60, speed: 4)), .resumed)
        XCTAssertEqual(d.phase, .driving)
    }

    func testResumeAfterTenMinutesEndsTheDrive() {
        var d = DrivingDetector()
        for s in 0..<3 { _ = d.ingest(fix(Double(s), speed: 10)) }
        _ = d.ingest(fix(3, speed: 0, stationary: true))
        XCTAssertEqual(d.ingest(fix(11 * 60, speed: 8)), .ended)
        XCTAssertEqual(d.phase, .idle)
        XCTAssertEqual(d.ingest(fix(11 * 60 + 1, speed: 8)), .none)
        XCTAssertEqual(d.ingest(fix(11 * 60 + 2, speed: 8)), .started, "the fast fix that ended the pause counts toward the re-probe")
    }
}
