// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// When a Live Activity update is worth sending (design 2.7 and 4.2): milestones, stretch steps, phase and target
// changes, the 60 s idle refresh, the stale dates. Pure, no ActivityKit.

import RadaresCore
import XCTest
@testable import RadaresAnunciados

final class ActivityCadenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ phase: DrivePhase = .approaching, metres: Int? = nil, remaining: Int? = nil, title: String = "Radar fijo", note: String? = nil, at t: Date? = nil) -> DriveContent {
        DriveContent(phase: phase, kindSymbol: "camera.fill", title: title, subtitle: "A-2 km 202,3", distanceMetres: metres, limit: 90, speedKmh: 120, stretchRemainingMetres: remaining, note: note, updatedAt: t ?? t0)
    }

    func testDistanceSnapsToTheMilestoneJustCrossed() {
        XCTAssertEqual(ActivityCadence.snappedDistance(833), 1000)
        XCTAssertEqual(ActivityCadence.snappedDistance(1000), 1000)
        XCTAssertEqual(ActivityCadence.snappedDistance(760), 1000)
        XCTAssertEqual(ActivityCadence.snappedDistance(750), 750)
        XCTAssertEqual(ActivityCadence.snappedDistance(700), 750)
        XCTAssertEqual(ActivityCadence.snappedDistance(480), 500)
        XCTAssertEqual(ActivityCadence.snappedDistance(240), 250)
        XCTAssertEqual(ActivityCadence.snappedDistance(90), 100)
        XCTAssertEqual(ActivityCadence.snappedDistance(1150), 1200, "beyond the first milestone, 100 m steps")
        XCTAssertEqual(ActivityCadence.snappedDistance(2049), 2000)
    }

    func testRemainingRoundsUpToTheNextStep() {
        XCTAssertEqual(ActivityCadence.snappedRemaining(8_499), 8_500)
        XCTAssertEqual(ActivityCadence.snappedRemaining(8_500), 8_500)
        XCTAssertEqual(ActivityCadence.snappedRemaining(8_001), 8_500)
        XCTAssertEqual(ActivityCadence.snappedRemaining(8_000), 8_000)
        XCTAssertEqual(ActivityCadence.snappedRemaining(-5), 0)
    }

    func testTwoFixesInsideOneMilestoneSendNothing() {
        var cadence = ActivityCadence()
        let first = ActivityCadence.display(card(metres: 990))
        XCTAssertEqual(cadence.reason(for: first, alert: false, now: t0), .first)
        cadence.record(first, at: t0)
        let inside = ActivityCadence.display(card(metres: 900, at: t0.addingTimeInterval(3)))
        XCTAssertNil(cadence.reason(for: inside, alert: false, now: t0.addingTimeInterval(3)), "900 m is still the 1,0 km card")
        let crossed = ActivityCadence.display(card(metres: 740, at: t0.addingTimeInterval(9)))
        XCTAssertEqual(cadence.reason(for: crossed, alert: false, now: t0.addingTimeInterval(9)), .milestone)
    }

    func testAlertPhaseTargetNoteAndStretchStepAlwaysSend() {
        var cadence = ActivityCadence()
        let base = ActivityCadence.display(card(metres: 990))
        cadence.record(base, at: t0)
        let t = t0.addingTimeInterval(1)
        XCTAssertEqual(cadence.reason(for: base, alert: true, now: t), .alert)
        XCTAssertEqual(cadence.reason(for: ActivityCadence.display(card(.alert, metres: 990)), alert: false, now: t), .phase)
        XCTAssertEqual(cadence.reason(for: ActivityCadence.display(card(metres: 990, title: "Radar en remolque")), alert: false, now: t), .target)
        XCTAssertEqual(cadence.reason(for: ActivityCadence.display(card(metres: 990, note: "Datos de hace 3 días")), alert: false, now: t), .note)

        var inside = ActivityCadence()
        inside.record(ActivityCadence.display(card(.insideStretch, remaining: 8_400)), at: t0)
        XCTAssertNil(inside.reason(for: ActivityCadence.display(card(.insideStretch, remaining: 8_100)), alert: false, now: t), "8,5 km holds until 8,0 km")
        XCTAssertEqual(inside.reason(for: ActivityCadence.display(card(.insideStretch, remaining: 7_990)), alert: false, now: t), .stretchStep)
    }

    func testWatchingCardIgnoresDistanceMilestones() {
        var cadence = ActivityCadence()
        var nearby = card(.watching, metres: 990)
        nearby.subtitle = "cerca"
        cadence.record(ActivityCadence.display(nearby), at: t0)
        var closer = nearby
        closer.distanceMetres = 480
        XCTAssertNil(cadence.reason(for: ActivityCadence.display(closer), alert: false, now: t0.addingTimeInterval(5)), "a radar beside the road moving from 1,0 km to 500 m is not a milestone")
        XCTAssertEqual(cadence.reason(for: ActivityCadence.display(card(.approaching, metres: 480)), alert: false, now: t0.addingTimeInterval(5)), .phase)
    }

    func testIdleRefreshAfterSixtySeconds() {
        var cadence = ActivityCadence()
        let watching = ActivityCadence.display(.watching(at: t0))
        cadence.record(watching, at: t0)
        XCTAssertNil(cadence.reason(for: watching, alert: false, now: t0.addingTimeInterval(Thresholds.cardIdleSeconds - 1)))
        XCTAssertEqual(cadence.reason(for: watching, alert: false, now: t0.addingTimeInterval(Thresholds.cardIdleSeconds)), .idle)
    }

    func testStaleDates() {
        XCTAssertEqual(ActivityCadence.staleDate(for: card(), now: t0), t0.addingTimeInterval(Thresholds.activityStaleSeconds))
        XCTAssertEqual(ActivityCadence.staleDate(for: card(.paused), now: t0), t0.addingTimeInterval(Thresholds.activityPausedStaleMinutes * 60))
    }
}
