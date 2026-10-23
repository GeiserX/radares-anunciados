// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Engine/AlertEvent.swift.

package io.github.geiserx.radares.core.engine

import io.github.geiserx.radares.core.health.StretchExitReason
import io.github.geiserx.radares.core.model.Radar
import io.github.geiserx.radares.core.phrasing.Phrasing
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.Locale

/// `FULL` = speech + the high-priority notification. `VISUAL` = the notification without the voice and the in-app card
/// row (opposite direction, pacing gap). Contested direction data demotes to `VISUAL` and never hides.
@Serializable
enum class Level(val raw: String) { @SerialName("full") FULL("full"), @SerialName("visual") VISUAL("visual") }

/// What the surfaces say and show for one event. Built by `Phrasing` in the core, so the sentence a route vector
/// expects is the sentence the car hears.
data class Phrase(
    /// The sentence for the speech synthesizer, e.g. "Radar fijo a 800 metros. Límite 90."
    val spoken: String,
    /// Short line for the notification title, e.g. "Radar fijo a 800 m".
    val title: String,
    /// Second line, e.g. "A-2 km 202,3 · límite 90 km/h".
    val body: String,
)

/// The in-app card's phase.
enum class DrivePhase(val raw: String) {
    WATCHING("watching"),
    APPROACHING("approaching"),
    ALERT("alert"),
    PASSED("passed"),
    INSIDE_STRETCH("insideStretch"),
    PAUSED("paused"),
    DEGRADED("degraded"),
}

/// The in-app card and the source of a `VISUAL` warning's notification text. Display values are rounded here.
data class DriveContent(
    val phase: DrivePhase,
    /// A kind symbol name ("camera.fill"); the app maps it to its own icon.
    val kindSymbol: String,
    /// "Radar fijo", "Tramo de radar móvil", "Sin radares cerca".
    val title: String,
    /// Road and km, or the name.
    val subtitle: String,
    val distanceMetres: Int? = null,
    val limit: Int? = null,
    val speedKmh: Int? = null,
    /// The row is a radar for the opposite flow ("sentido contrario").
    val opposite: Boolean = false,
    /// Inside a stretch: chord minus the projection of the car, labelled "aprox." by the surfaces.
    val stretchRemainingMetres: Int? = null,
    /// Inside an average-speed section: path length since entry over elapsed time.
    val avgKmh: Int? = null,
    val note: String? = null,
    val updatedAt: Instant,
) {
    companion object {
        /// The idle card: nothing ahead. English by phone locale, like every other title the core writes.
        fun watching(at: Instant, locale: Locale): DriveContent {
            val title = if (Phrasing.isEnglish(locale)) "No radars nearby" else "Sin radares cerca"
            return DriveContent(phase = DrivePhase.WATCHING, kindSymbol = "car.fill", title = title, subtitle = "", updatedAt = at)
        }
    }
}

/// One thing the engine decided on a fix. The whole surface chain (speech, notification, log) reads these.
data class AlertEvent(
    val kind: Kind,
    /// Null only for `DriveEnded`.
    val radar: Radar? = null,
    /// Metres to the gate when the event fired; for a stretch joined between its gates, the metres left to the far gate.
    val distance: Double? = null,
    /// Fired inside `warnDistance - Thresholds.lateBandM`.
    val late: Boolean = false,
    /// Lateral distance from the course line to the gate, logged on every alert.
    val crossTrackMetres: Double? = null,
    /// Null when nothing is said or shown as text.
    val phrase: Phrase? = null,
    /// The card after this event.
    val content: DriveContent,
) {
    sealed class Kind {
        data class Warn(val level: Level) : Kind()
        data object Passed : Kind()
        data object StretchEntered : Kind()
        /// Carries why the stretch was left, so the log row can be written from the event alone.
        data class StretchExited(val reason: StretchExitReason) : Kind()
        data object DriveEnded : Kind()
    }
}
