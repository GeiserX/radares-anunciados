// SPDX-License-Identifier: GPL-3.0-or-later
//
// CarData over the app's shared state: the current drive's last fix from AppGraph.snapshot, else the last
// position Play Services knows (asked once when the car screen opens), and the radar store the feed loaded.

package io.github.geiserx.radares.car

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import com.google.android.gms.location.LocationServices
import io.github.geiserx.radares.AppGraph
import io.github.geiserx.radares.RadaresApp
import io.github.geiserx.radares.core.feed.RadarStore
import io.github.geiserx.radares.core.model.Coordinate

class AppCarData private constructor(private val context: Context, private val graph: AppGraph) : CarData {
    @Volatile
    private var lastKnown: Coordinate? = null

    init {
        if (locationPermitted()) {
            runCatching {
                LocationServices.getFusedLocationProviderClient(context).lastLocation
                    .addOnSuccessListener { location ->
                        if (location != null) lastKnown = Coordinate(location.latitude, location.longitude)
                    }
            }
        }
    }

    override fun position(): Coordinate? = graph.snapshot.value?.lastFix?.coordinate ?: lastKnown

    override fun store(): RadarStore? = graph.feed.store.value

    override fun locationPermitted(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    companion object {
        fun from(context: Context): AppCarData = AppCarData(context.applicationContext, RadaresApp.graph(context))
    }
}
