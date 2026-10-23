// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The map's pure rules (design 4.4): only radars that can warn today (and grey reports), a corridor longer than the
// box still drawn when the car is in its middle, and the road drawn under a stretch when the sidecar has one.

import RadaresCore
import XCTest
@testable import RadaresAnunciados

final class MapRulesTests: XCTestCase {
    /// León city centre.
    private let leon = Coordinate(latitude: 42.5987, longitude: -5.5671)
    private let today = FeedDecoder.madridCalendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12))!

    private func day(_ offset: Int) -> Date {
        FeedDecoder.madridCalendar.startOfDay(for: today).addingTimeInterval(Double(offset) * 86_400)
    }

    private func announced(from: Int, to: Int, active: Bool) -> Radar {
        Radar(
            id: "leon-announced", kind: .mobileAnnounced, role: .point,
            start: Geo.destination(from: leon, bearingDegrees: 45, metres: 800),
            name: "Avenida de Europa", validFrom: day(from), validTo: day(to), active: active,
            source: "leon", attribution: ""
        )
    }

    private func stretch(_ id: String, from: Coordinate, to: Coordinate) -> Radar {
        Radar(
            id: id, kind: .stretch, role: .mobileCorridor, start: from, end: to,
            chordMetres: Geo.distance(from, to), name: id, source: "dgt_invive", attribution: ""
        )
    }

    private func ids(_ radars: [Radar], roadLine: (String) -> [Coordinate]? = { _ in nil }) -> [String] {
        MapRules.nearby(store: RadarStore(radars: radars), centre: leon, on: today, roadLine: roadLine).map(\.id)
    }

    /// An announced radar whose days are over (the feed marks it active=false) is not drawn; the same radar announced
    /// for today is. A grey report stays.
    func testAnExpiredAnnouncedRadarIsNotDrawn() {
        XCTAssertEqual(ids([announced(from: -10, to: -3, active: false)]), [], "expired and inactive: stale marker")
        XCTAssertEqual(ids([announced(from: -10, to: -3, active: true)]), [], "past dates alone already hide it")
        XCTAssertEqual(ids([announced(from: 0, to: 2, active: true)]), ["leon-announced"], "announced for today: drawn")
        let report = Radar(
            id: "note", kind: .reported, role: .point, start: leon, name: "nota", active: false, source: "osm", attribution: ""
        )
        XCTAssertEqual(ids([report]), ["note"], "an unconfirmed report is drawn in grey")
    }

    /// A 12 km corridor centred on the map: both ends 6 km away, outside the 5 km box, yet the line crosses it. A
    /// corridor 30 km away is not drawn.
    func testACorridorCrossingTheBoxIsDrawnWithBothEndsOutside() {
        let through = stretch(
            "through",
            from: Geo.destination(from: leon, bearingDegrees: 0, metres: 6000),
            to: Geo.destination(from: leon, bearingDegrees: 180, metres: 6000)
        )
        let farCentre = Geo.destination(from: leon, bearingDegrees: 90, metres: 30_000)
        let far = stretch(
            "far",
            from: Geo.destination(from: farCentre, bearingDegrees: 0, metres: 6000),
            to: Geo.destination(from: farCentre, bearingDegrees: 180, metres: 6000)
        )
        XCTAssertEqual(ids([through, far]), ["through"])
        let item = MapRules.nearby(store: RadarStore(radars: [through]), centre: leon, on: today).first
        XCTAssertEqual(item?.line, [through.start, through.end!], "without a road the chord is drawn")
    }

    /// A stretch with a road line draws the road, not the chord; a bowed road that comes into the box while the
    /// chord stays outside keeps the stretch on the map. Points never get a line.
    func testALineWithARoadDrawsTheRoad() throws {
        let start = Geo.destination(from: leon, bearingDegrees: 270, metres: 12_000)
        let end = Geo.destination(from: leon, bearingDegrees: 90, metres: 12_000)
        let bowedChord = stretch("bowed", from: Geo.destination(from: start, bearingDegrees: 0, metres: 9000), to: Geo.destination(from: end, bearingDegrees: 0, metres: 9000))
        let road = [bowedChord.start, leon, bowedChord.end!]
        XCTAssertEqual(ids([bowedChord]), [], "the chord 9 km north misses the box")
        let items = MapRules.nearby(store: RadarStore(radars: [bowedChord]), centre: leon, on: today) { $0 == "bowed" ? road : nil }
        let item = try XCTUnwrap(items.first, "the road through the centre keeps it")
        XCTAssertEqual(item.line, road)

        let point = Radar(id: "p", kind: .fixed, role: .point, start: leon, name: "p", source: "dgt", attribution: "")
        let pointItem = try XCTUnwrap(
            MapRules.nearby(store: RadarStore(radars: [point]), centre: leon, on: today) { _ in road }.first,
            "a point at the centre is drawn"
        )
        XCTAssertNil(pointItem.line, "a point never gets a line, even when a road is supplied")
    }
}
