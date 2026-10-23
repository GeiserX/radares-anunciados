// SPDX-License-Identifier: GPL-3.0-or-later
//
// Activity Recognition transitions (not exported; Play Services delivers through the explicit PendingIntent).
// IN_VEHICLE enter starts the drive service at once; ON_FOOT enter ends a drive; STILL enter marks the fixes
// stationary; IN_VEHICLE exit is only recorded (a red light is not the end of a drive).

package io.github.geiserx.radares.drive

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity

class TransitionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val result = ActivityTransitionResult.extractResult(intent) ?: return
        val newest = result.transitionEvents.maxByOrNull { it.elapsedRealTimeNanos } ?: return
        val wallMillis = System.currentTimeMillis() -
            (android.os.SystemClock.elapsedRealtimeNanos() - newest.elapsedRealTimeNanos) / 1_000_000
        WakeUps.noteTransition(context, newest.activityType, newest.transitionType, wallMillis)
        if (newest.transitionType != ActivityTransition.ACTIVITY_TRANSITION_ENTER) return
        when (newest.activityType) {
            DetectedActivity.IN_VEHICLE -> DriveService.start(context, Wake.InVehicle)
            DetectedActivity.ON_FOOT -> DriveService.notify(context, Wake.OnFoot)
            DetectedActivity.STILL -> DriveService.notify(context, Wake.Still)
        }
    }
}
