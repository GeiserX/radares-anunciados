// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Budgets of design 5.4 and 10: ingest under 10 ms per fix on a feed-sized store, decode under 500 ms.
// Both run offline on a 4,500-feature file built from the fixture. Decoding the live feed is opt-in
// (RADARES_LIVE_FEED=1) because CI and the package tests never touch the network.

import XCTest
@testable import RadaresCore

func milliseconds(_ d: Duration) -> Double {
    let seconds = Double(d.components.seconds)
    let attoseconds = Double(d.components.attoseconds)
    return seconds * 1000 + attoseconds / 1e15
}

final class PerformanceTests: XCTestCase {
    func testIngestOnAFeedSizedStoreStaysUnderTenMillisecondsPerFix() throws {
        let store = try RadarStore.load(geojson: Fixtures.syntheticFeed(count: 4500))
        XCTAssertGreaterThanOrEqual(store.count, 3600)
        let vector = try Vector.load("a2-120kmh-ne")
        let fixes = vector.fixList
        let engine = AlertEngine(store: store, ledger: PassLedger(), locale: Fixtures.es)
        let clock = ContinuousClock()
        var events = 0
        let elapsed = clock.measure {
            for fix in fixes { events += engine.ingest(fix).count }
        }
        let perFix = milliseconds(elapsed) / Double(fixes.count)
        XCTAssertLessThan(perFix, 10, "ingest took \(perFix) ms per fix")
        XCTAssertGreaterThan(events, 0, "the drive still warns on the big store")
    }

    /// The feed-sized store plus a sidecar entry for every synthetic copy of the road scenarios: one road drive at a
    /// time stays under the same 10 ms per fix.
    func testIngestWithRoadGeometryStaysUnderTenMillisecondsPerFix() throws {
        let base = try FeedDecoder.decode(Fixtures.syntheticFeed(count: 4500))
        let roadRadars = try FeedDecoder.decode(Data(contentsOf: Fixtures.url("feed-sample-roads", ext: "geojson")))
        let sample = try Fixtures.roads()
        var shapes: [String: RoadShape] = [:]
        for r in roadRadars { shapes[r.id] = sample.shape(for: r.id) }
        // Every synthetic copy of a feed-sample point gets the arc's approach and every line the bowed corridor's
        // geometry, so the store is as polyline-laden as the live sidecar for its size.
        let arc = try XCTUnwrap(sample.approaches(for: "fixed-arc-road"))
        let curve = try XCTUnwrap(sample.shape(for: "dgt_invive-curve-road"))
        for r in base { shapes[r.id] = r.isLine ? curve : .approaches(arc) }
        let roads = RoadGeometry(shapes: shapes)
        let store = RadarStore(radars: base + roadRadars)
        // The A-2 drive: about twenty copies of the radar stand at that spot, each with an approach to project onto.
        let vector = try Vector.load("a2-120kmh-ne")
        let fixes = vector.fixList
        let engine = AlertEngine(store: store, roads: roads, ledger: PassLedger(), locale: Fixtures.es)
        let clock = ContinuousClock()
        var events = 0
        let elapsed = clock.measure {
            for fix in fixes { events += engine.ingest(fix).count }
        }
        let perFix = milliseconds(elapsed) / Double(fixes.count)
        print("road ingest: \(perFix) ms per fix over \(fixes.count) fixes, \(shapes.count) shapes")
        XCTAssertLessThan(perFix, 10, "ingest took \(perFix) ms per fix")
        XCTAssertGreaterThan(events, 0)
    }

    /// A 1.5 MB sidecar in the live file's shape: the decode (strings kept, lines indexed) stays under 500 ms.
    func testDecodeOfASidecarSizedFileStaysUnderHalfASecond() throws {
        let sample = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.roadsData()) as? [String: Any])
        let entries = try XCTUnwrap(sample["features"] as? [String: Any])
        var features: [String: Any] = [:]
        var copy = 0
        var data = Data()
        repeat {
            for (id, entry) in entries { features["\(id)#\(copy)"] = entry }
            copy += 1
            if copy % 50 == 0 {
                data = try JSONSerialization.data(withJSONObject: ["version": 1, "precision": 5, "attribution": "x", "features": features])
            }
        } while data.count < 1_500_000
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure {
            if case .success(let roads) = RoadsValidator.validate(data) { count = roads.count }
        }
        let ms = milliseconds(elapsed)
        print("sidecar validate+decode: \(ms) ms for \(data.count) bytes, \(count) entries")
        XCTAssertGreaterThan(count, 500)
        XCTAssertLessThan(ms, 500, "sidecar decode took \(ms) ms")
    }

    func testDecodeOfAFeedSizedFileStaysUnderHalfASecond() throws {
        let data = try Fixtures.syntheticFeed(count: 4500)
        XCTAssertGreaterThan(data.count, 2_000_000, "the synthetic file is about the size of the live feed")
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure { count = (try? FeedDecoder.decode(data))?.count ?? 0 }
        let ms = milliseconds(elapsed)
        XCTAssertGreaterThanOrEqual(count, 3600)
        XCTAssertLessThan(ms, 500, "decode took \(ms) ms")
    }

    func testDecodeOfTheLiveFeedWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["RADARES_LIVE_FEED"] == "1" else {
            throw XCTSkip("set RADARES_LIVE_FEED=1 to download and decode the live feed; CI runs offline")
        }
        var request = URLRequest(url: FeedClient.feedURL)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let clock = ContinuousClock()
        var radars: [Radar] = []
        let elapsed = clock.measure { radars = (try? FeedDecoder.decode(data)) ?? [] }
        let ms = milliseconds(elapsed)
        XCTAssertGreaterThanOrEqual(radars.count, Thresholds.feedMinFeatures)
        XCTAssertLessThan(ms, 500, "live decode took \(ms) ms for \(data.count) bytes")
        guard case .success(let feed) = FeedValidator.validate(data) else { return XCTFail("the live feed must validate") }
        XCTAssertGreaterThan(feed.countsByKind[.fixed] ?? 0, 2000)
    }
}
