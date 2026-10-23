// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Geo/Geo.swift.
// Haversine distance, atan2 bearing, angle difference, cross-track distance and projection onto a chord.
// Spherical formulas on a 6,371 km Earth: at the distances the engine cares about (under 100 km) the error
// against WGS84 is well under the GPS accuracy of a fix.

package io.github.geiserx.radares.core.geo

import io.github.geiserx.radares.core.model.Coordinate
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

object Geo {
    /// Mean Earth radius in metres.
    const val earthRadiusM: Double = 6_371_000.0

    /// Metres between two coordinates (haversine).
    fun distance(a: Coordinate, b: Coordinate): Double {
        val lat1 = a.latitude * PI / 180
        val lat2 = b.latitude * PI / 180
        val dLat = lat2 - lat1
        val dLon = (b.longitude - a.longitude) * PI / 180
        val s1 = sin(dLat / 2)
        val s2 = sin(dLon / 2)
        val h = s1 * s1 + cos(lat1) * cos(lat2) * s2 * s2
        return 2 * earthRadiusM * asin(min(1.0, sqrt(h)))
    }

    /// Degrees 0..<360 from `from` to `to` (initial bearing).
    fun bearing(from: Coordinate, to: Coordinate): Double {
        val lat1 = from.latitude * PI / 180
        val lat2 = to.latitude * PI / 180
        val dLon = (to.longitude - from.longitude) * PI / 180
        val y = sin(dLon) * cos(lat2)
        val x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return normalize(atan2(y, x) * 180 / PI)
    }

    /// Smallest absolute difference between two headings, 0...180.
    fun angleDiff(a: Double, b: Double): Double {
        val d = abs(normalize(a) - normalize(b))
        return if (d > 180) 360 - d else d
    }

    /// Any angle folded into 0..<360. Kotlin's `%` keeps the sign of the dividend like Swift's truncatingRemainder.
    fun normalize(degrees: Double): Double {
        val r = degrees % 360
        return if (r < 0) r + 360 else r
    }

    /// Lateral metres from the line through `from` along `courseDegrees` to `point` (signed: positive to the right).
    fun crossTrack(point: Coordinate, from: Coordinate, courseDegrees: Double): Double {
        val d13 = distance(from, point) / earthRadiusM
        val t13 = bearing(from, point) * PI / 180
        val t12 = courseDegrees * PI / 180
        return asin(sin(d13) * sin(t13 - t12)) * earthRadiusM
    }

    /// Metres along the chord `from`->`to` of the projection of `point`, clamped to the chord.
    fun projection(point: Coordinate, from: Coordinate, to: Coordinate): Double {
        val chord = distance(from, to)
        if (!(chord > 0)) return 0.0
        return min(chord, max(0.0, alongChord(point, from, to)))
    }

    /// Metres along the line through `from` and `to` of the projection of `point`, signed: negative behind `from`,
    /// beyond the chord length past `to`.
    fun alongChord(point: Coordinate, from: Coordinate, to: Coordinate): Double {
        val d13 = distance(from, point)
        if (!(d13 > 0) || !(distance(from, to) > 0)) return 0.0
        val course = bearing(from, to)
        val xt = crossTrack(point, from, course) / earthRadiusM
        val ratio = min(1.0, max(-1.0, cos(d13 / earthRadiusM) / cos(xt)))
        var along = acos(ratio) * earthRadiusM
        if (angleDiff(course, bearing(from, point)) > 90) along = -along
        return along
    }

    /// Metres from `point` to the chord `from`->`to`: the lateral distance while the projection falls between the
    /// ends, else the distance to the nearer end.
    fun distanceToChord(point: Coordinate, from: Coordinate, to: Coordinate): Double {
        val chord = distance(from, to)
        if (!(chord > 0)) return distance(point, from)
        val along = alongChord(point, from, to)
        if (along <= 0) return distance(point, from)
        if (along >= chord) return distance(point, to)
        return abs(crossTrack(point, from, bearing(from, to)))
    }

    /// The coordinate `metres` away from `from` along `bearingDegrees`.
    fun destination(from: Coordinate, bearingDegrees: Double, metres: Double): Coordinate {
        val lat1 = from.latitude * PI / 180
        val lon1 = from.longitude * PI / 180
        val t = bearingDegrees * PI / 180
        val d = metres / earthRadiusM
        val lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(t))
        val lon2 = lon1 + atan2(sin(t) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return Coordinate(latitude = lat2 * 180 / PI, longitude = lon2 * 180 / PI)
    }
}
