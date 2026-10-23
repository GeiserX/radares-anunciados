// SPDX-License-Identifier: GPL-3.0-or-later
// Port of testEveryMustNotFireVectorHasAMustFireTwin (AlertEngineVectorTests.swift) and SPEC 10's twin list.

package io.github.geiserx.radares.core

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class TwinsTest {
    private fun fullWarnings(v: Vector) = v.expected.count { it.kind == "warn" && it.level == "full" }

    /// A silent vector expects nothing at all; its twin on the same radar expects a full warning.
    @Test
    fun everyMustNotFireVectorHasAMustFireTwin() {
        val silent = mapOf(
            "leon-50kmh-tomorrow" to "leon-50kmh-today",
            "a2-parallel-150m" to "a2-head-on-90kmh",
            "a2-behind" to "a2-head-on-90kmh",
            "a2-no-course-2mps" to "a2-no-course-20mps",
        )
        for ((quiet, loud) in silent) {
            val q = Vector.load(quiet)
            val l = Vector.load(loud)
            assertTrue(q.expected.isEmpty(), "$quiet must expect no event at all, got ${q.expected.map { it.kind }}")
            assertTrue(fullWarnings(l) >= 1, loud)
        }
    }

    /// The U-turn inside five minutes is one pass; its eleven-minute, 3 km twin is two.
    @Test
    fun theUTurnTwinsCountPasses() {
        assertEquals(1, fullWarnings(Vector.load("a2-uturn-5min")), "one pass, one warning")
        assertEquals(2, fullWarnings(Vector.load("a2-uturn-11min-3km")), "two passes, two warnings")
    }

    /// The opposite OSM flow is shown, never hidden; the same flow is spoken.
    @Test
    fun theOsmBearingTwinsDemoteAndNeverHide() {
        val opposite = Vector.load("osm-bearing-opposite")
        val same = Vector.load("osm-bearing-same")
        assertTrue(opposite.expected.any { it.kind == "warn" && it.level == "visual" && it.opposite == true }, "opposite flow: a visual warning")
        assertTrue(fullWarnings(same) >= 1, "same flow: a full warning")
    }
}
