// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RadaresCore

final class RadarStoreTests: XCTestCase {
    let a2 = Coordinate.at(41.30326, -1.94488)

    func testCandidatesAreOrderedByGateDistanceAndBounded() throws {
        let store = try Fixtures.store()
        XCTAssertEqual(store.count, 208)
        XCTAssertEqual(store.countsByKind[.stretch], 60)
        let near = store.candidates(near: a2, within: 1200, on: t0)
        XCTAssertEqual(near.map(\.id), ["dgt-CABINACINEMOMETRO_120001"])
        let from2km = Geo.destination(from: a2, bearingDegrees: 60, metres: 2000)
        XCTAssertTrue(store.candidates(near: from2km, within: 1200, on: t0).isEmpty)
        XCTAssertEqual(store.candidates(near: from2km, within: 2100, on: t0).map(\.id), ["dgt-CABINACINEMOMETRO_120001"])
    }

    /// A line is a candidate by its nearer gate or by its chord (design 2.5: a car that joined between the gates
    /// must see the stretch); a point 2 km beside the chord is not.
    func testALineIsFoundByItsNearerGateOrByItsChord() throws {
        let store = try Fixtures.store()
        let corridor = try Fixtures.radar("dgt_invive-Tramo_Invive_344")
        let east = try XCTUnwrap(corridor.end)
        let nearEast = Geo.destination(from: east, bearingDegrees: 90, metres: 500)
        XCTAssertEqual(store.candidates(near: nearEast, within: 800, on: t0).map(\.id), [corridor.id])
        let into = Geo.bearing(from: corridor.start, to: east)
        let middle = Geo.destination(from: corridor.start, bearingDegrees: into, metres: 4800)
        XCTAssertEqual(store.candidates(near: middle, within: 1200, on: t0).map(\.id), [corridor.id], "the middle of the chord is on the stretch")
        XCTAssertEqual(RadarStore.distance(from: middle, to: corridor), 0, accuracy: 1)
        XCTAssertGreaterThan(RadarStore.gateDistance(from: middle, to: corridor), 4000, "the gates are still far")
        let beside = Geo.destination(from: middle, bearingDegrees: into + 90, metres: 2000)
        XCTAssertTrue(store.candidates(near: beside, within: 1200, on: t0).isEmpty, "2 km beside the chord is not on it")
        XCTAssertEqual(RadarStore.distance(from: beside, to: corridor), 2000, accuracy: 5)
    }

    func testInactiveAndReportedAreNeverCandidates() throws {
        let store = try Fixtures.store()
        let inactive = try Fixtures.radar("leon-2026-10-06-avenida-de-europa-0")
        XCTAssertFalse(inactive.active)
        XCTAssertFalse(store.candidates(near: inactive.start, within: 50, on: madridDate(2026, 10, 6)).contains { $0.id == inactive.id })
        let reported = try XCTUnwrap(store.all.first { $0.kind == .reported })
        XCTAssertTrue(reported.active)
        XCTAssertFalse(store.candidates(near: reported.start, within: 50, on: t0).contains { $0.id == reported.id })
        XCTAssertFalse(reported.isAlertable(on: t0))
    }

    func testAnnouncedMobileRadarIsAlertableOnlyOnItsMadridDays() throws {
        let store = try Fixtures.store()
        let leon = try Fixtures.radar("leon-2026-10-07-avenida-de-los-antibioticos-2")
        let ids = { (day: Date) in store.candidates(near: leon.start, within: 50, on: day).map(\.id) }
        XCTAssertEqual(ids(madridDate(2026, 10, 7, 0, 1)), [leon.id])
        XCTAssertEqual(ids(madridDate(2026, 10, 7, 23, 59)), [leon.id])
        XCTAssertEqual(ids(madridDate(2026, 10, 6, 23, 59)), [])
        XCTAssertEqual(ids(madridDate(2026, 10, 8, 0, 1)), [])
    }

    func testMadridMidnightNotUTCMidnight() throws {
        let store = try Fixtures.store()
        let murcia = try XCTUnwrap(store.all.first { $0.source == "murcia" && $0.active })
        let to = try XCTUnwrap(murcia.validTo)
        // 22:30 UTC on the last valid day is already 00:30 of the next day in Madrid (CEST): no longer alertable.
        let lastDayMadrid = FeedDecoder.madridCalendar.date(byAdding: DateComponents(hour: 23, minute: 30), to: to)!
        XCTAssertTrue(murcia.isAlertable(on: lastDayMadrid))
        let lateUTC = FeedDecoder.madridCalendar.date(byAdding: DateComponents(hour: 24, minute: 30), to: to)!
        XCTAssertFalse(murcia.isAlertable(on: lateUTC))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.day, from: lateUTC), utc.component(.day, from: lastDayMadrid), "same UTC day, different Madrid day")
    }

    func testRadarByIdAndMissingId() throws {
        let store = try Fixtures.store()
        XCTAssertEqual(store.radar(id: "dgt-CABINACINEMOMETRO_120001")?.name, "Radar fijo A-2 km 202.3 (sentido ZARAGOZA)")
        XCTAssertNil(store.radar(id: "nope"))
        XCTAssertNil(store.radar(id: "dgt-CVM_161274-from"), "merged twins are gone")
    }
}
