// SPDX-License-Identifier: GPL-3.0-or-later

package io.github.geiserx.radares.feed

import io.github.geiserx.radares.Fixtures
import io.github.geiserx.radares.RecordingEvents
import io.github.geiserx.radares.core.InstantSerializer
import io.github.geiserx.radares.core.feed.FeedRefreshPolicy
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.io.IOException
import java.time.Instant

class FeedStoreTest {
    @TempDir lateinit var dir: File

    private val snapshot by lazy { File(Fixtures.snapshotDir, "feed-snapshot.geojson").readBytes() }
    private val snapshotDate by lazy { File(Fixtures.snapshotDir, "feed-snapshot.date").readText() }

    @Test
    fun theSnapshotIsCopiedOnFirstLaunchWithItsDateAsFetchedAt() {
        val store = FeedStore(dir)
        assertTrue(store.copySnapshotIfNeeded({ snapshot.inputStream() }, { snapshotDate }))
        assertArrayEquals(snapshot, store.feed.readBytes())
        val meta = store.readMeta()
        assertEquals(InstantSerializer.parseIso(snapshotDate.trim()), meta.fetchedAt)
        assertTrue(meta.featureCount > 2000, "${meta.featureCount}")
        assertNotNull(store.load())
        // Second launch: a feed exists, nothing is copied over it.
        assertFalse(store.copySnapshotIfNeeded({ error("must not read") }, { null }))
    }

    @Test
    fun replaceKeepsThePreviousFileAsBak() {
        val store = FeedStore(dir)
        store.replace("one".toByteArray())
        store.replace("two".toByteArray())
        assertEquals("two", store.feed.readText())
        assertEquals("one", store.backup.readText())
        assertFalse(File(dir, "feed.geojson.new").exists())
    }

    @Test
    fun aValidDownloadIsInstalledAndAnInvalidOneKeepsTheOldFile() {
        val files = FeedStore(dir)
        files.copySnapshotIfNeeded({ snapshot.inputStream() }, { snapshotDate })
        val events = RecordingEvents()
        var body: FeedFetch = FeedFetch.Updated(snapshot, "\"v2\"", null)
        val repo = FeedRepository(files, { body }, events, clock = { Instant.parse("2026-10-23T10:00:00Z") })
        assertTrue(repo.refresh())
        assertEquals("\"v2\"", repo.meta().etag)
        assertEquals(Instant.parse("2026-10-23T10:00:00Z"), repo.meta().fetchedAt)
        assertNotNull(repo.store.value)

        // The 254-feature sample is a valid GeoJSON but under the 2,000-feature floor: refused, old file kept.
        body = FeedFetch.Updated(File(Fixtures.dir, "feed-sample.geojson").readBytes(), "\"bad\"", null)
        assertFalse(repo.refresh())
        assertArrayEquals(snapshot, files.feed.readBytes())
        assertEquals(1, repo.meta().consecutiveFailures)
        assertEquals("\"v2\"", repo.meta().etag)

        body = FeedFetch.Updated("not json".toByteArray(), null, null)
        assertFalse(repo.refresh())
        assertEquals(2, repo.meta().consecutiveFailures)
    }

    @Test
    fun aNotModifiedMovesCheckedAtAndClearsFailures() {
        val files = FeedStore(dir)
        files.copySnapshotIfNeeded({ snapshot.inputStream() }, { snapshotDate })
        var asked: String? = "unset"
        var fail = true
        val repo = FeedRepository(files, { etag ->
            asked = etag
            if (fail) throw IOException("offline") else FeedFetch.NotModified
        }, RecordingEvents(), clock = { Instant.parse("2026-10-23T10:00:00Z") })
        assertFalse(repo.refresh())
        assertEquals(1, repo.meta().consecutiveFailures)
        fail = false
        assertFalse(repo.refresh())
        assertEquals(0, repo.meta().consecutiveFailures)
        assertEquals(Instant.parse("2026-10-23T10:00:00Z"), repo.meta().checkedAt)
        assertEquals(null, asked, "the snapshot has no ETag")
    }

    @Test
    fun theRefreshPolicyDecidesWhetherToAsk() {
        val files = FeedStore(dir)
        files.copySnapshotIfNeeded({ snapshot.inputStream() }, { snapshotDate })
        var calls = 0
        val fetchedAt = InstantSerializer.parseIso(snapshotDate.trim())
        val repo = FeedRepository(files, { calls++; FeedFetch.NotModified }, RecordingEvents(), clock = { fetchedAt.plusSeconds(3600) })
        assertFalse(repo.refreshIfNeeded(FeedRefreshPolicy.Trigger.FOREGROUND))
        assertTrue(repo.refreshIfNeeded(FeedRefreshPolicy.Trigger.MANUAL))
        assertEquals(1, calls)
    }
}
