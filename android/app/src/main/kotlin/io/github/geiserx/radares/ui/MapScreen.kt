// SPDX-License-Identifier: GPL-3.0-or-later
//
// Mapa: OpenStreetMap raster tiles through osmdroid, the published radars within 5 km of the map centre as markers
// coloured by kind like the iOS map (tap one for its source), and the card from the drive snapshot ("Sin radares
// cerca" when idle). The card is for a glance while the app happens to be open; the warnings never depend on it.
//
// OSM tile policy (https://operations.osmfoundation.org/policies/tiles/): a user agent that names the app and its
// repository, the visible attribution, osmdroid's own cache of tiles already viewed, and nothing else: no
// CacheManager, no prefetch, no offline download.

package io.github.geiserx.radares.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import io.github.geiserx.radares.AppGraph
import io.github.geiserx.radares.BuildConfig
import io.github.geiserx.radares.R
import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.engine.DriveContent
import io.github.geiserx.radares.core.feed.RadarStore
import io.github.geiserx.radares.core.model.Coordinate
import io.github.geiserx.radares.core.model.Kind
import io.github.geiserx.radares.core.phrasing.Phrasing
import org.osmdroid.config.Configuration
import org.osmdroid.events.MapListener
import org.osmdroid.events.ScrollEvent
import org.osmdroid.events.ZoomEvent
import org.osmdroid.tileprovider.tilesource.TileSourcePolicy
import org.osmdroid.tileprovider.tilesource.XYTileSource
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.CopyrightOverlay
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.TilesOverlay
import java.io.File
import java.time.Instant
import java.util.Locale

/** The app's user agent for tile requests, as the OSM tile policy asks. */
fun tileUserAgent(): String = "RadaresAnunciados/${BuildConfig.VERSION_NAME} (https://github.com/GeiserX/radares-anunciados)"

/** The standard OSM tiles with the ODbL attribution and the policy flags (no bulk, no prefetch). */
fun osmTiles(attribution: String) = XYTileSource(
    "Mapnik", 0, 19, 256, ".png", arrayOf("https://tile.openstreetmap.org/"), attribution,
    TileSourcePolicy(
        2,
        TileSourcePolicy.FLAG_NO_BULK or TileSourcePolicy.FLAG_NO_PREVENTIVE or
            TileSourcePolicy.FLAG_USER_AGENT_MEANINGFUL or TileSourcePolicy.FLAG_USER_AGENT_NORMALIZED,
    ),
)

/** Spain's centre, where the map opens before any position is known. */
private val SPAIN = Coordinate(40.4168, -3.7038)

@Composable
fun MapScreen(graph: AppGraph) {
    val context = LocalContext.current
    val snapshot by graph.snapshot.collectAsState()
    val store by graph.feed.store.collectAsState()
    val locale = LocalConfiguration.current.locales[0]
    val attribution = stringResource(R.string.map_attribution)
    val sourceLabel = stringResource(R.string.marker_source, "%s")
    val map = remember { createMap(context, attribution) }

    DisposableEffect(map) {
        map.onResume()
        onDispose { map.onPause() }
    }

    LaunchedEffect(snapshot?.lastFix?.coordinate, store) {
        val at = snapshot?.lastFix?.coordinate
        if (at != null) map.controller.animateTo(GeoPoint(at.latitude, at.longitude))
        showRadars(map, store, locale, sourceLabel)
    }

    Box(Modifier.fillMaxSize()) {
        AndroidView(factory = {
            map.addMapListener(object : MapListener {
                override fun onScroll(event: ScrollEvent?): Boolean = false.also { showRadars(map, graph.feed.store.value, locale, sourceLabel) }
                override fun onZoom(event: ZoomEvent?): Boolean = false
            })
            map
        }, modifier = Modifier.fillMaxSize())
        RadarCard(
            content = snapshot?.content ?: DriveContent.watching(Instant.now(), locale),
            modifier = Modifier.align(Alignment.BottomCenter).padding(12.dp),
        )
    }
}

