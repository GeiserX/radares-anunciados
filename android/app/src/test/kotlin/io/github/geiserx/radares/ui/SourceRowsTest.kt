// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Fuentes tab shows one row per source: a source whose radars carry several attribution strings is still one
// row with the total count, each string once.

package io.github.geiserx.radares.ui

import io.github.geiserx.radares.core.model.Coordinate
import io.github.geiserx.radares.core.model.Kind
import io.github.geiserx.radares.core.model.Radar
import io.github.geiserx.radares.core.model.Role
import org.junit.Assert.assertEquals
import org.junit.Test

class SourceRowsTest {
    private fun radar(id: Int, source: String, attribution: String) = Radar(
        id = "$source-$id", kind = Kind.FIXED, role = Role.POINT, start = Coordinate(41.0, -1.0),
        name = "r$id", source = source, attribution = attribution,
    )

    @Test
    fun oneRowPerSourceWithEachAttributionOnce() {
        val dgt = "Dirección General de Tráfico (CC BY 4.0)"
        val dgtRoad = "$dgt; carretera: © OpenStreetMap contributors (ODbL 1.0)"
        val osm = "© OpenStreetMap contributors (ODbL 1.0)"
        val radars = List(3) { radar(it, "dgt", dgtRoad) } + List(2) { radar(10 + it, "dgt", dgt) } +
            List(4) { radar(20 + it, "osm", osm) }

        val rows = sourceRows(radars)

        assertEquals(listOf("dgt", "osm"), rows.map { it.source })
        assertEquals(5, rows[0].count)
        assertEquals(listOf(dgtRoad, dgt), rows[0].attributions)
        assertEquals(4, rows[1].count)
        assertEquals(listOf(osm), rows[1].attributions)
    }
}
