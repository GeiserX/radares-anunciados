// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Feed/GeoJSON.swift.
// The shapes of feed.geojson, read with the same strictness as Swift's JSONDecoder: unknown keys are ignored, a
// missing or null optional is null, and a value of the wrong JSON type anywhere (a numeric id, a string maxspeed, a
// fractional maxspeed, a boolean as 1) throws, which rejects the whole file. kotlinx's own decoder is laxer (it
// reads "50" as an Int), so the fields are read by hand from the parsed tree. An unknown geometry type decodes as
// Unsupported so one odd feature never fails the whole file.

package io.github.geiserx.radares.core.feed

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.math.BigDecimal

/// A value of the wrong JSON type, or a required key missing: Swift's DecodingError.
class GeoJSONDecodingException(message: String) : Exception(message)

data class GeoJSONFeatureCollection(val type: String, val features: List<GeoJSONFeature>) {
    companion object {
        /// Parses and decodes; throws on malformed JSON or any type mismatch.
        fun decode(bytes: ByteArray): GeoJSONFeatureCollection = decode(bytes.toString(Charsets.UTF_8))

        fun decode(text: String): GeoJSONFeatureCollection {
            val root = try {
                Json.parseToJsonElement(text)
            } catch (e: Exception) {
                throw GeoJSONDecodingException("not JSON: ${e.message}")
            }
            val obj = root as? JsonObject ?: throw GeoJSONDecodingException("top level is not an object")
            val type = obj.requiredString("type", "collection")
            val features = obj["features"] as? JsonArray ?: throw GeoJSONDecodingException("features: missing or not an array")
            return GeoJSONFeatureCollection(type, features.mapIndexed { i, f -> GeoJSONFeature.decode(f, "features[$i]") })
        }
    }
}

data class GeoJSONFeature(val id: String?, val geometry: GeoJSONGeometry?, val properties: GeoJSONProperties?) {
    companion object {
        fun decode(e: JsonElement, path: String): GeoJSONFeature {
            val o = e as? JsonObject ?: throw GeoJSONDecodingException("$path: not an object")
            val geometry = when (val g = o["geometry"]) {
                null, JsonNull -> null
                else -> GeoJSONGeometry.decode(g, "$path.geometry")
            }
            val properties = when (val p = o["properties"]) {
                null, JsonNull -> null
                else -> GeoJSONProperties.decode(p, "$path.properties")
            }
            return GeoJSONFeature(o.optString("id", path), geometry, properties)
        }
    }
}

/// Point or LineString; coordinates are [lon, lat] pairs as GeoJSON writes them.
sealed class GeoJSONGeometry {
    data class Point(val coordinates: List<Double>) : GeoJSONGeometry()
    data class LineString(val coordinates: List<List<Double>>) : GeoJSONGeometry()
    data class Unsupported(val type: String) : GeoJSONGeometry()

    companion object {
        fun decode(e: JsonElement, path: String): GeoJSONGeometry {
            val o = e as? JsonObject ?: throw GeoJSONDecodingException("$path: not an object")
            return when (val type = o.requiredString("type", path)) {
                "Point" -> Point(numbers(o["coordinates"], "$path.coordinates"))
                "LineString" -> {
                    val a = o["coordinates"] as? JsonArray ?: throw GeoJSONDecodingException("$path.coordinates: not an array")
                    LineString(a.mapIndexed { i, v -> numbers(v, "$path.coordinates[$i]") })
                }
                else -> Unsupported(type)
            }
        }

        private fun numbers(e: JsonElement?, path: String): List<Double> {
            val a = e as? JsonArray ?: throw GeoJSONDecodingException("$path: not an array")
            return a.mapIndexed { i, v -> strictDouble(v, "$path[$i]") }
        }
    }
}

