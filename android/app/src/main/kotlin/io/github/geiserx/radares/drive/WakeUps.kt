// SPDX-License-Identifier: GPL-3.0-or-later
//
// The two co-equal wake-ups of SPEC 8, both with zero GPS while parked:
//   - Activity Recognition transitions: IN_VEHICLE enter/exit, ON_FOOT enter, STILL enter -> TransitionReceiver.
//   - A 400 m EXIT geofence around the parked position -> GeofenceReceiver.
// Both survive the app process; neither survives a reboot, so BootReceiver registers them again.
// Every registration outcome is kept in SharedPreferences for the Estado rows "Transiciones" and "Valla de aparcamiento".

package io.github.geiserx.radares.drive

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.DetectedActivity
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices
import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.model.Coordinate

/** What woke the drive service. */
enum class Wake(val wire: String) {
    InVehicle("in_vehicle"),
    OnFoot("on_foot"),
    Still("still"),
    Fence("fence"),
    SelfTest("self_test");

    companion object {
        fun from(wire: String?): Wake? = entries.firstOrNull { it.wire == wire }
    }
}

object WakeUps {
    private const val PREFS = "wakeups"
    private const val FENCE_ID = "radares.parked"
    const val KEY_FENCE_LAT = "fence.lat"
    const val KEY_FENCE_LON = "fence.lon"
    const val KEY_FENCE_RESULT = "fence.result"
    const val KEY_FENCE_AT = "fence.at"
    const val KEY_TRANSITIONS_RESULT = "transitions.result"
    const val KEY_TRANSITIONS_AT = "transitions.at"
    /** Newest transition seen: "IN_VEHICLE:0", "STILL:0", "ON_FOOT:0" and its time. */
    const val KEY_LAST_TRANSITION = "transition.last"
    const val KEY_LAST_TRANSITION_AT = "transition.at"
    const val OK = "ok"

    fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Registers both wake-ups; the fence only when a parked position is known. */
    fun register(context: Context) {
        registerTransitions(context)
        parkedPosition(context)?.let { armFence(context, it) }
    }

    @SuppressLint("MissingPermission")
    fun registerTransitions(context: Context) {
        if (!granted(context, Manifest.permission.ACTIVITY_RECOGNITION)) {
            record(context, KEY_TRANSITIONS_RESULT, KEY_TRANSITIONS_AT, "permission denied")
            return
        }
        val transitions = listOf(
            transition(DetectedActivity.IN_VEHICLE, ActivityTransition.ACTIVITY_TRANSITION_ENTER),
            transition(DetectedActivity.IN_VEHICLE, ActivityTransition.ACTIVITY_TRANSITION_EXIT),
            transition(DetectedActivity.ON_FOOT, ActivityTransition.ACTIVITY_TRANSITION_ENTER),
            transition(DetectedActivity.STILL, ActivityTransition.ACTIVITY_TRANSITION_ENTER),
        )
        try {
            ActivityRecognition.getClient(context)
                .requestActivityTransitionUpdates(ActivityTransitionRequest(transitions), transitionIntent(context))
                .addOnSuccessListener { record(context, KEY_TRANSITIONS_RESULT, KEY_TRANSITIONS_AT, OK) }
                .addOnFailureListener { record(context, KEY_TRANSITIONS_RESULT, KEY_TRANSITIONS_AT, it.message ?: it.javaClass.simpleName) }
        } catch (e: SecurityException) {
            record(context, KEY_TRANSITIONS_RESULT, KEY_TRANSITIONS_AT, "SecurityException: ${e.message}")
        }
    }

    /** The parked fence: an EXIT fence of Thresholds.fenceRadiusM around `at`, replacing any earlier one. */
    @SuppressLint("MissingPermission")
    fun armFence(context: Context, at: Coordinate) {
        prefs(context).edit {
            putLong(KEY_FENCE_LAT, java.lang.Double.doubleToRawLongBits(at.latitude))
            putLong(KEY_FENCE_LON, java.lang.Double.doubleToRawLongBits(at.longitude))
        }
        if (!granted(context, Manifest.permission.ACCESS_FINE_LOCATION) || !granted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION)) {
            record(context, KEY_FENCE_RESULT, KEY_FENCE_AT, "permission denied")
            return
        }
        val fence = Geofence.Builder()
            .setRequestId(FENCE_ID)
            .setCircularRegion(at.latitude, at.longitude, Thresholds.fenceRadiusM.toFloat())
            .setExpirationDuration(Geofence.NEVER_EXPIRE)
            .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_EXIT)
            .build()
        val request = GeofencingRequest.Builder()
            // No initial trigger: arming the fence where the car stands must not wake a drive.
            .setInitialTrigger(0)
            .addGeofence(fence)
            .build()
        try {
            val client = LocationServices.getGeofencingClient(context)
            client.removeGeofences(listOf(FENCE_ID))
            client.addGeofences(request, fenceIntent(context))
                .addOnSuccessListener { record(context, KEY_FENCE_RESULT, KEY_FENCE_AT, OK) }
                .addOnFailureListener { record(context, KEY_FENCE_RESULT, KEY_FENCE_AT, it.message ?: it.javaClass.simpleName) }
        } catch (e: SecurityException) {
            record(context, KEY_FENCE_RESULT, KEY_FENCE_AT, "SecurityException: ${e.message}")
        }
    }

    fun parkedPosition(context: Context): Coordinate? {
        val p = prefs(context)
        if (!p.contains(KEY_FENCE_LAT)) return null
        return Coordinate(
            latitude = java.lang.Double.longBitsToDouble(p.getLong(KEY_FENCE_LAT, 0)),
            longitude = java.lang.Double.longBitsToDouble(p.getLong(KEY_FENCE_LON, 0)),
        )
    }

    /** Records the newest transition, for the stationary flag and the "in vehicle in the last 3 min" start. */
    fun noteTransition(context: Context, activity: Int, transition: Int, atMillis: Long) {
        prefs(context).edit {
            putString(KEY_LAST_TRANSITION, "$activity:$transition")
            putLong(KEY_LAST_TRANSITION_AT, atMillis)
        }
    }

    private fun transition(activity: Int, type: Int) =
        ActivityTransition.Builder().setActivityType(activity).setActivityTransition(type).build()

    // Explicit intents to non-exported receivers; mutable because Play Services fills in the result extras.
    private fun transitionIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context, 1, Intent(context, TransitionReceiver::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
    )

    private fun fenceIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context, 2, Intent(context, GeofenceReceiver::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
    )

    private fun record(context: Context, key: String, atKey: String, value: String) {
        prefs(context).edit {
            putString(key, value)
            putLong(atKey, System.currentTimeMillis())
        }
    }

    private fun granted(context: Context, permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
}
