// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RadaresCore

final class FeedDecoderTests: XCTestCase {
    /// The fixture is reachable from the test bundle and is a FeatureCollection. The core lane replaces the
    /// placeholder fixture with about 250 real features and asserts the decoded counts.
    func testFixtureIsAFeatureCollection() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "feed-sample", withExtension: "geojson", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "FeatureCollection")
        let features = try XCTUnwrap(json["features"] as? [[String: Any]])
        XCTAssertEqual(features.count, 3)
    }

    func testDecodePlaceholder() throws {
        throw XCTSkip("lane: core")
    }
}
