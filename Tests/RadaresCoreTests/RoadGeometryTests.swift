// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The road sidecar (design 5.5) and the road rule (design 2.3): polyline5, projection, the candidate rule, the
// along-jump guard, the line index, the validator, and the 0.1.3 shapes that must still decode.

import XCTest
@testable import RadaresCore

final class RoadGeometryTests: XCTestCase {
    // MARK: Polyline

    func testThePolylineReferenceVectorDecodesAndEncodes() throws {
        let coords = try XCTUnwrap(Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@"))
        XCTAssertEqual(coords.count, 3)
        XCTAssertEqual(coords[0].latitude, 38.5, accuracy: 1e-9)
        XCTAssertEqual(coords[0].longitude, -120.2, accuracy: 1e-9)
        XCTAssertEqual(coords[1].latitude, 40.7, accuracy: 1e-9)
        XCTAssertEqual(coords[1].longitude, -120.95, accuracy: 1e-9)
        XCTAssertEqual(coords[2].latitude, 43.252, accuracy: 1e-9)
        XCTAssertEqual(coords[2].longitude, -126.453, accuracy: 1e-9)
        XCTAssertEqual(Polyline.encode(coords), "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
    }

    func testAMalformedPolylineIsRefused() {
        XCTAssertNil(Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq"), "cut inside a value")
        XCTAssertNil(Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`"), "cut inside the last value")
        XCTAssertNil(Polyline.decode("_p~iF ~ps|U"), "a byte outside the alphabet")
        XCTAssertNil(Polyline(encoded: "_p~iF~ps|U"), "one vertex is not a line")
        XCTAssertNotNil(Polyline(encoded: "_p~iF~ps|U_ulLnnqC"))
    }

    /// A straight line 1,000 m north from the origin.
    private func north(_ origin: Coordinate = .at(40, -3), metres: Double = 1000) -> Polyline {
        Polyline(vertices: [origin, Geo.destination(from: origin, bearingDegrees: 0, metres: metres)])!
    }

    func testProjectionOnAStraight() throws {
        let line = north()
        XCTAssertEqual(line.length, 1000, accuracy: 2)
        XCTAssertEqual(line.segmentBearings[0], 0, accuracy: 0.1)
        let p = Geo.destination(from: Geo.destination(from: line.vertices[0], bearingDegrees: 0, metres: 400), bearingDegrees: 90, metres: 12)
        let proj = line.project(p)
        XCTAssertEqual(proj.alongMetres, 400, accuracy: 1)
        XCTAssertEqual(proj.lateralMetres, 12, accuracy: 0.5)
    }

    func testProjectionBeyondBothEndsClampsToTheEnds() throws {
        let line = north()
        let before = Geo.destination(from: line.vertices[0], bearingDegrees: 180, metres: 100)
        XCTAssertEqual(line.project(before).alongMetres, 0, accuracy: 0.01)
        XCTAssertEqual(line.project(before).lateralMetres, 100, accuracy: 0.5)
        let after = Geo.destination(from: line.vertices[1], bearingDegrees: 0, metres: 50)
        XCTAssertEqual(line.project(after).alongMetres, line.length, accuracy: 0.01)
        XCTAssertEqual(line.project(after).lateralMetres, 50, accuracy: 0.5)
    }

    func testProjectionOnAnArc() throws {
        // A quarter circle of 1,000 m radius around a centre: length about 1,571 m.
        let centre = Coordinate.at(40, -3)
        let arc = (0...90).map { Geo.destination(from: centre, bearingDegrees: Double($0), metres: 1000) }
        let line = try XCTUnwrap(Polyline(vertices: arc))
        XCTAssertEqual(line.length, 1000 * .pi / 2, accuracy: 3)
        // 10 m outside the arc at 45 degrees: halfway along, 10 m off, travelling 135 degrees.
        let p = Geo.destination(from: centre, bearingDegrees: 45, metres: 1010)
        let proj = line.project(p)
        XCTAssertEqual(proj.alongMetres, line.length / 2, accuracy: 5)
        XCTAssertEqual(proj.lateralMetres, 10, accuracy: 0.5)
        XCTAssertEqual(proj.segmentBearing, 135, accuracy: 1)
        XCTAssertEqual(line.coordinate(atAlong: line.length / 2).latitude, Geo.destination(from: centre, bearingDegrees: 45, metres: 1000).latitude, accuracy: 1e-5)
    }

    // MARK: The candidate rule

    /// Two legs of a switchback 20 m apart, opposite directions: the car on the lower leg, 15 m toward the upper one,
    /// matches its own leg (farther) and not the nearer one that runs the other way.
    func testTheCandidateRulePrefersTheRightBearingOverTheNearerSegment() throws {
        let o = Coordinate.at(40, -3)
        let lower = try XCTUnwrap(Polyline(vertices: [o, Geo.destination(from: o, bearingDegrees: 90, metres: 400)]))
        let upperStart = Geo.destination(from: Geo.destination(from: o, bearingDegrees: 90, metres: 400), bearingDegrees: 0, metres: 20)
        let upper = try XCTUnwrap(Polyline(vertices: [upperStart, Geo.destination(from: upperStart, bearingDegrees: 270, metres: 400)]))
        let road = try XCTUnwrap(Polyline(vertices: lower.vertices + upper.vertices))
        let car = Geo.destination(from: Geo.destination(from: o, bearingDegrees: 90, metres: 200), bearingDegrees: 0, metres: 15)
        let m = try XCTUnwrap(RoadApproach.match([road], at: car, course: 90, accuracy: 5))
        XCTAssertEqual(m.projection.segmentIndex, 0, "the lower leg, 15 m away, not the upper one 5 m away")
        XCTAssertEqual(m.projection.lateralMetres, 15, accuracy: 0.5)
        // Positive control: heading west the nearer leg is the match.
        let west = try XCTUnwrap(RoadApproach.match([road], at: car, course: 270, accuracy: 5))
        XCTAssertEqual(west.projection.segmentIndex, 2)
        // No candidate at all off the course test: 90 degrees off both legs.
        XCTAssertNil(RoadApproach.match([road], at: car, course: 0, accuracy: 5))
        // The lateral limit grows with a poor fix.
        let far = Geo.destination(from: Geo.destination(from: o, bearingDegrees: 90, metres: 200), bearingDegrees: 180, metres: 30)
        XCTAssertNil(RoadApproach.match([road], at: far, course: 90, accuracy: 5))
        XCTAssertNotNil(RoadApproach.match([road], at: far, course: 90, accuracy: 25))
    }

    func testTheAlongJumpGuardDropsAFourHundredMetreJump() throws {
        let line = north(metres: 2000)
        let at = Geo.destination(from: line.vertices[0], bearingDegrees: 0, metres: 900)
        let now = t0.addingTimeInterval(1)
        // Previous fix 500 m along, 1 s ago, 20 m/s: the limit is 3 x 20 x 1 + 50 = 110 m; 900 is 400 m away.
        XCTAssertNil(RoadApproach.match([line], at: at, course: 0, accuracy: 5, previous: (0, 500, t0), now: now, speedMps: 20))
        // Positive control: from 820 m it is an 80 m move, kept.
        XCTAssertNotNil(RoadApproach.match([line], at: at, course: 0, accuracy: 5, previous: (0, 820, t0), now: now, speedMps: 20))
        // The guard is per polyline: the previous fix on another one does not hold this one back.
        XCTAssertNotNil(RoadApproach.match([line], at: at, course: 0, accuracy: 5, previous: (1, 500, t0), now: now, speedMps: 20))
    }

    func testRoadApproachMeasuresAlongTheRoad() throws {
        let line = north(metres: 1500)
        var previous: RoadHistory?
        var last: RoadMatch?
        for i in 0..<5 {
            let pos = Geo.destination(from: line.vertices[0], bearingDegrees: 0, metres: 800 + Double(i) * 25)
            let fix = makeFix(pos, t: t0.addingTimeInterval(Double(i)), speed: 25, course: 0)
            last = RoadApproach.evaluate(approaches: [line], fix: fix, courseDegrees: 0, speedMps: 25, previous: previous, warnDistance: 625)
            previous = last?.history
        }
        let m = try XCTUnwrap(last)
        XCTAssertEqual(m.distanceMetres, 600, accuracy: 3)
        XCTAssertEqual(m.approach.level, .full)
        XCTAssertFalse(m.approach.late)
        XCTAssertTrue(m.approach.directionMatch)
    }

    // MARK: Geometry and index

    func testTheFixtureLoadsAndIndexesItsLineInChunks() throws {
        let roads = try Fixtures.roads()
        XCTAssertEqual(roads.count, 8)
        XCTAssertEqual(roads.approaches(for: "fixed-dual-high-road")?.count, 1)
        let line = try XCTUnwrap(roads.line(for: "dgt_invive-curve-road"))
        XCTAssertEqual(line.length, 9368, accuracy: 30)
        XCTAssertEqual(roads.gates(for: "dgt_invive-curve-road")?.start.count, 1)
        XCTAssertNil(roads.approaches(for: "dgt_invive-curve-road"))
        XCTAssertNil(roads.line(for: "fixed-arc-road"))
        XCTAssertNil(roads.approaches(for: "dgt-CABINACINEMOMETRO_120001"), "a radar with no entry runs today's rules")
        let second = try XCTUnwrap(roads.line(for: "dgt_invive-switchback-road"))
        XCTAssertEqual(roads.boxCount, Int((line.length / Thresholds.roadChunkM).rounded(.up)) + Int((second.length / Thresholds.roadChunkM).rounded(.up)), "pieces of at most 2 km")
        // The middle of the bow, 2 km off the chord: found through the road's boxes.
        let middle = line.coordinate(atAlong: line.length / 2)
        XCTAssertEqual(roads.lineCandidates(near: middle, within: 500), ["dgt_invive-curve-road"])
        XCTAssertEqual(roads.lineCandidates(near: Geo.destination(from: middle, bearingDegrees: 0, metres: 5000), within: 500), [])
    }

    func testShapesGivenAsValuesAreServedAsIs() throws {
        let line = north()
        let roads = RoadGeometry(shapes: ["a": .approaches([line]), "l": .line(line, gatesStart: [], gatesEnd: [line])])
        XCTAssertEqual(roads.approaches(for: "a"), [line])
        XCTAssertEqual(roads.gates(for: "l")?.end, [line])
        XCTAssertEqual(roads.lineCandidates(near: line.vertices[0], within: 100), ["l"])
    }

    // MARK: Validator (each refusal is a check that can fail: the fixture passes the same code)

    private func file(entries: Int, version: Int = 1, brokenGate: Bool = false) -> Data {
        let good = Polyline.encode([.at(40, -3), .at(40.01, -3)])
        var features: [String: Any] = [:]
        for i in 0..<entries { features["r\(i)"] = ["approaches": [["polyline": good, "bearing": 0]]] }
        if brokenGate {
            features["line"] = ["line": good, "gates": ["start": [["polyline": "_p~iF"]], "end": []]]
        }
        return try! JSONSerialization.data(withJSONObject: ["version": version, "precision": 5, "attribution": "x", "features": features])
    }

    func testTheValidatorAcceptsAGoodFile() throws {
        guard case .success(let roads) = RoadsValidator.validate(file(entries: 500)) else { return XCTFail("refused a good file") }
        XCTAssertEqual(roads.count, 500)
    }

    func testTheValidatorRefusesVersionTwo() {
        XCTAssertEqual(failure(RoadsValidator.validate(file(entries: 500, version: 2))), .wrongVersion(2))
    }

    func testTheValidatorRefusesFourHundredNinetyNineEntries() {
        XCTAssertEqual(failure(RoadsValidator.validate(file(entries: 499))), .tooFewEntries(499))
    }

    func testTheValidatorRefusesABrokenGatePolyline() {
        XCTAssertEqual(failure(RoadsValidator.validate(file(entries: 500, brokenGate: true))), .brokenPolyline(id: "line"))
    }

    /// An entry whose approaches were all omitted (under 200 m) does not refuse the file, and does not count toward
    /// the floor; RoadGeometry skips it the same way.
    func testTheValidatorSkipsAnEntryWithNoPolyline() throws {
        var doc = try XCTUnwrap(JSONSerialization.jsonObject(with: file(entries: 500)) as? [String: Any])
        var features = try XCTUnwrap(doc["features"] as? [String: Any])
        features["empty"] = ["approaches": [Any]()]
        doc["features"] = features
        let data = try JSONSerialization.data(withJSONObject: doc)
        guard case .success(let roads) = RoadsValidator.validate(data) else { return XCTFail("one empty entry refused the file") }
        XCTAssertEqual(roads.count, 500)
        XCTAssertNil(roads.approaches(for: "empty"))
        // 499 good entries plus an empty one are under the floor: the empty one is not counted.
        var short = try XCTUnwrap(JSONSerialization.jsonObject(with: file(entries: 499)) as? [String: Any])
        var shortFeatures = try XCTUnwrap(short["features"] as? [String: Any])
        shortFeatures["empty"] = ["approaches": [Any]()]
        short["features"] = shortFeatures
        XCTAssertEqual(failure(RoadsValidator.validate(try JSONSerialization.data(withJSONObject: short))), .tooFewEntries(499))
    }

    func testTheValidatorRefusesAFileOverFourMegabytes() {
        XCTAssertEqual(failure(RoadsValidator.validate(Data(count: 4_000_001))), .tooLarge(4_000_001))
        // Exactly the limit is a size it accepts (and then fails as JSON, which proves the size test passed).
        if case .tooLarge? = failure(RoadsValidator.validate(Data(count: 4_000_000))) { XCTFail("4,000,000 bytes is allowed") }
    }

    func testTheValidatorChecksTheFixtureLikeAnyFile() throws {
        // The fixture has eight entries, under the floor: the same code that accepts 500 good ones refuses it.
        XCTAssertEqual(failure(RoadsValidator.validate(try Fixtures.roadsData())), .tooFewEntries(8))
    }

    private func failure(_ r: Result<RoadGeometry, RoadsError>) -> RoadsError? {
        if case .failure(let e) = r { return e }
        return nil
    }

    // MARK: Shapes written before this change

    func testALedgerWrittenBy013Decodes() throws {
        // PassLedger as 0.1.3 writes it (JSONEncoder, default dates): entries without held or hidden, a stretch whose
        // radar has no directionConfidence.
        let json = """
        {"entries":[{"id":"dgt-1","firedAt":800000000,"level":"full","farthestMetres":120,"passedAt":800000040},
        {"id":"osm-2","firedAt":800000100,"level":"visual","farthestMetres":0}],
        "stretch":{"radar":{"id":"c","kind":"stretch","role":"mobileCorridor","start":{"latitude":41,"longitude":-1},
        "end":{"latitude":41.1,"longitude":-1},"chordMetres":11000,"name":"c","bidirectional":false,"active":true,
        "source":"dgt_invive","attribution":""},"enteredAt":800000000,"entryGate":{"latitude":41,"longitude":-1}}}
        """
        let ledger = try JSONDecoder().decode(PassLedger.self, from: Data(json.utf8))
        XCTAssertEqual(ledger.entries.count, 2)
        XCTAssertNil(ledger.entries[1].held)
        XCTAssertNil(ledger.entries[1].hidden)
        XCTAssertNil(ledger.stretch?.radar.directionConfidence)
        let tracker = PassTracker(ledger: ledger)
        XCTAssertFalse(tracker.canUpgrade("osm-2"), "a 0.1.3 visual fire is not held")
        // And the new fields round-trip.
        var t = PassTracker(ledger: PassLedger())
        t.fire("h", level: .visual, held: true, now: t0)
        let back = try JSONDecoder().decode(PassLedger.self, from: JSONEncoder().encode(t.ledger))
        XCTAssertEqual(back.entries.first?.held, true)
    }

    func testFeedMetaWithoutTheRoadKeysDecodes() throws {
        let json = #"{"featureCount":4500,"countsByKind":["fixed",2900],"consecutiveFailures":0,"etag":"\"abc\""}"#
        let meta = try JSONDecoder().decode(FeedMeta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.featureCount, 4500)
        XCTAssertNil(meta.roadsEtag)
        XCTAssertNil(meta.roadsCheckedAt)
    }

    func testAlertEventWithAndWithoutHeldAndHiddenDecodes() throws {
        let content = DriveContent(phase: .alert, kindSymbol: "camera.fill", title: "Radar fijo", subtitle: "", opposite: true, updatedAt: t0, held: true, hidden: false)
        let event = AlertEvent(kind: .warn(.visual), radar: makeRadar(), distance: 600, content: content)
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(AlertEvent.self, from: data), event)
        // The same JSON as 0.1.3 writes it: no held, no hidden.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var c = try XCTUnwrap(object["content"] as? [String: Any])
        c.removeValue(forKey: "held")
        c.removeValue(forKey: "hidden")
        object["content"] = c
        let old = try JSONDecoder().decode(AlertEvent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(old.content.held)
        XCTAssertFalse(old.content.hidden)
    }

    // MARK: Passes

    func testAHeldFireUpgradesOnceAndAHiddenFireIsMarked() {
        var t = PassTracker(ledger: PassLedger())
        t.fire("r", level: .visual, held: true, now: t0)
        XCTAssertTrue(t.canUpgrade("r"))
        XCTAssertFalse(t.canFire("r", now: t0))
        t.upgrade("r")
        XCTAssertEqual(t.ledger.entry(for: "r")?.level, .full)
        XCTAssertFalse(t.canUpgrade("r"), "exactly one upgrade per pass")
        t.fire("o", level: .visual, now: t0)
        XCTAssertFalse(t.canUpgrade("o"), "an opposite or paced visual fire is not held")
        XCTAssertNil(t.ledger.entry(for: "o")?.held, "nothing new is written for a plain fire")
        t.fire("h", level: .visual, hidden: true, now: t0)
        XCTAssertTrue(t.isHidden("h"))
        XCTAssertFalse(t.isHidden("o"))
        t.fire("p", level: .visual, held: true, now: t0)
        t.markPassed("p", now: t0)
        XCTAssertFalse(t.canUpgrade("p"), "no upgrade after the pass")
    }
}

final class TravelBearingDecoderTests: XCTestCase {
    private func decode(_ props: String) throws -> Radar {
        let json = """
        {"type":"FeatureCollection","features":[{"type":"Feature","id":"x","geometry":{"type":"Point","coordinates":[-3,40]},
        "properties":{"kind":"fixed","source":"dgt",\(props)}}]}
        """
        return try XCTUnwrap(FeedDecoder.decode(Data(json.utf8)).first)
    }

    func testTheTravelBearingWinsOverTheNumericDirection() throws {
        let r = try decode(#""direction":"-40","bearing":95,"direction_semantics":"travel","direction_confidence":"high","bearing_source":"official_km","road_ref":"A-7","km":12.5,"km_direction":"positive""#)
        XCTAssertEqual(r.bearing, 95)
        XCTAssertFalse(r.bidirectional)
        XCTAssertEqual(r.directionConfidence, .high)
        XCTAssertNil(r.road, "road_ref never becomes the notification's road")
    }

    func testTheTravelBearingOverridesBothAndKeepsThePlaceName() throws {
        let both = try decode(#""direction":"both","bearing":-10,"direction_semantics":"travel","direction_confidence":"low""#)
        XCTAssertEqual(both.bearing, 350)
        XCTAssertFalse(both.bidirectional)
        XCTAssertEqual(both.directionConfidence, .low)
        let named = try decode(#""direction":"ZARAGOZA","bearing":60,"direction_semantics":"travel","direction_confidence":"high""#)
        XCTAssertEqual(named.directionText, "ZARAGOZA", "the place name is still spoken")
        XCTAssertEqual(named.bearing, 60)
    }

    func testConfidenceMapping() throws {
        XCTAssertEqual(try decode(#""bearing":10,"direction_semantics":"travel","direction_confidence":"maybe""#).directionConfidence, .low, "unknown reads as low")
        XCTAssertEqual(try decode(#""bearing":10,"direction_semantics":"travel""#).directionConfidence, .low)
        // A bearing without "travel" semantics is ignored: today's numeric direction and no confidence.
        let other = try decode(#""direction":"-40","bearing":10,"direction_semantics":"heading","direction_confidence":"high""#)
        XCTAssertEqual(other.bearing, 320)
        XCTAssertNil(other.directionConfidence)
        let none = try decode(#""direction":"-40""#)
        XCTAssertEqual(none.bearing, 320)
        XCTAssertNil(none.directionConfidence)
    }

    func testARadarEncodedBy013Decodes() throws {
        let json = #"{"id":"a","kind":"fixed","role":"point","start":{"latitude":40,"longitude":-3},"name":"a","bearing":320,"bidirectional":false,"active":true,"source":"osm","attribution":""}"#
        let r = try JSONDecoder().decode(Radar.self, from: Data(json.utf8))
        XCTAssertEqual(r.bearing, 320)
        XCTAssertNil(r.directionConfidence)
    }
}