@SuppressLint("ClickableViewAccessibility")
private fun createMap(context: Context, attribution: String): MapView {
    Configuration.getInstance().apply {
        userAgentValue = tileUserAgent()
        // App-private cache dirs: no storage permission, and Android may clear them.
        osmdroidBasePath = File(context.cacheDir, "osmdroid")
        osmdroidTileCache = File(context.cacheDir, "osmdroid/tiles")
    }
    return MapView(context).apply {
        setTileSource(osmTiles(attribution))
        setMultiTouchControls(true)
        // Dark map: the tiles' colours inverted, like the rest of the app.
        overlayManager.tilesOverlay.setColorFilter(TilesOverlay.INVERT_COLORS)
        overlays.add(CopyrightOverlay(context).apply { setTextColor(android.graphics.Color.WHITE) })
        controller.setZoom(14.0)
        controller.setCenter(GeoPoint(SPAIN.latitude, SPAIN.longitude))
    }
}

/** Markers for every radar within Thresholds.mapRadiusM of the map centre, with the source in the bubble. */
private fun showRadars(map: MapView, store: RadarStore?, locale: Locale, sourceLabel: String) {
    val center = map.mapCenter.let { Coordinate(it.latitude, it.longitude) }
    map.overlays.removeAll { it is Marker }
    val icons = mutableMapOf<Kind, Drawable>()
    store?.all?.asSequence()
        ?.filter { RadarStore.distance(center, it) <= Thresholds.mapRadiusM }
        ?.take(300)
        ?.forEach { radar ->
            map.overlays.add(Marker(map).apply {
                position = GeoPoint(radar.start.latitude, radar.start.longitude)
                title = Phrasing.kindTitle(radar, locale)
                snippet = Phrasing.body(radar, locale)
                subDescription = sourceLabel.replace("%s", radar.attribution.ifEmpty { radar.source })
                icon = icons.getOrPut(radar.kind) { markerIcon(map.context, radar.kind) }
                setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
            })
        }
    map.invalidate()
}

/** The marker's colour and glyph per kind, the same as the iOS map: red camera, orange road, blue car, purple
 *  truck, grey question mark. Colours are iOS's dark-mode system colours. */
internal fun markerStyle(kind: Kind): Pair<Int, Int> = when (kind) {
    Kind.FIXED -> 0xFFFF453A.toInt() to R.drawable.ic_stat_radar
    Kind.SECTION, Kind.STRETCH -> 0xFFFF9F0A.toInt() to R.drawable.ic_marker_road
    Kind.MOBILE_ANNOUNCED, Kind.MOBILE_RECURRING -> 0xFF0A84FF.toInt() to R.drawable.ic_marker_car
    Kind.TRAILER -> 0xFFBF5AF2.toInt() to R.drawable.ic_marker_truck
    Kind.REPORTED -> 0xFF8E8E93.toInt() to R.drawable.ic_marker_question
}

/** A filled disc in the kind's colour with a white rim and the white glyph inside, 30 dp across. */
private fun markerIcon(context: Context, kind: Kind): Drawable {
    val (color, glyph) = markerStyle(kind)
    val density = context.resources.displayMetrics.density
    val size = (30 * density).toInt()
    val disc = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(color)
        setStroke((2 * density).toInt(), android.graphics.Color.WHITE)
        setSize(size, size)
    }
    // The layer's intrinsic size is the glyph's size plus its insets, so the 24 dp glyph is sized down to fit
    // inside 30 dp; left at 24 dp it would make the marker 38 dp.
    val inset = (7 * density).toInt()
    val glyphSize = size - 2 * inset
    return LayerDrawable(arrayOf(disc, ContextCompat.getDrawable(context, glyph)!!)).apply {
        setLayerSize(1, glyphSize, glyphSize)
        setLayerInset(1, inset, inset, inset, inset)
    }
}

@Composable
fun RadarCard(content: DriveContent, modifier: Modifier = Modifier) {
    val locale = LocalConfiguration.current.locales[0]
    Card(
        modifier = modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f)),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(content.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                content.distanceMetres?.let { Text(stringResource(R.string.card_distance, it), style = MaterialTheme.typography.titleLarge) }
            }
            if (content.subtitle.isNotEmpty()) Text(content.subtitle, style = MaterialTheme.typography.bodyLarge)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                content.limit?.let { Text(stringResource(R.string.card_limit, it), color = Amber) }
                if (content.opposite) Text(stringResource(R.string.card_opposite), color = MaterialTheme.colorScheme.onSurfaceVariant)
                content.stretchRemainingMetres?.let {
                    Text(stringResource(R.string.card_remaining, Phrasing.lengthText(it.toDouble(), locale)))
                }
                content.avgKmh?.let { Text(stringResource(R.string.card_average, it)) }
            }
        }
    }
}
