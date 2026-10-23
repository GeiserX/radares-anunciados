// SPDX-License-Identifier: GPL-3.0-or-later
//
// Builds the two car templates from NearbyContent. Kept apart from the Screen classes so a test can build and read
// them without a car host.

package io.github.geiserx.radares.car

import android.text.SpannableString
import android.text.Spanned
import androidx.car.app.model.Action
import androidx.car.app.model.ActionStrip
import androidx.car.app.model.CarLocation
import androidx.car.app.model.Distance
import androidx.car.app.model.DistanceSpan
import androidx.car.app.model.ItemList
import androidx.car.app.model.MessageTemplate
import androidx.car.app.model.Metadata
import androidx.car.app.model.Place
import androidx.car.app.model.PlaceListMapTemplate
import androidx.car.app.model.PlaceMarker
import androidx.car.app.model.Row
import java.util.Locale

object CarTemplates {
    fun sourcesLabel(locale: Locale): String = if (locale.language == "en") "Sources" else "Fuentes"

    /** The radar list on the car's map. `onSources` opens the attributions. */
    @Suppress("DEPRECATION") // PlaceListMapTemplate is the POI map template that works from car API level 1.
    fun nearby(
        content: NearbyContent,
        locale: Locale,
        showCurrentLocation: Boolean,
        onRefresh: (() -> Unit)? = null,
        onSources: () -> Unit,
    ): PlaceListMapTemplate {
        val builder = PlaceListMapTemplate.Builder()
            .setTitle(content.title)
            .setHeaderAction(Action.APP_ICON)
            .setCurrentLocationEnabled(showCurrentLocation)
            .setActionStrip(
                ActionStrip.Builder()
                    .addAction(
                        Action.Builder()
                            .setTitle(sourcesLabel(locale))
                            .setOnClickListener { onSources() }
                            .build(),
                    )
                    .build(),
            )
        // Car API 5 and later: the driver's refresh request, which the host never counts against its quota.
        onRefresh?.let { refresh -> builder.setOnContentRefreshListener { refresh() } }
        if (!content.hasPosition) return builder.setLoading(true).build()
        val list = ItemList.Builder().setNoItemsMessage(content.emptyMessage)
        content.rows.forEach { list.addItem(row(it)) }
        return builder.setItemList(list.build()).build()
    }

    fun row(row: NearbyRow): Row {
        // The host wants the distance as a DistanceSpan so it can render it in the car's units.
        val distance = SpannableString("  · ${row.detail}").apply {
            setSpan(
                DistanceSpan.create(Distance.create(row.distanceMetres.toDouble(), Distance.UNIT_METERS)),
                0, 1, Spanned.SPAN_INCLUSIVE_INCLUSIVE,
            )
        }
        return Row.Builder()
            .setTitle(row.title)
            .addText(distance)
            .addText(row.source)
            .setMetadata(
                Metadata.Builder()
                    .setPlace(
                        Place.Builder(CarLocation.create(row.position.latitude, row.position.longitude))
                            .setMarker(PlaceMarker.Builder().build())
                            .build(),
                    )
                    .build(),
            )
            .build()
    }

    /** Every attribution of the radars on screen, verbatim, and the map's. */
    fun sources(content: NearbyContent, locale: Locale): MessageTemplate =
        MessageTemplate.Builder(content.attributions.joinToString("\n"))
            .setTitle(sourcesLabel(locale))
            .setHeaderAction(Action.BACK)
            .build()
}
