// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the Android Auto radar screen shows, pure over a position, the radar store and the day, so a JVM test
// asserts it (the Android counterpart of CarPlayContent in App/Sources/Surfaces/CarPlayScene.swift). Up to six of
// the nearest alertable radars, nearest first, each with its source. Not a card the driver keeps on screen: the
// warning itself is the CarAppExtender notification posted by surfaces/Notifier.kt.

package io.github.geiserx.radares.car

import io.github.geiserx.radares.core.feed.RadarStore
import io.github.geiserx.radares.core.model.Coordinate
import io.github.geiserx.radares.core.phrasing.Phrasing
import java.time.Instant
import java.util.Locale

data class NearbyRow(
    val radarId: String,
    /** "Radar fijo", "Tramo de radar móvil"... */
    val title: String,
    /** Rounded as the voice rounds it, so the car never shows a figure the voice did not say. */
    val distanceMetres: Int,
    /** Road and km or the name, then the limit when published. */
    val detail: String,
    /** The feed's attribution for this radar, verbatim. */
    val source: String,
    val position: Coordinate,
)

data class NearbyContent(
    val title: String,
    val rows: List<NearbyRow>,
    /** Shown in place of the list when it is empty. */
    val emptyMessage: String,
    /** Every distinct attribution on screen, then the map's. */
    val attributions: List<String>,
    /** False until the first position is known: the template shows its loading state. */
    val hasPosition: Boolean,
) {
    /**
     * Whether the car host counts `next` as a refresh of this content, which costs nothing against its template quota:
     * this one was still loading, or the screen title, the number of rows and each row's title are unchanged (the
     * rule in PlaceListMapTemplate's documentation). Anything else is a new template.
     */
    fun isRefreshedBy(next: NearbyContent): Boolean =
        !hasPosition || (title == next.title && rows.map { it.title } == next.rows.map { it.title })

    /** The same rows in the same order with their distances from `position`, so the host takes it as a refresh. */
    fun withDistancesFrom(position: Coordinate?, store: RadarStore?): NearbyContent {
        if (position == null || store == null) return this
        return copy(
            rows = rows.map { row ->
                val radar = store.radar(row.radarId) ?: return@map row
                row.copy(distanceMetres = Phrasing.roundedDistance(RadarStore.distance(position, radar)))
            },
        )
    }

    companion object {
        const val MAX_ROWS = 6
        /** Radars farther than this are not listed: the screen is about what is near, not a map of Spain. */
        const val RADIUS_M = 10_000.0
        const val APP_TITLE = "Radares Anunciados"
        const val MAP_ATTRIBUTION = "© OpenStreetMap contributors, ODbL"

        fun make(position: Coordinate?, store: RadarStore?, now: Instant, locale: Locale): NearbyContent {
            val en = Phrasing.isEnglish(locale)
            val empty = if (en) "No radars nearby" else "Sin radares cerca"
            if (position == null || store == null) {
                return NearbyContent(APP_TITLE, emptyList(), empty, listOf(MAP_ATTRIBUTION), hasPosition = false)
            }
            val rows = store.candidates(position, RADIUS_M, now).take(MAX_ROWS).map { radar ->
                val parts = mutableListOf(Phrasing.subtitle(radar, locale))
                radar.maxspeed?.let { parts.add(if (en) "limit $it km/h" else "límite $it km/h") }
                NearbyRow(
                    radarId = radar.id,
                    title = Phrasing.kindTitle(radar, locale),
                    distanceMetres = Phrasing.roundedDistance(RadarStore.distance(position, radar)),
                    detail = parts.joinToString(" · "),
                    source = radar.attribution,
                    position = radar.start,
                )
            }
            val attributions = rows.map { it.source }.distinct() + MAP_ATTRIBUTION
            return NearbyContent(APP_TITLE, rows, empty, attributions, hasPosition = true)
        }
    }
}
