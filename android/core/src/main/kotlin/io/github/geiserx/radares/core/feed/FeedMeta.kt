// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Feed/FeedMeta.swift.
// feed.meta.json (design 5.3). Feed age comes from here, never from file dates.

@file:UseSerializers(InstantSerializer::class)

package io.github.geiserx.radares.core.feed

import io.github.geiserx.radares.core.InstantSerializer
import io.github.geiserx.radares.core.model.Kind
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import kotlinx.serialization.json.Json
import java.time.Instant

@Serializable
data class FeedMeta(
    val etag: String? = null,
    val lastModified: String? = null,
    /// When a 200 body was last stored.
    val fetchedAt: Instant? = null,
    /// When the server was last asked (200 or 304).
    val checkedAt: Instant? = null,
    val featureCount: Int = 0,
    val countsByKind: Map<Kind, Int> = emptyMap(),
    val lastError: String? = null,
    val consecutiveFailures: Int = 0,
) {
    fun encode(): String = json.encodeToString(serializer(), this)

    companion object {
        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

        /// A missing or unreadable file reads as an empty meta: the next refresh asks for the feed.
        fun decode(text: String): FeedMeta = try {
            json.decodeFromString(serializer(), text)
        } catch (e: Exception) {
            FeedMeta()
        }
    }
}