data class GeoJSONProperties(
    val kind: String? = null,
    val name: String? = null,
    val source: String? = null,
    val active: Boolean? = null,
    val maxspeed: Int? = null,
    val direction: String? = null,
    val province: String? = null,
    val url: String? = null,
    val attribution: String? = null,
    val validFrom: String? = null,
    val validTo: String? = null,
    val road: String? = null,
    val kmFrom: Double? = null,
    val kmTo: Double? = null,
    /// SPEC 1 optional future fields. The Swift core does not declare them, so Swift ignores them whatever their type;
    /// they are read leniently here (a wrong type reads as null) so they can never reject a file Swift accepts.
    val bearing: Double? = null,
    val directionSemantics: String? = null,
    val geometryIsChord: Boolean? = null,
    val sectionOf: String? = null,
) {
    companion object {
        fun decode(e: JsonElement, path: String): GeoJSONProperties {
            val o = e as? JsonObject ?: throw GeoJSONDecodingException("$path: not an object")
            return GeoJSONProperties(
                kind = o.optString("kind", path),
                name = o.optString("name", path),
                source = o.optString("source", path),
                active = o.optBool("active", path),
                maxspeed = o.optInt("maxspeed", path),
                direction = o.optString("direction", path),
                province = o.optString("province", path),
                url = o.optString("url", path),
                attribution = o.optString("attribution", path),
                validFrom = o.optString("valid_from", path),
                validTo = o.optString("valid_to", path),
                road = o.optString("road", path),
                kmFrom = o.optDouble("km_from", path),
                kmTo = o.optDouble("km_to", path),
                bearing = runCatching { o.optDouble("bearing", path) }.getOrNull(),
                directionSemantics = runCatching { o.optString("direction_semantics", path) }.getOrNull(),
                geometryIsChord = runCatching { o.optBool("geometry_is_chord", path) }.getOrNull(),
                sectionOf = runCatching { o.optString("section_of", path) }.getOrNull(),
            )
        }
    }
}

// Strict scalar readers, one per Swift type.

private fun JsonObject.present(key: String): JsonElement? = when (val v = this[key]) {
    null, JsonNull -> null
    else -> v
}

private fun JsonObject.requiredString(key: String, path: String): String =
    present(key)?.let { strictString(it, "$path.$key") } ?: throw GeoJSONDecodingException("$path.$key: missing")

private fun JsonObject.optString(key: String, path: String): String? = present(key)?.let { strictString(it, "$path.$key") }

private fun JsonObject.optBool(key: String, path: String): Boolean? = present(key)?.let {
    val p = it as? JsonPrimitive
    if (p == null || p.isString || (p.content != "true" && p.content != "false")) throw GeoJSONDecodingException("$path.$key: not a boolean")
    p.content == "true"
}

private fun JsonObject.optDouble(key: String, path: String): Double? = present(key)?.let { strictDouble(it, "$path.$key") }

/// Swift's Int from JSON: any number literal whose value is a whole number in range (50, 50.0, 5e1); 50.5 and "50" throw.
private fun JsonObject.optInt(key: String, path: String): Int? = present(key)?.let {
    val n = numberLiteral(it, "$path.$key")
    try {
        n.intValueExact()
    } catch (e: ArithmeticException) {
        throw GeoJSONDecodingException("$path.$key: not an integer")
    }
}

private fun strictString(e: JsonElement, path: String): String {
    val p = e as? JsonPrimitive
    if (p == null || !p.isString) throw GeoJSONDecodingException("$path: not a string")
    return p.content
}

/// Double.parseDouble rounds correctly; BigDecimal is only the integer check above.
private fun strictDouble(e: JsonElement, path: String): Double {
    val p = e as? JsonPrimitive
    if (p == null || p.isString || p is JsonNull) throw GeoJSONDecodingException("$path: not a number")
    val d = p.content.toDoubleOrNull() ?: throw GeoJSONDecodingException("$path: not a number")
    if (d.isInfinite() || d.isNaN()) throw GeoJSONDecodingException("$path: number out of range")
    return d
}

private fun numberLiteral(e: JsonElement, path: String): BigDecimal {
    val p = e as? JsonPrimitive
    if (p == null || p.isString || p is JsonNull) throw GeoJSONDecodingException("$path: not a number")
    return p.content.toBigDecimalOrNull() ?: throw GeoJSONDecodingException("$path: not a number")
}
