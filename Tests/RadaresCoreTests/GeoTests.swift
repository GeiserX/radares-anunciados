// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RadaresCore

final class GeoTests: XCTestCase {
    let madrid = Coordinate.at(40.4168, -3.7038)
    let barcelona = Coordinate.at(41.3874, 2.1686)

    func testHaversineMadridBarcelona() {
        XCTAssertEqual(Geo.distance(madrid, barcelona), 504_600, accuracy: 1500)
        XCTAssertEqual(Geo.distance(madrid, madrid), 0)
    }

    func testBearingCardinals() {
        let north = Geo.destination(from: madrid, bearingDegrees: 0, metres: 1000)
        let east = Geo.destination(from: madrid, bearingDegrees: 90, metres: 1000)
        XCTAssertEqual(Geo.bearing(from: madrid, to: north), 0, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(from: madrid, to: east), 90, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(from: north, to: madrid), 180, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(from: madrid, to: barcelona), 75.75, accuracy: 0.1)
    }

    func testAngleDiffWrapsAtNorth() {
        XCTAssertEqual(Geo.angleDiff(350, 10), 20)
        XCTAssertEqual(Geo.angleDiff(10, 350), 20)
        XCTAssertEqual(Geo.angleDiff(0, 180), 180)
        XCTAssertEqual(Geo.angleDiff(90, 270), 180)
        XCTAssertEqual(Geo.angleDiff(-40, 320), 0)
        XCTAssertEqual(Geo.normalize(-200), 160)
        XCTAssertEqual(Geo.normalize(720), 0)
    }

    func testCrossTrackIsSignedLateralDistance() {
        let ahead = Geo.destination(from: madrid, bearingDegrees: 0, metres: 800)
        let right = Geo.destination(from: ahead, bearingDegrees: 90, metres: 100)
        let left = Geo.destination(from: ahead, bearingDegrees: 270, metres: 100)
        XCTAssertEqual(Geo.crossTrack(point: ahead, from: madrid, courseDegrees: 0), 0, accuracy: 0.5)
        XCTAssertEqual(Geo.crossTrack(point: right, from: madrid, courseDegrees: 0), 100, accuracy: 0.5)
        XCTAssertEqual(Geo.crossTrack(point: left, from: madrid, courseDegrees: 0), -100, accuracy: 0.5)
    }

    func testProjectionOntoAChordIsClamped() {
        let end = Geo.destination(from: madrid, bearingDegrees: 90, metres: 10_000)
        let third = Geo.destination(from: Geo.destination(from: madrid, bearingDegrees: 90, metres: 3_000), bearingDegrees: 0, metres: 40)
        XCTAssertEqual(Geo.projection(point: third, from: madrid, to: end), 3_000, accuracy: 2)
        let behind = Geo.destination(from: madrid, bearingDegrees: 270, metres: 500)
        XCTAssertEqual(Geo.projection(point: behind, from: madrid, to: end), 0)
        let beyond = Geo.destination(from: end, bearingDegrees: 90, metres: 500)
        XCTAssertEqual(Geo.projection(point: beyond, from: madrid, to: end), 10_000, accuracy: 2)
        XCTAssertEqual(Geo.projection(point: madrid, from: madrid, to: end), 0)
    }

    func testDestinationRoundTrips() {
        let p = Geo.destination(from: madrid, bearingDegrees: 123, metres: 2_500)
        XCTAssertEqual(Geo.distance(madrid, p), 2_500, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(from: madrid, to: p), 123, accuracy: 0.01)
    }
}
