// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RadaresCore

final class StretchTrackerTests: XCTestCase {
    let west = Coordinate.at(40.51793, 0.13277)
    let east = Coordinate.at(40.51235, 0.24688)

    func corridor(bearing: Double? = nil, role: Role = .mobileCorridor, bidirectional: Bool = true) -> Radar {
        makeRadar(id: "s", kind: .stretch, role: role, start: west, end: east, road: "N-232", kmFrom: 20.81, kmTo: 30.91, bearing: bearing, bidirectional: bidirectional, source: role == .mobileCorridor ? "dgt_invive" : "dgt")
    }

    /// Drives `fixes` through a fresh tracker and returns every change with the fix index.
    func run(_ radar: Radar, fixes: [Fix], speed: Double = 25) -> (changes: [(Int, StretchTracker.Change)], tracker: StretchTracker) {
        var tracker = StretchTracker()
        var out: [(Int, StretchTracker.Change)] = []
        for (i, f) in fixes.enumerated() {
            if let c = tracker.ingest(f, courseDegrees: f.course, warnDistance: WarnPolicy.warnDistance(speed: speed), speedMps: speed, candidates: [radar], now: f.timestamp) {
                out.append((i, c))
            }
        }
        return (out, tracker)
    }

    func testEntryNeedsTheCourseIntoTheStretch() {
        let into = Geo.bearing(from: west, to: east)
        let fixesIn = straightFixes(gate: west, course: into, speed: 25, metresBefore: 1000, metresAfter: 100)
        let (changes, tracker) = run(corridor(), fixes: fixesIn)
        guard case .entered(let radar, let gate, let approach, let level)? = changes.first?.1 else { return XCTFail("no entry") }
        XCTAssertEqual(radar.id, "s")
        XCTAssertEqual(gate, west)
        XCTAssertEqual(level, .full)
        XCTAssertLessThanOrEqual(approach.distanceMetres, 625)
        XCTAssertNotNil(tracker.inside)

        // Same gate, same closing approach, but the course points out of the stretch (a road crossing at the gate).
        let across = Geo.normalize(into + 90)
        let fixesAcross = straightFixes(gate: west, course: across, speed: 25, metresBefore: 1000, metresAfter: 100)
        XCTAssertTrue(run(corridor(), fixes: fixesAcross).changes.isEmpty)
    }

    func testCorridorEntersFromEitherEndSectionWithBearingFollowsTheDirectionGate() {
        let outOf = Geo.bearing(from: east, to: west)
        let fromEast = straightFixes(gate: east, course: outOf, speed: 25, metresBefore: 1000, metresAfter: 100)
        guard case .entered(_, let gate, _, .full)? = run(corridor(), fixes: fromEast).changes.first?.1 else { return XCTFail("corridor must enter from the east gate") }
        XCTAssertEqual(gate, east)

        let section = corridor(bearing: Geo.bearing(from: west, to: east), role: .averageSpeedSection, bidirectional: false)
        guard case .entered(_, _, _, let level)? = run(section, fixes: fromEast).changes.first?.1 else { return XCTFail("section must still report") }
        XCTAssertEqual(level, .visual, "an OSM bearing against the course demotes to visual")
        XCTAssertNil(run(section, fixes: fromEast).tracker.inside, "a visual entry does not enter")
    }

    func testExitAtTheFarGateAndRemainingEstimate() {
        let into = Geo.bearing(from: west, to: east)
        let chord = Geo.distance(west, east)
        let fixes = straightFixes(gate: west, course: into, speed: 25, metresBefore: 1000, metresAfter: chord + 100)
        let (changes, tracker) = run(corridor(), fixes: fixes)
        XCTAssertEqual(changes.count, 2)
        guard let (exitIndex, last) = changes.last, case .exited(_, let reason) = last else { return XCTFail("no exit") }
        XCTAssertEqual(reason, .farGate)
        XCTAssertNil(tracker.inside)
        XCTAssertEqual(Geo.distance(fixes[exitIndex].coordinate, east), 300, accuracy: 30)
    }

    func testAverageSpeedFromThePathAndDriveEndExit() {
        let into = Geo.bearing(from: west, to: east)
        let section = corridor(role: .averageSpeedSection, bidirectional: false)
        let fixes = straightFixes(gate: west, course: into, speed: 27.78, metresBefore: 1000, metresAfter: 3000)
        var tracker = StretchTracker()
        for f in fixes {
            _ = tracker.ingest(f, courseDegrees: f.course, warnDistance: 694, speedMps: 27.78, candidates: [section], now: f.timestamp)
        }
        guard let inside = tracker.inside, let avg = inside.avgKmh, let remaining = inside.remainingMetres else { return XCTFail("not inside with an average") }
        XCTAssertEqual(avg, 100, accuracy: 2)
        XCTAssertEqual(remaining, Geo.distance(west, east) - 3000, accuracy: 60)
        guard case .exited(_, let reason)? = tracker.endDrive() else { return XCTFail("drive end must exit") }
        XCTAssertEqual(reason, .driveEnd)
        XCTAssertNil(tracker.inside)
        XCTAssertNil(tracker.endDrive())
    }
}
