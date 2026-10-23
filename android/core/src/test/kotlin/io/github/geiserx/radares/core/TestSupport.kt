// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Tests/RadaresCoreTests/TestSupport.swift: the fixture, synthetic radars and fixes. Offline, Fixtures/ only.
// The fixtures are the Swift ones, read in place from the directory Gradle passes as -Dradares.fixtures.

package io.github.geiserx.radares.core

import io.github.geiserx.radares.core.feed.RadarStore
import io.github.geiserx.radares.core.geo.Geo
import io.github.geiserx.radares.core.model.Coordinate
import io.github.geiserx.radares.core.model.Fix
import io.github.geiserx.radares.core.model.Kind
import io.github.geiserx.radares.core.model.Radar
import io.github.geiserx.radares.core.model.Role
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.Locale

object Fixtures {
    val dir: File by lazy {
        val path = System.getProperty("radares.fixtures") ?: error("radares.fixtures is not set: run the tests through Gradle")
        File(path).also { require(it.isDirectory) { "fixtures dir missing: $it" } }
    }

    val vectorsDir: File get() = File(dir, "vectors")

    fun feedBytes(): ByteArray = File(dir, "feed-sample.geojson").readBytes()

    val store: RadarStore by lazy { RadarStore.load(feedBytes()) }

    fun radar(id: String): Radar = store.radar(id) ?: error("fixture has no radar $id")

    /// The fixture replicated with suffixed ids until it has at least `count` features: a feed-sized file, offline.
    fun syntheticFeed(count: Int, mutate: (Int, JsonObject) -> JsonObject = { _, f -> f }): ByteArray {
        val base = Json.parseToJsonElement(String(feedBytes())).jsonObject.getValue("features").jsonArray
        val features = mutableListOf<JsonObject>()
        var copy = 0
        while (features.size < count) {
            for (f in base) {
                var g = f.jsonObject
                val id = g["id"]?.jsonPrimitive?.content
                if (copy > 0 && id != null) g = JsonObject(g + ("id" to JsonPrimitive("$id#$copy")))
                features.add(mutate(features.size, g))
                if (features.size >= count) break
            }
            copy += 1
        }
        return JsonObject(mapOf("type" to JsonPrimitive("FeatureCollection"), "features" to JsonArray(features))).toString().toByteArray()
    }

    val es: Locale = Locale.forLanguageTag("es-ES")
    val en: Locale = Locale.forLanguageTag("en-GB")
}

/// Swift's Locale(identifier:) accepts both "es_ES" and "es-ES".
fun localeOf(identifier: String): Locale = Locale.forLanguageTag(identifier.replace('_', '-'))

fun at(lat: Double, lon: Double) = Coordinate(lat, lon)

fun makeRadar(
    id: String = "test",
    kind: Kind = Kind.FIXED,
    role: Role = Role.POINT,
    start: Coordinate = at(41.3, -1.9),
    end: Coordinate? = null,
    name: String = "Radar fijo A-2 km 202.3",
    road: String? = null,
    kmFrom: Double? = null,
    kmTo: Double? = null,
    maxspeed: Int? = null,
    bearing: Double? = null,
    bidirectional: Boolean = false,
    directionText: String? = null,
    validFrom: Instant? = null,
    validTo: Instant? = null,
    active: Boolean = true,
    source: String = "dgt",
): Radar = Radar(
    id = id, kind = kind, role = role, start = start, end = end,
    chordMetres = end?.let { Geo.distance(start, it) },
    roadMetres = if (kmFrom != null && kmTo != null) Math.abs(kmTo - kmFrom) * 1000 else null,
    name = name, road = road, kmFrom = kmFrom, kmTo = kmTo, maxspeed = maxspeed, bearing = bearing,
    bidirectional = bidirectional, directionText = directionText, validFrom = validFrom, validTo = validTo,
    active = active, source = source, attribution = "test",
)

fun makeFix(c: Coordinate, t: Instant, speed: Double? = 25.0, course: Double? = 0.0, accuracy: Double = 5.0, stationary: Boolean = false) =
    Fix(coordinate = c, timestamp = t, speed = speed, course = course, horizontalAccuracy = accuracy, isStationary = stationary)

/// 2026-10-07T10:00:00Z
val t0: Instant = Instant.ofEpochSecond(1_791_367_200)

fun madridDate(y: Int, m: Int, d: Int, h: Int = 12, min: Int = 0): Instant =
    LocalDateTime.of(y, m, d, h, min).atZone(ZoneId.of("Europe/Madrid")).toInstant()

/// A straight 1 Hz drive from `metresBefore` before `gate` along `course`, to `metresAfter` beyond it.
fun straightFixes(gate: Coordinate, course: Double, speed: Double, metresBefore: Double, metresAfter: Double, start: Instant = t0, courseInFix: Boolean = true): List<Fix> {
    val fixes = mutableListOf<Fix>()
    var pos = Geo.destination(gate, Geo.normalize(course + 180), metresBefore)
    val n = roundHalfAway((metresBefore + metresAfter) / speed).toInt()
    for (i in 0 until n) {
        pos = Geo.destination(pos, course, speed)
        fixes.add(makeFix(pos, start.plusSeconds((i + 1).toDouble()), speed = speed, course = if (courseInFix) course else null))
    }
    return fixes
}
