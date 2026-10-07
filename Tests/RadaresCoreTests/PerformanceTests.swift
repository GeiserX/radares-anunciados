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
