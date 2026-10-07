// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// feed.meta.json (design 5.3). Feed age comes from here, never from file dates.

import Foundation

public struct FeedMeta: Sendable, Codable, Hashable {
    public var etag: String?
    public var lastModified: String?
    /// When a 200 body was last stored.
    public var fetchedAt: Date?
    /// When the server was last asked (200 or 304).
    public var checkedAt: Date?
    public var featureCount: Int
    public var countsByKind: [Kind: Int]
    public var lastError: String?
    public var consecutiveFailures: Int

    public init(
        etag: String? = nil,
        lastModified: String? = nil,
        fetchedAt: Date? = nil,
        checkedAt: Date? = nil,
        featureCount: Int = 0,
        countsByKind: [Kind: Int] = [:],
        lastError: String? = nil,
        consecutiveFailures: Int = 0
    ) {
        self.etag = etag
        self.lastModified = lastModified
        self.fetchedAt = fetchedAt
        self.checkedAt = checkedAt
        self.featureCount = featureCount
        self.countsByKind = countsByKind
        self.lastError = lastError
        self.consecutiveFailures = consecutiveFailures
    }
}
