// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RadaresCore

final class ApproachTests: XCTestCase {
    let gate = Coordinate.at(41.30326, -1.94488)

    /// A fix `metres` before the gate along `course`, offset `side` metres to the right.
    func fix(metres: Double, course: Double = 60, side: Double = 0, speed: Double = 25) -> Fix {
        var p = Geo.destination(from: gate, bearingDegrees: Geo.normalize(course + 180), metres: metres)
        if side != 0 { p = Geo.destination(from: p, bearingDegrees: Geo.normalize(course + 90), metres: side) }
        return makeFix(p, t: t0, speed: speed, course: course)
    }

    func evaluate(_ f: Fix, course: Double = 60, bearing: Double? = nil, bidirectional: Bool = false, previous: [Double] = [700, 680], warn: Double = 625) -> Approach {
        ApproachEvaluator.evaluate(gate: gate, bearing: bearing, bidirectional: bidirectional, fix: f, courseDegrees: course, previousDistances: previous, warnDistance: warn)
    }

    func testAheadIsTheSixtyDegreeCone() {
        XCTAssertTrue(evaluate(fix(metres: 600)).ahead)
        // 600 m ahead and 300 m to the side is 26.6 degrees off: still ahead (a curve). 1,100 m to the side is 61 degrees: beside.
        XCTAssertTrue(evaluate(fix(metres: 600, side: 300)).ahead)
        XCTAssertFalse(evaluate(fix(metres: 600, side: 1100)).ahead)
        XCTAssertFalse(evaluate(fix(metres: -100)).ahead, "behind")
    }

    func testClosingNeedsTwoDecreasesOfAtLeastOneMetre() {
        XCTAssertTrue(evaluate(fix(metres: 600), previous: [640, 620]).closing)
        XCTAssertFalse(evaluate(fix(metres: 600), previous: [620]).closing, "one earlier fix is not enough")
        XCTAssertFalse(evaluate(fix(metres: 600), previous: []).closing)
        XCTAssertFalse(evaluate(fix(metres: 600), previous: [640, 600.5]).closing, "a half metre is jitter")
        XCTAssertFalse(evaluate(fix(metres: 600), previous: [610, 640]).closing, "oscillating")
        XCTAssertTrue(evaluate(fix(metres: 600), previous: [900, 640, 620]).closing, "only the last two count")
    }

    func testInRangeAndLevel() {
        XCTAssertEqual(evaluate(fix(metres: 600), warn: 625).level, .full)
        XCTAssertTrue(evaluate(fix(metres: 600), warn: 625).inRange)
        XCTAssertNil(evaluate(fix(metres: 700), previous: [740, 720], warn: 625).level)
        XCTAssertFalse(evaluate(fix(metres: 700), previous: [740, 720], warn: 625).inRange)
        XCTAssertNil(evaluate(fix(metres: 600), previous: [], warn: 625).level, "in range but not closing")
    }

    func testDirectionGateDemotesOnlyTheOppositeFlow() {
        XCTAssertEqual(evaluate(fix(metres: 600), bearing: 60).level, .full)
        XCTAssertEqual(evaluate(fix(metres: 600), bearing: 140).level, .full, "80 degrees off is a curve, inside the half-plane")
        XCTAssertEqual(evaluate(fix(metres: 600), bearing: 240).level, .visual, "the opposite flow")
        XCTAssertEqual(evaluate(fix(metres: 600), bearing: 160).level, .visual, "100 degrees off")
        XCTAssertEqual(evaluate(fix(metres: 600), bearing: 240, bidirectional: true).level, .full)
        XCTAssertEqual(evaluate(fix(metres: 600), bearing: nil).level, .full)
        XCTAssertFalse(evaluate(fix(metres: 600), bearing: 240).directionMatch)
    }

    /// The two angles are inclusive edges (design 2.3 and 2.4 say "≤"): exactly 60° is ahead, exactly 90° matches.
    func testTheConeAndTheHalfPlaneAreInclusiveAtTheirEdges() {
        XCTAssertTrue(ApproachEvaluator.isAhead(angleOff: Thresholds.aheadDeg))
        XCTAssertFalse(ApproachEvaluator.isAhead(angleOff: Thresholds.aheadDeg.nextUp))
        XCTAssertTrue(ApproachEvaluator.matchesDirection(angleOff: Thresholds.bearingToleranceDeg))
        XCTAssertFalse(ApproachEvaluator.matchesDirection(angleOff: Thresholds.bearingToleranceDeg.nextUp))
    }

    func testLateWhenFirstSeenInsideTheBand() {
        XCTAssertFalse(evaluate(fix(metres: 600), previous: [800, 640], warn: 625).late, "first seen at 800, outside warn - 100")
        XCTAssertTrue(evaluate(fix(metres: 400), previous: [500, 450], warn: 625).late, "first seen at 500, inside 525")
        XCTAssertTrue(evaluate(fix(metres: 100), previous: [], warn: 625).late, "first fix is this one")
        XCTAssertFalse(evaluate(fix(metres: 530), previous: [], warn: 625).late, "exactly outside the late band")
    }

    func testDistanceAndCrossTrackAreReported() {
        let a = evaluate(fix(metres: 600, side: 50))
        XCTAssertEqual(a.distanceMetres, sqrt(600 * 600 + 50 * 50), accuracy: 1)
        XCTAssertEqual(a.crossTrackMetres, -50, accuracy: 1, "the gate is 50 m to the left of a car offset to the right")
        XCTAssertEqual(evaluate(fix(metres: 600)).crossTrackMetres, 0, accuracy: 0.5)
    }
}
