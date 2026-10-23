// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Model/Radar.swift.

@file:UseSerializers(InstantSerializer::class)

package io.github.geiserx.radares.core.model

import io.github.geiserx.radares.core.InstantSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import java.time.Instant

/// The feed's `kind` property, verbatim. `reported` is an unconfirmed OSM note: map only, never warned.
@Serializable
enum class Kind(val raw: String) {
    @SerialName("fixed") FIXED("fixed"),
    @SerialName("section") SECTION("section"),
    @SerialName("stretch") STRETCH("stretch"),
    @SerialName("mobile_announced") MOBILE_ANNOUNCED("mobile_announced"),
    /// A place where a mobile radar is set up often, derived from published fines; no dates.
    @SerialName("mobile_recurring") MOBILE_RECURRING("mobile_recurring"),
    @SerialName("trailer") TRAILER("trailer"),
    @SerialName("reported") REPORTED("reported");

    companion object {
        fun fromRaw(raw: String): Kind? = entries.firstOrNull { it.raw == raw }
    }
}

/// What the app does with a radar, derived by the decoder (design 2.1).
@Serializable
enum class Role { @SerialName("point") POINT, @SerialName("mobileCorridor") MOBILE_CORRIDOR, @SerialName("averageSpeedSection") AVERAGE_SPEED_SECTION }

/// One alertable thing from the feed, normalised.
@Serializable
data class Radar(
    /// `feature.id`, unique and stable per source.
    val id: String,
    val kind: Kind,
    val role: Role,
    /// The Point, or the first vertex of the LineString.
    val start: Coordinate,
    /// The last vertex of a LineString; null for a point.
    val end: Coordinate? = null,
    /// Sum of the segment lengths of the LineString; null for a point.
    val chordMetres: Double? = null,
    /// `|km_to - km_from| * 1000` when both are present.
    val roadMetres: Double? = null,
    val name: String,
    val road: String? = null,
    val kmFrom: Double? = null,
    val kmTo: Double? = null,
    /// Speed limit in km/h; null when the feed has none.
    val maxspeed: Int? = null,
    /// Degrees 0..<360, heading of the monitored traffic per OSM; null when unknown. Demotes, never hides.
    val bearing: Double? = null,
    /// `direction == "both"`.
    val bidirectional: Boolean = false,
    /// A place name such as "ZARAGOZA": spoken and shown, never used to gate.
    val directionText: String? = null,
    /// `mobile_announced` only: the calendar day range (Europe/Madrid) the announcement covers.
    val validFrom: Instant? = null,
    val validTo: Instant? = null,
    val active: Boolean = true,
    val source: String,
    val attribution: String,
    val url: String? = null,
    val province: String? = null,
    /// SPEC 1 optional future field: `bearing` when `direction_semantics` is "travel". Decoded, not used by the engine
    /// yet (the Swift core does not read it either); nil today.
    val travelBearing: Double? = null,
    /// SPEC 1 optional future field `geometry_is_chord`. Decoded only.
    val geometryIsChord: Boolean? = null,
    /// SPEC 1 optional future field `section_of`. Decoded only.
    val sectionOf: String? = null,
) {
    /// True for lines (stretches); the two gates are `start` and `end`.
    val isLine: Boolean get() = end != null

    /// Length used for speech and the remaining estimate: the road length when the feed has km markers, else the chord.
    val lengthMetres: Double? get() = roadMetres ?: chordMetres
}
