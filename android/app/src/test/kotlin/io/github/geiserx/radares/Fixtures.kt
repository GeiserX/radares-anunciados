// SPDX-License-Identifier: GPL-3.0-or-later
//
// The shared fixtures (Tests/RadaresCoreTests/Fixtures): the 254-feature feed sample and the route vectors the iOS
// and core tests run, read in place.

package io.github.geiserx.radares

import io.github.geiserx.radares.core.InstantSerializer
import io.github.geiserx.radares.core.feed.RadarStore
import io.github.geiserx.radares.core.model.Coordinate
import io.github.geiserx.radares.core.model.Fix
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.util.Locale

object Fixtures {
    val dir: File = File(requireNotNull(System.getProperty("radares.fixtures")) { "radares.fixtures not set" })
    val snapshotDir: File = File(requireNotNull(System.getProperty("radares.snapshotDir")))
    val resDir: File = File(requireNotNull(System.getProperty("radares.resDir")))

    val store: RadarStore by lazy { RadarStore.load(File(dir, "feed-sample.geojson").readBytes()) }

    data class Expected(val kind: String, val radar: String?, val level: String?, val spoken: String?, val opposite: Boolean?)

    data class Vector(
        val name: String,
        val locale: Locale,
        val negativeControl: Boolean,
        /** Drives over the road fixture: the Kotlin core has no road rule yet, so the app skips these as the core does. */
        val roadFixture: Boolean,
        val fixes: List<Fix>,
        val expected: List<Expected>,
    )

    fun vectors(): List<Vector> {
        val files = File(dir, "vectors").listFiles { f -> f.extension == "json" }.orEmpty().sortedBy { it.name }
        check(files.size >= 28) { "expected at least 28 vectors, found ${files.size}" }
        return files.map { parse(it) }
    }

    private fun parse(file: File): Vector {
        val o = Json.parseToJsonElement(file.readText()).jsonObject
        fun JsonObject.str(k: String) = this[k]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content
        fun JsonObject.dbl(k: String) = this[k]?.takeIf { it !is JsonNull }?.jsonPrimitive?.double
        return Vector(
            name = o.str("name") ?: file.nameWithoutExtension,
            locale = Locale.forLanguageTag(o.str("locale") ?: "es-ES"),
            negativeControl = o["negativeControl"]?.jsonPrimitive?.booleanOrNull ?: false,
            roadFixture = o["roadFixture"]?.jsonPrimitive?.booleanOrNull ?: false,
            fixes = o.getValue("fixes").jsonArray.map { e ->
                val f = e.jsonObject
                Fix(
                    coordinate = Coordinate(f.getValue("lat").jsonPrimitive.double, f.getValue("lon").jsonPrimitive.double),
                    timestamp = InstantSerializer.parseIso(f.str("t")!!),
                    speed = f.dbl("speed"),
                    course = f.dbl("course"),
                    horizontalAccuracy = f.dbl("accuracy") ?: 5.0,
                    isStationary = f["stationary"]?.jsonPrimitive?.boolean ?: false,
                )
            },
            expected = o.getValue("expected").jsonArray.map { e ->
                val x = e.jsonObject
                Expected(x.str("kind")!!, x.str("radar"), x.str("level"), x.str("spoken"), x["opposite"]?.jsonPrimitive?.booleanOrNull)
            },
        )
    }
}
