// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// One conditional GET of the road sidecar (design 5.1), the FeedClient pattern with its own URL and ETag:
// If-None-Match, Thresholds.feedTimeoutSeconds, cellular allowed. The file changes only when roads or radars change,
// so most refreshes end in a 304.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RoadsClient: Sendable {
    public static let roadsURL = URL(string: "https://geiserx.github.io/radares-anunciados-ha/roads.json")!

    private let client: FeedClient

    public init(session: URLSession = .shared, url: URL = RoadsClient.roadsURL) {
        client = FeedClient(session: session, url: url)
    }

    public func request(ifNoneMatch etag: String?) -> URLRequest {
        client.request(ifNoneMatch: etag)
    }

    public func fetch(ifNoneMatch etag: String?) async throws -> FeedFetch {
        try await client.fetch(ifNoneMatch: etag)
    }
}
