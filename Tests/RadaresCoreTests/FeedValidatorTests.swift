// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RadaresCore

final class FeedValidatorTests: XCTestCase {
    func testATruncatedFileIsNotJSON() throws {
        let data = try Fixtures.feedData().prefix(5000)
        guard case .failure(let error) = FeedValidator.validate(Data(data)) else { return XCTFail("accepted a truncated file") }
        guard case .notJSON = error else { return XCTFail("\(error)") }
    }

    func testNotAFeatureCollection() {
        let data = Data(#"{"type":"Feature","features":[]}"#.utf8)
        XCTAssertEqual(FeedValidator.validate(data).failureError, .notFeatureCollection)
    }

    func testAThousandFeaturesAreTooFew() throws {
        let data = try Fixtures.syntheticFeed(count: 1000)
        XCTAssertEqual(FeedValidator.validate(data).failureError, .tooFewFeatures(1000))
    }

    func testAFileWithoutAFixedRadarFails() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.syntheticFeed(count: 2100)) as? [String: Any])
        var features = try XCTUnwrap(json["features"] as? [[String: Any]])
        for i in features.indices {
            var props = features[i]["properties"] as? [String: Any] ?? [:]
            if props["kind"] as? String == "fixed" { props["kind"] = "trailer" }
            features[i]["properties"] = props
        }
        let data = try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
        XCTAssertEqual(FeedValidator.validate(data).failureError, .noFixedRadar)
    }

    func testAFeatureWithoutIdKindOrGeometryFails() throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("id", { f in f.removeValue(forKey: "id") }),
            ("kind", { f in
                var p = f["properties"] as! [String: Any]
                p.removeValue(forKey: "kind")
                f["properties"] = p
            }),
            ("geometry", { f in f["geometry"] = NSNull() }),
        ]
        for (field, mutate) in mutations {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.syntheticFeed(count: 2100)) as? [String: Any])
            var features = try XCTUnwrap(json["features"] as? [[String: Any]])
            mutate(&features[1700])
            let data = try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
            guard case .failure(.featureMissingField(_, let missing)) = FeedValidator.validate(data) else { return XCTFail("accepted a feature without \(field)") }
            XCTAssertEqual(missing, field)
        }
    }

    func testAFeedSizedFilePasses() throws {
        let data = try Fixtures.syntheticFeed(count: 4500)
        guard case .success(let feed) = FeedValidator.validate(data) else { return XCTFail("rejected a good file") }
        XCTAssertEqual(feed.data, data)
        XCTAssertGreaterThanOrEqual(feed.radars.count, 3600)
        let fixed = try XCTUnwrap(feed.countsByKind[.fixed])
        XCTAssertGreaterThanOrEqual(fixed, 109 * 17, "17 full copies of the fixture plus part of an 18th")
        XCTAssertLessThanOrEqual(fixed, 109 * 18)
        XCTAssertLessThanOrEqual(feed.countsByKind[.section] ?? 0, 4 * 18, "twins fold in a feed-sized file too")
    }
}

extension Result where Failure == FeedError {
    var failureError: FeedError? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
