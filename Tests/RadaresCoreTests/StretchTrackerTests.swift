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
        guard case .entered(let radar, let gate, let approach, let level, let remaining)? = changes.first?.1 else { return XCTFail("no entry") }
        XCTAssertNil(remaining, "a gate entry carries no remaining length")
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
        guard case .entered(_, let gate, _, .full, _)? = run(corridor(), fixes: fromEast).changes.first?.1 else { return XCTFail("corridor must enter from the east gate") }
        XCTAssertEqual(gate, east)

        let section = corridor(bearing: Geo.bearing(from: west, to: east), role: .averageSpeedSection, bidirectional: false)
        guard case .entered(_, _, _, let level, _)? = run(section, fixes: fromEast).changes.first?.1 else { return XCTFail("section must still report") }
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

    /// Joined between the gates: three fixes on the chord heading along it enter with the length left; the same
    /// fixes across the chord, or beside it, never enter. A car already past the far-gate margin does not enter.
    func testJoinBetweenTheGates() {
        let into = Geo.bearing(from: west, to: east)
        let chord = Geo.distance(west, east)
        let start = Geo.destination(from: west, bearingDegrees: into, metres: 5000)
        var fixes: [Fix] = []
        for i in 0..<10 {
            fixes.append(makeFix(Geo.destination(from: start, bearingDegrees: into, metres: Double(i) * 25), t: t0.addingTimeInterval(Double(i)), speed: 25, course: into))
        }
        let (changes, tracker) = run(corridor(), fixes: fixes)
        guard case .entered(_, let gate, let approach, .full, let remaining)? = changes.first?.1 else { return XCTFail("no mid-join: \(changes)") }
        XCTAssertEqual(changes.first?.0, Thresholds.stretchMidJoinFixes - 1, "the third fix on the chord")
        XCTAssertEqual(gate, west)
        XCTAssertEqual(try XCTUnwrap(remaining), chord - 5050, accuracy: 5)
        XCTAssertEqual(approach.distanceMetres, try XCTUnwrap(remaining))
        XCTAssertEqual(try XCTUnwrap(tracker.inside?.remainingMetres), chord - 5000 - 9 * 25, accuracy: 5, "after the last of the ten fixes")

        // Heading back west from the same spot enters with the east gate behind and the west gate ahead.
        let back = fixes.map { makeFix($0.coordinate, t: $0.timestamp, speed: 25, course: Geo.normalize(into + 180)) }
        guard case .entered(_, let backGate, _, .full, _)? = run(corridor(), fixes: back).changes.first?.1 else { return XCTFail("no mid-join westward") }
        XCTAssertEqual(backGate, east)

        let across = fixes.map { makeFix($0.coordinate, t: $0.timestamp, speed: 25, course: Geo.normalize(into + 90)) }
        XCTAssertTrue(run(corridor(), fixes: across).changes.isEmpty, "crossing the chord is not a join")

        // Two qualifying fixes, one with no course, one more: not three in a row, so the join comes two fixes later.
        var broken = fixes
        broken[2] = makeFix(fixes[2].coordinate, t: fixes[2].timestamp, speed: 25, course: nil)
        XCTAssertEqual(run(corridor(), fixes: broken).changes.first?.0, 5, "the run restarts after the course-less fix")

        let beside = fixes.map { makeFix(Geo.destination(from: $0.coordinate, bearingDegrees: into + 90, metres: Thresholds.stretchMidJoinCrossTrackM + 50), t: $0.timestamp, speed: 25, course: into) }
        XCTAssertTrue(run(corridor(), fixes: beside).changes.isEmpty, "a road beside the chord is not a join")

        let nearFar = fixes.map { makeFix(Geo.destination(from: $0.coordinate, bearingDegrees: into, metres: chord - 5200), t: $0.timestamp, speed: 25, course: into) }
        XCTAssertTrue(run(corridor(), fixes: nearFar).changes.isEmpty, "inside the far-gate margin there is nothing left to warn about")

        // An OSM bearing on a section follows the direction gate: heading against it is no entry at all.
        let section = corridor(bearing: into, role: .averageSpeedSection, bidirectional: false)
        XCTAssertTrue(run(section, fixes: back).changes.isEmpty)
        XCTAssertFalse(run(section, fixes: fixes).changes.isEmpty)
    }

    /// Restored from the ledger after a relaunch: the far gate, the chord and the exit are those of the entry.
    func testResumeFromAPersistedState() {
        let into = Geo.bearing(from: west, to: east)
        let chord = Geo.distance(west, east)
        let state = DriveSnapshot.StretchState(radar: corridor(), enteredAt: t0, entryGate: west, remainingMetres: chord, entrySpeedMps: 25)
        var tracker = StretchTracker(resuming: state)
        XCTAssertNotNil(tracker.inside)
        var exit: StretchTracker.Change?
        var remainingSeen: [Double] = []
        for i in 0..<(Int(chord / 25) + 10) {
            let fix = makeFix(Geo.destination(from: west, bearingDegrees: into, metres: 5000 + Double(i) * 25), t: t0.addingTimeInterval(200 + Double(i)), speed: 25, course: into)
            if let c = tracker.ingest(fix, courseDegrees: into, warnDistance: 625, speedMps: 25, candidates: [corridor()], now: fix.timestamp) { exit = c; break }
            remainingSeen.append(tracker.inside?.remainingMetres ?? -1)
        }
        guard case .exited(_, let reason)? = exit else { return XCTFail("no exit after the restore") }
        XCTAssertEqual(reason, .farGate)
        XCTAssertEqual(remainingSeen.first!, chord - 5000, accuracy: 5)
        XCTAssertNil(StretchTracker(resuming: nil).inside)
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
