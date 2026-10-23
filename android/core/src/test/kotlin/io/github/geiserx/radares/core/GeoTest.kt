// SPDX-License-Identifier: GPL-3.0-or-later
// Geo against known values: the formulas are spherical, so the checks are to a metre or a tenth of a degree.

package io.github.geiserx.radares.core

import io.github.geiserx.radares.core.geo.Geo
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class GeoTest {
    private val madrid = at(40.4168, -3.7038)
    private val zaragoza = at(41.6488, -0.8891)

    @Test
    fun distanceAndBearing() {
        assertEquals(0.0, Geo.distance(madrid, madrid))
        // One degree of latitude on a 6,371 km sphere is 111,195 m.
        assertEquals(111_195.0, Geo.distance(at(40.0, -3.0), at(41.0, -3.0)), 1.0)
        assertEquals(272_936.0, Geo.distance(madrid, zaragoza), 1.0)
        assertEquals(0.0, Geo.bearing(at(40.0, -3.0), at(41.0, -3.0)), 1e-9)
        assertEquals(180.0, Geo.bearing(at(41.0, -3.0), at(40.0, -3.0)), 1e-9)
        assertEquals(90.0, Geo.bearing(at(0.0, 0.0), at(0.0, 1.0)), 1e-9)
        assertEquals(270.0, Geo.bearing(at(0.0, 1.0), at(0.0, 0.0)), 1e-9)
    }

    @Test
    fun normalizeAndAngleDiff() {
        assertEquals(320.0, Geo.normalize(-40.0))
        assertEquals(0.0, Geo.normalize(360.0))
        assertEquals(40.0, Geo.normalize(400.0))
        assertEquals(160.0, Geo.normalize(-200.0))
        assertEquals(20.0, Geo.angleDiff(350.0, 10.0))
        assertEquals(180.0, Geo.angleDiff(0.0, 180.0))
        assertEquals(90.0, Geo.angleDiff(-45.0, 45.0))
    }

    @Test
    fun destinationRoundTripsWithDistanceAndBearing() {
        for (b in listOf(0.0, 37.0, 90.0, 181.0, 300.0)) {
            val d = Geo.destination(madrid, b, 5_000.0)
            assertEquals(5_000.0, Geo.distance(madrid, d), 0.01)
            assertEquals(b, Geo.bearing(madrid, d), 0.01)
        }
    }

    @Test
    fun crossTrackProjectionAndChordDistance() {
        val a = madrid
        val course = 60.0
        val b = Geo.destination(a, course, 10_000.0)
        val mid = Geo.destination(a, course, 4_000.0)
        val right = Geo.destination(mid, course + 90, 200.0)
        val left = Geo.destination(mid, course - 90, 200.0)
        assertEquals(200.0, Geo.crossTrack(right, a, course), 0.5)
        assertEquals(-200.0, Geo.crossTrack(left, a, course), 0.5)
        assertEquals(4_000.0, Geo.projection(right, a, b), 1.0)
        assertEquals(200.0, Geo.distanceToChord(right, a, b), 0.5)
        val behind = Geo.destination(a, course + 180, 300.0)
        assertTrue(Geo.alongChord(behind, a, b) < 0, "behind the start is negative")
        assertEquals(0.0, Geo.projection(behind, a, b), "clamped to the chord")
        assertEquals(300.0, Geo.distanceToChord(behind, a, b), 0.5)
        val past = Geo.destination(b, course, 500.0)
        assertEquals(10_000.0, Geo.projection(past, a, b), 1e-6)
        assertEquals(500.0, Geo.distanceToChord(past, a, b), 0.5)
        assertEquals(0.0, Geo.projection(right, a, a), "a zero-length chord")
    }
}
