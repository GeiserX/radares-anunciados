// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RadaresCore

final class FeedDecoderTests: XCTestCase {
    func testFixtureIsAFeatureCollection() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.feedData()) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "FeatureCollection")
        let features = try XCTUnwrap(json["features"] as? [[String: Any]])
        XCTAssertEqual(features.count, 254)
    }

    func testFixtureDecodesToTheExpectedCountsPerKind() throws {
        let radars = try FeedDecoder.decode(Fixtures.feedData())
        var counts: [Kind: Int] = [:]
        for r in radars { counts[r.kind, default: 0] += 1 }
        // 254 features: 2 of an unknown kind are skipped and 46 section twins fold into their stretch.
        XCTAssertEqual(radars.count, 206)
        XCTAssertEqual(counts[.fixed], 109)
        XCTAssertEqual(counts[.stretch], 60)
        XCTAssertEqual(counts[.section], 4)
        XCTAssertEqual(counts[.mobileAnnounced], 23)
        XCTAssertEqual(counts[.trailer], 5)
        XCTAssertEqual(counts[.reported], 5)
        XCTAssertEqual(Set(radars.map(\.id)).count, radars.count, "ids stay unique")
    }

    func testRolesBySourceAndKind() throws {
        let radars = try FeedDecoder.decode(Fixtures.feedData())
        var roles: [Role: Int] = [:]
        for r in radars { roles[r.role, default: 0] += 1 }
        XCTAssertEqual(roles[.mobileCorridor], 31)
        XCTAssertEqual(roles[.averageSpeedSection], 29)
        XCTAssertEqual(roles[.point], 146)
        XCTAssertEqual(try Fixtures.radar("dgt_invive-Tramo_Invive_344").role, .mobileCorridor)
        XCTAssertEqual(try Fixtures.radar("dgt-CVM_161274").role, .averageSpeedSection)
        XCTAssertEqual(try Fixtures.radar("salamanca-tramo-2").role, .averageSpeedSection)
        XCTAssertEqual(try Fixtures.radar("dgt-CABINACINEMOMETRO_120001").role, .point)
    }

    func testNumericDirectionBecomesABearingAndNegativesFoldMod360() throws {
        let store = try Fixtures.store()
        let r = try XCTUnwrap(store.radar(id: "osm-619772731"))
        XCTAssertEqual(r.bearing, 320)
        XCTAssertFalse(r.bidirectional)
        XCTAssertNil(r.directionText)
        for id in ["osm-11370481637", "osm-12029827822", "osm-13645871721", "osm-619775424", "osm-992003666", "osm-992004416", "osm-992006870"] {
            let b = try XCTUnwrap(store.radar(id: id)?.bearing, id)
            XCTAssertGreaterThanOrEqual(b, 0, id)
            XCTAssertLessThan(b, 360, id)
        }
        XCTAssertEqual(FeedDecoder.parseDirection("-200").bearing, 160)
        XCTAssertEqual(FeedDecoder.parseDirection("-1").bearing, 359)
        XCTAssertEqual(FeedDecoder.parseDirection("75").bearing, 75)
        XCTAssertEqual(FeedDecoder.parseDirection("400").bearing, 40)
    }

    func testBothNameAndNullVocabularies() throws {
        let store = try Fixtures.store()
        let corridor = try XCTUnwrap(store.radar(id: "dgt_invive-Tramo_Invive_344"))
        XCTAssertTrue(corridor.bidirectional)
        XCTAssertNil(corridor.bearing)
        XCTAssertNil(corridor.directionText)

        let a2 = try XCTUnwrap(store.radar(id: "dgt-CABINACINEMOMETRO_120001"))
        XCTAssertEqual(a2.directionText, "ZARAGOZA")
        XCTAssertNil(a2.bearing)
        XCTAssertFalse(a2.bidirectional)

        let pair = try XCTUnwrap(store.radar(id: "dgt-CABINACINEMOMETRO_120452"))
        XCTAssertNil(pair.directionText)
        XCTAssertNil(pair.bearing)
        XCTAssertFalse(pair.bidirectional)

        XCTAssertEqual(FeedDecoder.parseDirection("forward"), FeedDecoder.Direction(), "OSM relative tokens carry no heading and no place")
        XCTAssertEqual(FeedDecoder.parseDirection("backward"), FeedDecoder.Direction())
        XCTAssertEqual(FeedDecoder.parseDirection("DONOSTIA / SAN SEBASTIÁN").text, "DONOSTIA / SAN SEBASTIÁN")
    }

    func testSectionTwinsMergeIntoTheirStretchBothEnds() throws {
        let store = try Fixtures.store()
        XCTAssertNil(store.radar(id: "dgt-CVM_161274-from"))
        XCTAssertNil(store.radar(id: "dgt-CVM_161274-to"))
        let stretch = try XCTUnwrap(store.radar(id: "dgt-CVM_161274"))
        XCTAssertEqual(stretch.kind, .stretch)
        XCTAssertEqual(stretch.start, .at(41.6088, -0.915697))
        XCTAssertEqual(stretch.end, .at(41.6192, -0.9496))
        XCTAssertEqual(stretch.directionText, "MADRID")
        XCTAssertEqual(store.all.filter { $0.id.hasSuffix("-from") || $0.id.hasSuffix("-to") }.count, 0)
    }

    func testUnpairedSectionsStayPoints() throws {
        let store = try Fixtures.store()
        for id in ["sct-A-2-539.2-545.1", "euskadi-trabakua-tramo-1"] {
            let r = try XCTUnwrap(store.radar(id: id), id)
            XCTAssertEqual(r.kind, .section)
            XCTAssertEqual(r.role, .point)
            XCTAssertNil(r.end)
        }
    }

    func testThirteenVertexLinesKeepTheirPathLength() throws {
        let store = try Fixtures.store()
        for id in ["salamanca-tramo-2", "salamanca-tramo-4"] {
            let r = try XCTUnwrap(store.radar(id: id), id)
            let end = try XCTUnwrap(r.end)
            let straight = Geo.distance(r.start, end)
            let chord = try XCTUnwrap(r.chordMetres)
            XCTAssertGreaterThan(chord, straight, "\(id): the sum of 12 segments is longer than the straight line")
            XCTAssertNil(r.roadMetres)
            XCTAssertEqual(r.lengthMetres, chord)
        }
    }

    func testRoadLengthFromKmMarkers() throws {
        let r = try Fixtures.radar("dgt_invive-Tramo_Invive_344")
        XCTAssertEqual(try XCTUnwrap(r.roadMetres), 10_100, accuracy: 0.01)
        XCTAssertEqual(r.road, "N-232")
        XCTAssertEqual(r.kmFrom, 20.81)
        XCTAssertEqual(r.kmTo, 30.91)
        XCTAssertEqual(r.lengthMetres, r.roadMetres)
        XCTAssertEqual(try XCTUnwrap(r.chordMetres), 9_680, accuracy: 60)
    }

    func testValidityDaysAreMadridCalendarDays() throws {
        let r = try Fixtures.radar("leon-2026-10-07-avenida-de-los-antibioticos-2")
        XCTAssertEqual(r.validFrom, madridDate(2026, 10, 7, 0))
        XCTAssertEqual(r.validTo, madridDate(2026, 10, 7, 0))
        XCTAssertEqual(r.maxspeed, 50)
        XCTAssertTrue(r.active)
        XCTAssertFalse(try Fixtures.radar("leon-2026-10-06-avenida-de-europa-0").active)
        XCTAssertNil(FeedDecoder.day("2026-13-40"))
        XCTAssertNil(FeedDecoder.day(nil))
    }

    func testUnknownKindsMissingIdsAndOddGeometriesAreSkippedNotFatal() throws {
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","id":"ok","geometry":{"type":"Point","coordinates":[-1.9,41.3]},"properties":{"kind":"fixed","name":"x","source":"dgt","active":true,"maxspeed":null,"direction":null,"province":null,"url":null,"attribution":"a","extra_field":{"nested":1}}},
          {"type":"Feature","id":"newkind","geometry":{"type":"Point","coordinates":[-1.9,41.3]},"properties":{"kind":"mobile_recurring","name":"x","source":"madrid_multas","active":true}},
          {"type":"Feature","geometry":{"type":"Point","coordinates":[-1.9,41.3]},"properties":{"kind":"fixed","name":"noid","source":"dgt","active":true}},
          {"type":"Feature","id":"poly","geometry":{"type":"Polygon","coordinates":[[[0,0],[1,1],[2,2],[0,0]]]},"properties":{"kind":"fixed","name":"x","source":"dgt","active":true}},
          {"type":"Feature","id":"nogeom","geometry":null,"properties":{"kind":"fixed","name":"x","source":"dgt","active":true}}
        ]}
        """
        let radars = try FeedDecoder.decode(Data(json.utf8))
        XCTAssertEqual(radars.map(\.id), ["ok"])
    }

    func testATwinFillsAMissingLimitOnItsStretch() throws {
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","id":"s","geometry":{"type":"LineString","coordinates":[[-1.9,41.3],[-1.8,41.3]]},"properties":{"kind":"stretch","name":"s","source":"dgt","active":true,"maxspeed":null,"direction":"MADRID","road":"A-2","km_from":10,"km_to":12.5}},
          {"type":"Feature","id":"s-from","geometry":{"type":"Point","coordinates":[-1.9,41.3]},"properties":{"kind":"section","name":"s from","source":"dgt","active":true,"maxspeed":100}},
          {"type":"Feature","id":"s-to","geometry":{"type":"Point","coordinates":[-1.8,41.3]},"properties":{"kind":"section","name":"s to","source":"dgt","active":true,"maxspeed":100}}
        ]}
        """
        let radars = try FeedDecoder.decode(Data(json.utf8))
        XCTAssertEqual(radars.count, 1)
        XCTAssertEqual(radars[0].id, "s")
        XCTAssertEqual(radars[0].maxspeed, 100)
        XCTAssertEqual(radars[0].roadMetres, 2500)
    }
}
