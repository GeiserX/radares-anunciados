// SPDX-License-Identifier: GPL-3.0-or-later
//
// One conditional GET of the public feed (SPEC 1): If-None-Match, a 15 s timeout, cellular allowed. Nothing but the
// request itself leaves the phone: no identifier, no position.

package io.github.geiserx.radares.feed

import io.github.geiserx.radares.core.Thresholds
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

sealed class FeedFetch {
    data object NotModified : FeedFetch()
    class Updated(val body: ByteArray, val etag: String?, val lastModified: String?) : FeedFetch()
}

/** The one GET the repository needs; a fake in tests. */
fun interface FeedSource {
    fun fetch(ifNoneMatch: String?): FeedFetch
}

class FeedHttpException(val status: Int) : IOException("HTTP $status")

class FeedClient(
    private val url: URL = URL(FEED_URL),
    private val timeoutMs: Int = (Thresholds.feedTimeoutSeconds * 1000).toInt(),
) : FeedSource {
    override fun fetch(ifNoneMatch: String?): FeedFetch {
        val connection = url.openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "GET"
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            connection.useCaches = false
            connection.instanceFollowRedirects = true
            connection.setRequestProperty("Accept", "application/geo+json, application/json")
            if (!ifNoneMatch.isNullOrEmpty()) connection.setRequestProperty("If-None-Match", ifNoneMatch)
            return when (val status = connection.responseCode) {
                HttpURLConnection.HTTP_NOT_MODIFIED -> FeedFetch.NotModified
                HttpURLConnection.HTTP_OK -> FeedFetch.Updated(
                    connection.inputStream.use { it.readBytes() },
                    connection.getHeaderField("ETag"),
                    connection.getHeaderField("Last-Modified"),
                )
                else -> throw FeedHttpException(status)
            }
        } finally {
            connection.disconnect()
        }
    }

    companion object {
        const val FEED_URL = "https://geiserx.github.io/radares-anunciados-ha/feed.geojson"
    }
}
