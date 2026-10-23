// SPDX-License-Identifier: GPL-3.0-or-later
//
// The car screen's content and templates: at most six rows, nearest first, each with its source; the idle and
// loading states; the sources screen with the map attribution.

package io.github.geiserx.radares.car

import androidx.car.app.model.MessageTemplate
import androidx.car.app.model.PlaceListMapTemplate
import androidx.car.app.model.Row
import io.github.geiserx.radares.core.feed.RadarStore
import io.github.geiserx.radares.core.model.Coordinate
import io.github.geiserx.radares.core.model.Kind
import io.github.geiserx.radares.core.model.Radar
import io.github.geiserx.radares.core.model.Role
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.time.Instant
import java.util.Locale

@Suppress("DEPRECATION")
@RunWith(RobolectricTestRunner::class)
class NearbyScreenTest {
    private val es = Locale.forLanguageTag("es-ES")
    private val here = Coordinate(40.4168, -3.7038)
    private val now = Instant.parse("2026-10-23T10:00:00Z")

    /** `count` fixed radars due north of `here`, 300 m apart, listed farthest first so the order is the store's. */
    private fun store(count: Int): RadarStore = RadarStore(
        (count downTo 1).map { i ->
            Radar(
                id = "dgt-$i",
                kind = Kind.FIXED,
                role = Role.POINT,
                start = Coordinate(here.latitude + i * 300 / 111_320.0, here.longitude),
                name = "Radar $i",
                road = "A-$i",
                kmFrom = i.toDouble(),
                maxspeed = if (i == 1) 90 else null,
                source = if (i % 2 == 0) "dgt" else "osm",
                attribution = if (i % 2 == 0) "Dirección General de Tráfico (CC BY 4.0)" else "© OpenStreetMap contributors (ODbL 1.0)",
            )
        },
    )

    @Test
    fun atMostSixRowsNearestFirstEachWithItsSource() {
        val content = NearbyContent.make(here, store(9), now, es)
        assertEquals(NearbyContent.MAX_ROWS, content.rows.size)
        assertEquals((1..6).map { "dgt-$it" }, content.rows.map { it.radarId })
        assertEquals(300, content.rows.first().distanceMetres)
        assertEquals("Radar fijo", content.rows.first().title)
        assertEquals("A-1 km 1 · límite 90 km/h", content.rows.first().detail)

        val template = CarTemplates.nearby(content, es, showCurrentLocation = false) {}
        assertTrue(template is PlaceListMapTemplate)
        val rows = template.itemList!!.items.map { it as Row }
        assertEquals(6, rows.size)
        rows.zip(content.rows).forEach { (row, expected) ->
            assertEquals(expected.title, row.title.toString())
            val texts = row.texts.map { it.toString() }
            assertTrue("row ${expected.radarId} has no source: $texts", texts.any { it == expected.source })
            assertTrue(row.metadata.place != null)
        }
    }

    @Test
    fun idleSaysNoRadarsNearby() {
        val content = NearbyContent.make(here, store(0), now, es)
        assertTrue(content.rows.isEmpty())
        val template = CarTemplates.nearby(content, es, showCurrentLocation = false) {}
        assertEquals(0, template.itemList!!.items.size)
        assertEquals("Sin radares cerca", template.itemList!!.noItemsMessage.toString())
        assertFalse(template.isLoading)

        val english = NearbyContent.make(here, store(0), now, Locale.ENGLISH)
        assertEquals("No radars nearby", english.emptyMessage)
    }

    @Test
    fun radarsBeyondTheRadiusAreNotListed() {
        val far = Coordinate(here.latitude + 1.0, here.longitude) // about 111 km north
        val content = NearbyContent.make(far, store(3), now, es)
        assertTrue(content.rows.isEmpty())
    }

    @Test
    fun loadingUntilAPositionIsKnown() {
        val content = NearbyContent.make(null, store(3), now, es)
        assertFalse(content.hasPosition)
        assertTrue(CarTemplates.nearby(content, es, showCurrentLocation = false) {}.isLoading)
    }

    @Test
    fun sourcesScreenListsEveryAttributionAndTheMap() {
        val content = NearbyContent.make(here, store(4), now, es)
        val template: MessageTemplate = CarTemplates.sources(content, es)
        val text = template.message.toString()
        assertTrue(text.contains("Dirección General de Tráfico (CC BY 4.0)"))
        assertTrue(text.contains("© OpenStreetMap contributors (ODbL 1.0)"))
        assertTrue(text.contains("© OpenStreetMap contributors, ODbL"))
        assertEquals("Fuentes", template.title.toString())
    }
}
