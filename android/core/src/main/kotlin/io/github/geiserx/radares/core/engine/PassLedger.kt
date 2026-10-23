// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Engine/PassLedger.swift.
// passes.json: what fired when and how far the car has been since, so a relaunch cannot repeat the voice (design 2.6),
// and the stretch the car is inside, so a relaunch mid-stretch still says "Fin de tramo" (design 2.5).
// Immutable: every change returns a new ledger, so a ledger handed to another engine never changes under it
// (Swift's value semantics).

@file:UseSerializers(InstantSerializer::class)

package io.github.geiserx.radares.core.engine

import io.github.geiserx.radares.core.InstantSerializer
import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.plusSeconds
import io.github.geiserx.radares.core.secondsSince
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import kotlinx.serialization.json.Json
import java.io.File
import java.time.Instant

@Serializable
data class PassLedger(
    val entries: List<Entry> = emptyList(),
    /// The stretch the car was inside when the ledger was written; null outside one. Written on entry, cleared on exit.
    val stretch: DriveSnapshot.StretchState? = null,
) {
    @Serializable
    data class Entry(
        val id: String,
        val firedAt: Instant,
        /// The level it fired at; a radar demoted to visual stays visual for the pass.
        val level: Level = Level.FULL,
        /// Farthest the car has been from the radar since firing, metres.
        val farthestMetres: Double = 0.0,
        val passedAt: Instant? = null,
    ) {
        /// Both cooldown conditions hold: the minutes have gone by and the car has been far enough away.
        fun cooldownOver(now: Instant): Boolean =
            now.secondsSince(firedAt) >= Thresholds.cooldownMinutes * 60 && farthestMetres >= Thresholds.cooldownM
    }

    fun entry(id: String): Entry? = entries.firstOrNull { it.id == id }

    fun upsert(entry: Entry): PassLedger {
        val i = entries.indexOfFirst { it.id == entry.id }
        val next = entries.toMutableList()
        if (i >= 0) next[i] = entry else next.add(entry)
        return copy(entries = next)
    }

    fun remove(id: String): PassLedger = copy(entries = entries.filter { it.id != id })

    /// Drops entries older than Thresholds.ledgerPruneHours and keeps at most Thresholds.ledgerMaxEntries (the newest).
    fun prune(now: Instant): PassLedger {
        val cutoff = now.plusSeconds(-Thresholds.ledgerPruneHours * 3600)
        var kept = entries.filter { !it.firedAt.isBefore(cutoff) }
        if (kept.size > Thresholds.ledgerMaxEntries) {
            kept = kept.sortedByDescending { it.firedAt }.take(Thresholds.ledgerMaxEntries)
        }
        return copy(entries = kept)
    }
}

/// passes.json on disk. The owner saves on fire, on pass, at stretch entry and exit and at drive end, never per fix.
class PassLedgerFile(private val file: File) {
    /// The stored ledger; an empty one when the file is missing or unreadable (a broken file never blocks a drive).
    fun load(): PassLedger = try {
        if (file.exists()) json.decodeFromString(PassLedger.serializer(), file.readText()) else PassLedger()
    } catch (e: Exception) {
        PassLedger()
    }

    /// Written to a temporary file and renamed, so a process killed mid-write leaves the previous ledger.
    fun save(ledger: PassLedger): Boolean = try {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(json.encodeToString(PassLedger.serializer(), ledger))
        if (!tmp.renameTo(file)) {
            file.delete()
            tmp.renameTo(file)
        } else {
            true
        }
    } catch (e: Exception) {
        false
    }

    private companion object {
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    }
}
