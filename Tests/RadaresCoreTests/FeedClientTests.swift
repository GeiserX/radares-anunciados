// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The conditional GET against a stub URLProtocol: no network, ever.

import XCTest
@testable import RadaresCore

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let handler = Self.handler, let url = request.url else { return }
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class FeedClientTests: XCTestCase {
    var client: FeedClient!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        client = FeedClient(session: URLSession(configuration: config))
        StubProtocol.lastRequest = nil
    }

    func testRequestCarriesTheEtagTimeoutAndCellular() {
        let r = client.request(ifNoneMatch: "\"abc\"")
        XCTAssertEqual(r.value(forHTTPHeaderField: "If-None-Match"), "\"abc\"")
        XCTAssertEqual(r.timeoutInterval, Thresholds.feedTimeoutSeconds)
        XCTAssertTrue(r.allowsCellularAccess)
        XCTAssertEqual(r.url, FeedClient.feedURL)
        XCTAssertEqual(r.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(client.request(ifNoneMatch: nil).value(forHTTPHeaderField: "If-None-Match"))
    }

    func testNotModified() async throws {
        StubProtocol.handler = { _ in (304, [:], Data()) }
        guard case .notModified = try await client.fetch(ifNoneMatch: "\"x\"") else { return XCTFail("expected notModified") }
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "If-None-Match"), "\"x\"")
    }

    func testUpdatedCarriesBodyEtagAndLastModified() async throws {
        let body = try Fixtures.feedData()
        StubProtocol.handler = { _ in (200, ["ETag": "\"6ac5e2b4-2cad5a\"", "Last-Modified": "Wed, 07 Oct 2026 06:12:04 GMT"], body) }
        guard case .updated(let data, let etag, let lastModified) = try await client.fetch(ifNoneMatch: nil) else { return XCTFail("expected updated") }
        XCTAssertEqual(data, body)
        XCTAssertEqual(etag, "\"6ac5e2b4-2cad5a\"")
        XCTAssertEqual(lastModified, "Wed, 07 Oct 2026 06:12:04 GMT")
    }

    func testAServerErrorThrows() async {
        StubProtocol.handler = { _ in (503, [:], Data()) }
        do {
            _ = try await client.fetch(ifNoneMatch: nil)
            XCTFail("a 503 must throw")
        } catch let error as FeedClientError {
            XCTAssertEqual(error, .httpStatus(503))
        } catch {
            XCTFail("\(error)")
        }
    }
}
