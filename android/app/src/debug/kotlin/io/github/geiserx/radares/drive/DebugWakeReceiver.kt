// SPDX-License-Identifier: GPL-3.0-or-later
//
// Debug builds only (src/debug). `adb shell am broadcast -a io.github.geiserx.radares.DEBUG_WAKE --es reason in_vehicle
// -n io.github.geiserx.radares/.drive.DebugWakeReceiver` stands in for an IN_VEHICLE transition on an emulator,
// through the same startForegroundService path the real receivers use.

package io.github.geiserx.radares.drive

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class DebugWakeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        val wake = when (intent.getStringExtra("reason")) {
            "in_vehicle", null -> Wake.InVehicle
            "fence" -> Wake.Fence
            "on_foot" -> Wake.OnFoot
            else -> Wake.InVehicle
        }
        DriveService.start(context, wake)
    }

    companion object {
        const val ACTION = "io.github.geiserx.radares.DEBUG_WAKE"
    }
}
