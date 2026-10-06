// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// One conditional GET of the public feed (design 5.1): If-None-Match, Thresholds.feedTimeoutSeconds, cellular allowed.

import Foundation

public enum FeedFetch: Sendable {
    case notModified
    case updated(Data, etag: String?, lastModified: String?)
}

public struct FeedClient: Sendable {
    public static let feedURL = URL(string: "https://geiserx.github.io/radares-anunciados-ha/feed.geojson")!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(ifNoneMatch etag: String?) async throws -> FeedFetch {
        fatalError("lane: core")
    }
}
