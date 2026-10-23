// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Feed/FeedDecoder.swift.
// GeoJSON -> List<Radar>: the direction vocabularies, negative bearings mod 360, section twins merged into their
// stretch, roles by kind and source (design 2.1).

package io.github.geiserx.radares.core.feed

import io.github.geiserx.radares.core.geo.Geo
import io.github.geiserx.radares.core.model.Coordinate
import io.github.geiserx.radares.core.model.Kind
import io.github.geiserx.radares.core.model.Radar
import io.github.geiserx.radares.core.model.Role
import java.net.URI
import java.time.DateTimeException
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.abs

object FeedDecoder {
    /// The feed's calendar: `valid_from` / `valid_to` are Europe/Madrid calendar days.
    val madrid: ZoneId = ZoneId.of("Europe/Madrid")

    /// Throws GeoJSONDecodingException on malformed JSON or a type mismatch anywhere, as Swift's JSONDecoder does.
    fun decode(bytes: ByteArray): List<Radar> = radars(GeoJSONFeatureCollection.decode(bytes))

    /// Normalises an already parsed collection. Features without an id, a usable geometry or a known kind are skipped.
    fun radars(collection: GeoJSONFeatureCollection): List<Radar> {
        val lines = mutableListOf<Radar>()
        val points = mutableListOf<Radar>()
        for (feature in collection.features) {
            val radar = radar(feature) ?: continue
            if (radar.isLine) lines.add(radar) else points.add(radar)
        }

        // Section twins: a `section` point sitting exactly on a stretch endpoint is that stretch's gate, so it is
        // folded into the stretch (its limit fills a missing one) and the pass is one pass. Both ends, every stretch.
        val endpointIndex = HashMap<Coordinate, MutableList<Int>>()
        for ((i, line) in lines.withIndex()) {
            endpointIndex.getOrPut(line.start) { mutableListOf() }.add(i)
            line.end?.let { endpointIndex.getOrPut(it) { mutableListOf() }.add(i) }
        }
        val limitFromSection = HashMap<Int, Int>()
        val kept = ArrayList<Radar>(points.size)
        for (point in points) {
            val owners = if (point.kind == Kind.SECTION) endpointIndex[point.start] else null
            if (owners != null) {
                val limit = point.maxspeed
                if (limit != null) {
                    for (i in owners) if (lines[i].maxspeed == null) limitFromSection[i] = limit
                }
                continue
            }
            kept.add(point)
        }
        val result = ArrayList<Radar>(kept.size + lines.size)
        result.addAll(kept)
        for ((i, line) in lines.withIndex()) {
            val limit = limitFromSection[i]
            result.add(if (limit != null) line.copy(maxspeed = limit) else line)
        }
        return result
    }

    internal fun radar(feature: GeoJSONFeature): Radar? {
        val id = feature.id
        if (id.isNullOrEmpty()) return null
        val props = feature.properties ?: return null
        val kind = props.kind?.let { Kind.fromRaw(it) } ?: return null
        val geometry = feature.geometry ?: return null

        val start: Coordinate
        var end: Coordinate? = null
        var chord: Double? = null
        when (geometry) {
            is GeoJSONGeometry.Point -> start = coordinate(geometry.coordinates) ?: return null
            is GeoJSONGeometry.LineString -> {
                val vertices = geometry.coordinates.mapNotNull { coordinate(it) }
                if (vertices.size < 2 || vertices.size != geometry.coordinates.size) return null
                start = vertices[0]
                end = vertices[vertices.size - 1]
                var sum = 0.0
                for (i in 1 until vertices.size) sum += Geo.distance(vertices[i - 1], vertices[i])
                chord = sum
            }
            is GeoJSONGeometry.Unsupported -> return null
        }

        val source = props.source ?: ""
        val role = if (kind == Kind.STRETCH) {
            if (source == "dgt_invive") Role.MOBILE_CORRIDOR else Role.AVERAGE_SPEED_SECTION
        } else {
            Role.POINT
        }

        val direction = parseDirection(props.direction)
        val from = props.kmFrom
        val to = props.kmTo
        val roadMetres = if (from != null && to != null) abs(to - from) * 1000 else null

        return Radar(
            id = id,
            kind = kind,
            role = role,
            start = start,
            end = end,
            chordMetres = chord,
            roadMetres = roadMetres,
            name = props.name ?: id,
            road = props.road,
            kmFrom = props.kmFrom,
            kmTo = props.kmTo,
            maxspeed = props.maxspeed,
            bearing = direction.bearing,
            bidirectional = direction.bidirectional,
            directionText = direction.text,
            validFrom = day(props.validFrom),
            validTo = day(props.validTo),
            active = props.active ?: true,
            source = source,
            attribution = props.attribution ?: "",
            url = props.url?.takeIf { isUrl(it) },
            province = props.province,
            travelBearing = if (props.directionSemantics == "travel") props.bearing?.takeIf { it.isFinite() }?.let { Geo.normalize(it) } else null,
            geometryIsChord = props.geometryIsChord,
            sectionOf = props.sectionOf,
        )
    }

