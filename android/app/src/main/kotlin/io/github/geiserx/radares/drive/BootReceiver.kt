// SPDX-License-Identifier: GPL-3.0-or-later
//
// Geofences and transition requests do not survive a reboot or an app update: register both again.

package io.github.geiserx.radares.drive

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            WakeUps.register(context)
        }
    }
}
