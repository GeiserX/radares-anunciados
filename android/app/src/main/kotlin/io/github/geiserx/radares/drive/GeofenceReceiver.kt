// SPDX-License-Identifier: GPL-3.0-or-later
//
// The parked fence's EXIT (not exported). Starts the drive service, which probes for 60 s and stops when the
// phone is not in a car.

package io.github.geiserx.radares.drive

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.edit
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent

class GeofenceReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val event = GeofencingEvent.fromIntent(intent) ?: return
        if (event.hasError()) {
            WakeUps.prefs(context).edit { putString(WakeUps.KEY_FENCE_RESULT, "error ${event.errorCode}") }
            return
        }
        if (event.geofenceTransition == Geofence.GEOFENCE_TRANSITION_EXIT) {
            DriveService.start(context, Wake.Fence)
        }
    }
}
