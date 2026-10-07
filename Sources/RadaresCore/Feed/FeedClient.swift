// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// One conditional GET of the public feed (design 5.1): If-None-Match, Thresholds.feedTimeoutSeconds, cellular allowed.
// No background URLSession: the transfer fits inside a BGAppRefreshTask or a running drive. Nothing but the
// request itself leaves the phone: no identifiers, no location.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum FeedFetch: Sendable {
    case notModified
    case updated(Data, etag: String?, lastModified: String?)
}

public enum FeedClientError: Error, Sendable, Hashable {
    case notHTTP
    case httpStatus(Int)
}

public struct FeedClient: Sendable {
    public static let feedURL = URL(string: "https://geiserx.github.io/radares-anunciados-ha/feed.geojson")!

    private let session: URLSession
    private let url: URL

    public init(session: URLSession = .shared, url: URL = FeedClient.feedURL) {
        self.session = session
        self.url = url
    }

    /// The request as sent, so a test can check the headers without a network.
    public func request(ifNoneMatch etag: String?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Thresholds.feedTimeoutSeconds)
        request.httpMethod = "GET"
        request.allowsCellularAccess = true
        request.setValue("application/geo+json, application/json", forHTTPHeaderField: "Accept")
        if let etag, !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    public func fetch(ifNoneMatch etag: String?) async throws -> FeedFetch {
        let (data, response) = try await session.data(for: request(ifNoneMatch: etag))
        guard let http = response as? HTTPURLResponse else { throw FeedClientError.notHTTP }
        switch http.statusCode {
        case 304:
            return .notModified
        case 200:
            return .updated(data, etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        default:
            throw FeedClientError.httpStatus(http.statusCode)
        }
    }
}
