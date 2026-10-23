// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Feed/RadarStore.swift.
// The decoded feed in memory: a linear scan with a precomputed bounding box per radar (design 5.4).
// `candidates` applies the alertable rules: active, not reported, mobile_announced valid on the Madrid day of `at`.
// A line is a candidate by its nearer gate or by its chord, so a car between the gates sees the stretch (design 2.5).
// No spatial index: 4,500 boxes compare in microseconds; revisit at Thresholds.spatialIndexRevisitFeatures.

package io.github.geiserx.radares.core.feed

import io.github.geiserx.radares.core.geo.Geo
import io.github.geiserx.radares.core.model.Coordinate
import io.github.geiserx.radares.core.model.Kind
import io.github.geiserx.radares.core.model.Radar
import java.time.Instant
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min

class RadarStore(radars: List<Radar>) {
    val all: List<Radar> = radars.toList()

    /// One box per radar, same order as `all`: minLat, maxLat, minLon, maxLon in degrees.
    private val minLat = DoubleArray(all.size)
    private val maxLat = DoubleArray(all.size)
    private val minLon = DoubleArray(all.size)
    private val maxLon = DoubleArray(all.size)
    private val byId: Map<String, Int>

    init {
        for ((i, r) in all.withIndex()) {
            val endLat = r.end?.latitude ?: r.start.latitude
            val endLon = r.end?.longitude ?: r.start.longitude
            minLat[i] = min(r.start.latitude, endLat)
            maxLat[i] = max(r.start.latitude, endLat)
            minLon[i] = min(r.start.longitude, endLon)
            maxLon[i] = max(r.start.longitude, endLon)
        }
        val index = HashMap<String, Int>(all.size * 2)
        for ((i, r) in all.withIndex()) if (!index.containsKey(r.id)) index[r.id] = i
        byId = index
    }

    val count: Int get() = all.size

    val countsByKind: Map<Kind, Int> get() = all.groupingBy { it.kind }.eachCount()

    /// Alertable radars within `metres` of `near` (the point; for a line, the nearer gate or the chord between them)
    /// on the Europe/Madrid calendar day of `at`. Order: nearest first.
    fun candidates(near: Coordinate, metres: Double, at: Instant): List<Radar> {
        val dLat = metres / 111_320
        val cosLat = max(0.01, cos(near.latitude * PI / 180))
        val dLon = metres / (111_320 * cosLat)
        val loLat = near.latitude - dLat
        val hiLat = near.latitude + dLat
        val loLon = near.longitude - dLon
        val hiLon = near.longitude + dLon
        val found = ArrayList<Pair<Double, Radar>>()
        for (i in all.indices) {
            if (maxLat[i] < loLat || minLat[i] > hiLat || maxLon[i] < loLon || minLon[i] > hiLon) continue
            val r = all[i]
            val d = distance(near, r)
            if (!(d <= metres) || !r.isAlertable(at)) continue
            found.add(d to r)
        }
        found.sortBy { it.first }
        return found.map { it.second }
    }

    fun radar(id: String): Radar? = byId[id]?.let { all[it] }

    companion object {
        fun load(geojson: ByteArray): RadarStore = RadarStore(FeedDecoder.decode(geojson))

        /// Metres from `point` to the nearer gate of `radar`.
        fun gateDistance(point: Coordinate, radar: Radar): Double {
            val d = Geo.distance(point, radar.start)
            val end = radar.end ?: return d
            return min(d, Geo.distance(point, end))
        }

        /// Metres from `point` to the nearest part of `radar`: the point, or for a line the nearer gate or the chord.
        fun distance(point: Coordinate, radar: Radar): Double {
            val end = radar.end ?: return Geo.distance(point, radar.start)
            return Geo.distanceToChord(point, radar.start, end)
        }
    }
}
