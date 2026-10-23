// SPDX-License-Identifier: GPL-3.0-or-later
//
// The real HttpURLConnection client against a local server: 200 with an ETag, 304 on If-None-Match, a timeout,
// an HTTP error, and a 200 whose body is not JSON (the client hands it over; the validator refuses it).

package io.github.geiserx.radares.feed

import com.sun.net.httpserver.HttpServer
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.net.URL

class FeedClientTest {
    private val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
    private var lastAccept: String? = null
    private var mode = "ok"

    init {
        server.createContext("/feed.geojson") { ex ->
            lastAccept = ex.requestHeaders.getFirst("Accept")
            val inm = ex.requestHeaders.getFirst("If-None-Match")
            when {
                mode == "slow" -> {
                    Thread.sleep(1500)
                    ex.sendResponseHeaders(200, -1)
                }
                mode == "error" -> ex.sendResponseHeaders(503, -1)
                inm == "\"v1\"" -> ex.sendResponseHeaders(304, -1)
                else -> {
                    val body = if (mode == "bad") "<html>nope</html>".toByteArray() else """{"type":"FeatureCollection","features":[]}""".toByteArray()
                    ex.responseHeaders.add("ETag", "\"v1\"")
                    ex.responseHeaders.add("Last-Modified", "Thu, 23 Oct 2026 10:00:00 GMT")
                    ex.sendResponseHeaders(200, body.size.toLong())
                    ex.responseBody.use { it.write(body) }
                }
            }
            ex.close()
        }
        server.start()
    }

    private val client = FeedClient(URL("http://127.0.0.1:${server.address.port}/feed.geojson"), timeoutMs = 500)

    @AfterEach
    fun stop() = server.stop(0)

    @Test
    fun okReturnsTheBodyAndTheEtag() {
        val r = client.fetch(null) as FeedFetch.Updated
        assertArrayEquals("""{"type":"FeatureCollection","features":[]}""".toByteArray(), r.body)
        assertEquals("\"v1\"", r.etag)
        assertEquals("Thu, 23 Oct 2026 10:00:00 GMT", r.lastModified)
        assertEquals("application/geo+json, application/json", lastAccept)
    }

    @Test
    fun aMatchingEtagIsNotModified() {
        assertEquals(FeedFetch.NotModified, client.fetch("\"v1\""))
    }

    @Test
    fun aSlowServerTimesOut() {
        mode = "slow"
        assertThrows<SocketTimeoutException> { client.fetch(null) }
    }

    @Test
    fun anHttpErrorThrowsWithTheStatus() {
        mode = "error"
        assertEquals(503, assertThrows<FeedHttpException> { client.fetch(null) }.status)
    }

    @Test
    fun aBodyThatIsNotJsonIsHandedOverForTheValidatorToRefuse() {
        mode = "bad"
        val r = client.fetch(null)
        assertTrue(r is FeedFetch.Updated)
    }
}