    data class Direction(val bearing: Double? = null, val bidirectional: Boolean = false, val text: String? = null)

    /// The four vocabularies of `properties.direction` (design 2.1): a numeric string is an OSM bearing (negatives
    /// folded mod 360), `both` is bidirectional, a place name is spoken text, null is nothing. OSM's relative tokens
    /// `forward` / `backward` name no place and carry no absolute heading, so they are treated as null.
    fun parseDirection(rawIn: String?): Direction {
        // Swift's .whitespaces: tab plus the Unicode space separators.
        val raw = rawIn?.trim { it == '\t' || Character.getType(it) == Character.SPACE_SEPARATOR.toInt() } ?: return Direction()
        if (raw.isEmpty()) return Direction()
        if (raw == "both") return Direction(bidirectional = true)
        val value = swiftDouble(raw)
        if (value != null && raw.all { Character.isDigit(it) || it == '-' || it == '.' }) {
            return Direction(bearing = Geo.normalize(value))
        }
        if (raw == "forward" || raw == "backward") return Direction()
        return Direction(text = raw)
    }

    /// Swift's Double(String) for the characters parseDirection lets through: plain decimal literals only.
    private fun swiftDouble(raw: String): Double? {
        if (!Regex("^[+-]?(\\d+\\.?\\d*|\\.\\d+)$").matches(raw)) return null
        return raw.toDoubleOrNull()
    }

    /// `yyyy-MM-dd` as the start of that day in Europe/Madrid; null for anything else.
    fun day(raw: String?): Instant? {
        if (raw == null || raw.length != 10) return null
        // Swift split(separator:) drops empty pieces.
        val parts = raw.split("-").filter { it.isNotEmpty() }
        if (parts.size != 3) return null
        val y = parts[0].toIntOrNull() ?: return null
        val m = parts[1].toIntOrNull() ?: return null
        val d = parts[2].toIntOrNull() ?: return null
        if (m !in 1..12 || d !in 1..31) return null
        return try {
            LocalDate.of(y, m, d).atStartOfDay(madrid).toInstant()
        } catch (e: DateTimeException) {
            null
        }
    }

    /// The Europe/Madrid calendar day of an instant.
    fun madridDay(at: Instant): LocalDate = at.atZone(madrid).toLocalDate()

    private fun coordinate(pair: List<Double>): Coordinate? {
        if (pair.size < 2 || !pair[0].isFinite() || !pair[1].isFinite() || abs(pair[1]) > 90 || abs(pair[0]) > 180) return null
        return Coordinate(latitude = pair[1], longitude = pair[0])
    }

    /// Swift's URL(string:) refuses strings that are not RFC 3986; java.net.URI is the same test.
    private fun isUrl(raw: String): Boolean = try {
        URI(raw)
        raw.isNotEmpty()
    } catch (e: Exception) {
        false
    }
}

/// Alertable (design 2.1): active, not an unconfirmed note, and for an announced mobile radar the Europe/Madrid day
/// of `at` is inside its range (an entry with neither date is never alertable).
fun Radar.isAlertable(at: Instant): Boolean {
    if (!active || kind == Kind.REPORTED) return false
    if (kind != Kind.MOBILE_ANNOUNCED) return true
    val today = FeedDecoder.madridDay(at).atStartOfDay(FeedDecoder.madrid).toInstant()
    val from = validFrom
    val to = validTo
    if (from != null && today.isBefore(from)) return false
    if (to != null && today.isAfter(to)) return false
    return from != null || to != null
}
