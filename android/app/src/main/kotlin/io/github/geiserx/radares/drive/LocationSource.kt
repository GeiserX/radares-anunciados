// SPDX-License-Identifier: GPL-3.0-or-later
//
// Where the fixes come from: the fused provider at 1 Hz in the app, a list of fixes in the tests.

package io.github.geiserx.radares.drive

import android.annotation.SuppressLint
import android.content.Context
import android.location.Location
import android.os.Looper
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import io.github.geiserx.radares.core.model.Coordinate
import io.github.geiserx.radares.core.model.Fix
import java.time.Instant

interface LocationSource {
    /** Starts delivering fixes on the main thread; returns null or the failure text. */
    fun start(onFix: (Fix) -> Unit): String?
    fun stop()
}

/** FusedLocationProviderClient, high accuracy, one fix per second (SPEC 8). */
class FusedLocationSource(
    context: Context,
    private val stationary: () -> Boolean,
) : LocationSource {
    private val client: FusedLocationProviderClient = LocationServices.getFusedLocationProviderClient(context)
    private var callback: LocationCallback? = null

    @SuppressLint("MissingPermission")
    override fun start(onFix: (Fix) -> Unit): String? {
        stop()
        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000L)
            .setMinUpdateIntervalMillis(1000L)
            .setWaitForAccurateLocation(false)
            .build()
        val cb = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                result.locations.forEach { onFix(toFix(it, stationary())) }
            }
        }
        callback = cb
        return try {
            client.requestLocationUpdates(request, cb, Looper.getMainLooper())
            null
        } catch (e: SecurityException) {
            callback = null
            "SecurityException: ${e.message}"
        }
    }

    override fun stop() {
        callback?.let { client.removeLocationUpdates(it) }
        callback = null
    }

    companion object {
        /** A platform location as a core fix: speed and course null when the platform marks them missing. */
        fun toFix(location: Location, stationary: Boolean): Fix = Fix(
            coordinate = Coordinate(location.latitude, location.longitude),
            timestamp = Instant.ofEpochMilli(location.time),
            speed = if (location.hasSpeed()) location.speed.toDouble() else null,
            course = if (location.hasBearing()) location.bearing.toDouble() else null,
            horizontalAccuracy = if (location.hasAccuracy()) location.accuracy.toDouble() else 0.0,
            isStationary = stationary,
        )
    }
}
