// SPDX-License-Identifier: GPL-3.0-or-later
//
// The decoded feed every part of the app reads (drive, map, Fuentes, car screen), and the one refresh path
// (SPEC 1): conditional GET, validation by the core, atomic replace, swap in memory, log. A failure keeps the old
// file and counts a failure; stale data never disables alerts. One download at a time.

package io.github.geiserx.radares.feed

import io.github.geiserx.radares.core.feed.FeedMeta
import io.github.geiserx.radares.core.feed.FeedRefreshPolicy
import io.github.geiserx.radares.core.feed.FeedValidation
import io.github.geiserx.radares.core.feed.FeedValidator
import io.github.geiserx.radares.core.feed.RadarStore
import io.github.geiserx.radares.health.AppEvents
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.time.Instant

class FeedRepository(
    private val files: FeedStore,
    private val client: FeedSource,
    private val events: AppEvents,
    private val clock: () -> Instant = Instant::now,
) {
    private val current = MutableStateFlow<RadarStore?>(null)
    private val lock = Any()

    /** The radars in memory; null until the first load. */
    val store: StateFlow<RadarStore?> = current.asStateFlow()

    /** Loads feed.geojson once per process (the caller copied the snapshot first). */
    fun loadIfNeeded(): RadarStore? {
        current.value?.let { return it }
        synchronized(lock) {
            current.value?.let { return it }
            val loaded = files.load()
            if (loaded == null) events.feedFailed("no readable feed on disk")
            current.value = loaded
            return loaded
        }
    }

    fun meta(): FeedMeta = files.readMeta()

    /**
     * Runs the first-launch snapshot copy under the same lock as the load and the refresh: the app start and the
     * refresh worker both call it, and two copies at once would race on feed.geojson.new.
     */
    fun <T> exclusive(block: () -> T): T = synchronized(lock) { block() }

    fun refreshIfNeeded(trigger: FeedRefreshPolicy.Trigger): Boolean {
        if (!FeedRefreshPolicy.shouldRefresh(files.readMeta(), clock(), trigger)) return false
        refresh()
        return true
    }

    /** One conditional GET; returns true when a new body was installed. */
    fun refresh(): Boolean = synchronized(lock) {
        var meta = files.readMeta()
        val now = clock()
        // Without a feed on disk an ETag would get a 304 and nothing to keep.
        val etag = if (files.hasFeed()) meta.etag else null
        try {
            when (val fetched = client.fetch(etag)) {
                FeedFetch.NotModified -> {
                    files.writeMeta(meta.copy(checkedAt = now, lastError = null, consecutiveFailures = 0))
                    events.feedChecked(etag, notModified = true)
                    false
                }
                is FeedFetch.Updated -> when (val v = FeedValidator.validate(fetched.body)) {
                    is FeedValidation.Valid -> {
                        files.replace(v.feed.data)
                        current.value = RadarStore(v.feed.radars)
                        meta = FeedMeta(
                            etag = fetched.etag, lastModified = fetched.lastModified, fetchedAt = now, checkedAt = now,
                            featureCount = v.feed.radars.size, countsByKind = v.feed.countsByKind,
                        )
                        files.writeMeta(meta)
                        events.feedChecked(fetched.etag, notModified = false)
                        events.feedUpdated(v.feed.radars.size, fetched.etag)
                        true
                    }
                    is FeedValidation.Invalid -> fail(meta, v.error.toString(), now)
                }
            }
        } catch (e: Exception) {
            fail(meta, "${e.javaClass.simpleName}: ${e.message}", now)
        }
    }

    private fun fail(meta: FeedMeta, message: String, now: Instant): Boolean {
        files.writeMeta(meta.copy(checkedAt = now, lastError = message.take(300), consecutiveFailures = meta.consecutiveFailures + 1))
        events.feedFailed(message.take(300))
        return false
    }
}
