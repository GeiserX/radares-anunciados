// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The five checks of design 5.1: parses, FeatureCollection, at least Thresholds.feedMinFeatures features,
// at least one fixed, every feature has id, kind and geometry. A failed validation keeps the old file.

import Foundation

public struct ValidatedFeed: Sendable {
    public let data: Data
    public let radars: [Radar]
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
        fatalError("lane: core")
    }
}
