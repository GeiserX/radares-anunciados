// SPDX-License-Identifier: GPL-3.0-or-later
//
// The feed on disk (SPEC 1): filesDir/feed.geojson, one backup feed.geojson.bak, and feed.meta.json (the feed's age
// comes from here, never from file dates). A new body replaces the file atomically: written to .new, the current
// file renamed to .bak, .new renamed into place. On first launch the bundled snapshot is copied in, with its
// generation time as fetchedAt, so the first drive after install works offline.

package io.github.geiserx.radares.feed

import io.github.geiserx.radares.core.InstantSerializer
import io.github.geiserx.radares.core.feed.FeedMeta
import io.github.geiserx.radares.core.feed.RadarStore
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.time.Instant

class FeedStore(private val dir: File) {
    val feed = File(dir, "feed.geojson")
    val backup = File(dir, "feed.geojson.bak")
    private val incoming = File(dir, "feed.geojson.new")
    private val metaFile = File(dir, "feed.meta.json")

    fun hasFeed(): Boolean = feed.isFile

    /** Atomic replace keeping the previous file as .bak. */
    @Throws(IOException::class)
    fun replace(body: ByteArray) {
        dir.mkdirs()
        incoming.writeBytes(body)
        if (feed.exists()) {
            backup.delete()
            if (!feed.renameTo(backup)) throw IOException("could not move the feed to .bak")
        }
        if (!incoming.renameTo(feed)) {
            // Put the old file back so a failed swap never leaves the app without a feed.
            if (backup.exists() && !feed.exists()) backup.copyTo(feed)
            throw IOException("could not move the new feed into place")
        }
    }

    /**
     * Copies the bundled snapshot when no feed exists yet. `date` is the snapshot's sidecar `feed-snapshot.date`
     * (ISO 8601): it becomes fetchedAt, so Estado shows the snapshot's real age. Returns true when it copied.
     */
    fun copySnapshotIfNeeded(snapshot: () -> InputStream, date: () -> String?): Boolean {
        if (hasFeed()) return false
        val body = snapshot().use { it.readBytes() }
        replace(body)
        val fetchedAt = date()?.trim()?.let { runCatching { InstantSerializer.parseIso(it) }.getOrNull() }
        val store = RadarStore.load(body)
        writeMeta(FeedMeta(fetchedAt = fetchedAt, featureCount = store.all.size, countsByKind = store.all.groupingBy { it.kind }.eachCount()))
        return true
    }

    fun readMeta(): FeedMeta = if (metaFile.isFile) FeedMeta.decode(metaFile.readText()) else FeedMeta()

    fun writeMeta(meta: FeedMeta) {
        dir.mkdirs()
        val tmp = File(dir, "feed.meta.json.tmp")
        tmp.writeText(meta.encode())
        if (!tmp.renameTo(metaFile)) {
            metaFile.delete()
            tmp.renameTo(metaFile)
        }
    }

    /** The radars on disk, or null when there is no readable feed (the .bak is tried before giving up). */
    fun load(): RadarStore? =
        runCatching { RadarStore.load(feed.readBytes()) }.getOrNull()
            ?: runCatching { RadarStore.load(backup.readBytes()) }.getOrNull()

    /** True when the folder can be written and read back: the Estado row "Archivos". */
    fun verifyWritable(): Boolean = runCatching {
        dir.mkdirs()
        val probe = File(dir, ".probe")
        val stamp = Instant.now().toString()
        probe.writeText(stamp)
        val ok = probe.readText() == stamp
        probe.delete()
        ok
    }.getOrDefault(false)
}
