// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Engine/DriveSnapshot.swift.

@file:UseSerializers(InstantSerializer::class)

package io.github.geiserx.radares.core.engine

import io.github.geiserx.radares.core.InstantSerializer
import io.github.geiserx.radares.core.model.Coordinate
import io.github.geiserx.radares.core.model.Fix
import io.github.geiserx.radares.core.model.Radar
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import java.time.Instant
import java.util.Locale

/// What the engine knows right now, for the in-app card and the map. Read, never mutated, by the app.
data class DriveSnapshot(
    /// The radar the card is about: the one fired or armed ahead, else the nearest candidate ("cerca").
    val next: Radar? = null,
    val distanceMetres: Double? = null,
    /// The speed the warn distance was computed from (median of the last valid speeds), m/s.
    val speedMps: Double? = null,
    /// The course in use, degrees; null means nothing fires and the card shows the nearest radar as "cerca".
    val courseDegrees: Double? = null,
    val stretch: StretchState? = null,
    val visualRows: List<VisualRow> = emptyList(),
    val lastFix: Fix? = null,
    /// The card as it stands.
    val content: DriveContent,
) {
    /// The stretch the car is inside, if any (design 2.5). Persisted in the ledger, so it is serializable.
    @Serializable
    data class StretchState(
        val radar: Radar,
        val enteredAt: Instant,
        /// The gate the car came in through.
        val entryGate: Coordinate,
        /// Chord minus the projection of the car onto it, "aprox.".
        val remainingMetres: Double? = null,
        /// Average-speed sections only: path length since entry over elapsed time, km/h.
        val avgKmh: Double? = null,
        /// The speed at entry, for the silent time exit; kept so a relaunch mid-stretch restores it.
        val entrySpeedMps: Double? = null,
        /// Where the car was at entry: after a relaunch the path driven since is estimated from here.
        val entryCoordinate: Coordinate? = null,
    )

    /// A radar shown as "sentido contrario" or demoted by pacing: on the card and in a silent notification, never spoken.
    data class VisualRow(val radar: Radar, val distanceMetres: Double, val opposite: Boolean)

    companion object {
        /// Before the first fix.
        fun empty(at: Instant, locale: Locale): DriveSnapshot = DriveSnapshot(content = DriveContent.watching(at, locale))
    }
}
