// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The five checks of design 5.1: parses, FeatureCollection, at least Thresholds.feedMinFeatures features,
// at least one fixed, every feature has id, kind and geometry. A failed validation keeps the old file.

import Foundation

public struct ValidatedFeed: Sendable {
    public let data: Data
    public let radars: [Radar]
    /// Radars per kind after decoding (section twins already folded into their stretch).
    public let countsByKind: [Kind: Int]

    public init(data: Data, radars: [Radar], countsByKind: [Kind: Int]) {
        self.data = data
        self.radars = radars
        self.countsByKind = countsByKind
    }
}

public enum FeedError: Error, Sendable, Hashable {
    case notJSON(String)
    case notFeatureCollection
    case tooFewFeatures(Int)
    case noFixedRadar
    case featureMissingField(id: String?, field: String)
}

public struct FeedValidator: Sendable {
    public static func validate(_ data: Data) -> Result<ValidatedFeed, FeedError> {
        let collection: GeoJSONFeatureCollection
        do {
            collection = try JSONDecoder().decode(GeoJSONFeatureCollection.self, from: data)
        } catch {
            return .failure(.notJSON(String(describing: error).prefix(200).description))
        }
        guard collection.type == "FeatureCollection" else { return .failure(.notFeatureCollection) }
        guard collection.features.count >= Thresholds.feedMinFeatures else {
            return .failure(.tooFewFeatures(collection.features.count))
        }
        guard collection.features.contains(where: { $0.properties?.kind == Kind.fixed.rawValue }) else {
            return .failure(.noFixedRadar)
        }
        for feature in collection.features {
            guard let id = feature.id, !id.isEmpty else { return .failure(.featureMissingField(id: nil, field: "id")) }
            guard let kind = feature.properties?.kind, !kind.isEmpty else { return .failure(.featureMissingField(id: id, field: "kind")) }
            guard feature.geometry != nil else { return .failure(.featureMissingField(id: id, field: "geometry")) }
        }
        let radars = FeedDecoder.radars(from: collection)
        var counts: [Kind: Int] = [:]
        for radar in radars { counts[radar.kind, default: 0] += 1 }
        return .success(ValidatedFeed(data: data, radars: radars, countsByKind: counts))
    }
}
