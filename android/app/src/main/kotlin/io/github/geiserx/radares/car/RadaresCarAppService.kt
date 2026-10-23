// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Car App Library entry point, category POI (docs/ANDROID-AUTO.md). Being a Car App Library app is what lets
// Android Auto draw the CarAppExtender warning notifications as a banner; the one screen lists the nearest
// published radars with their sources. Nothing here starts or stops a drive.

package io.github.geiserx.radares.car

import android.content.Context
import android.content.Intent
import androidx.car.app.CarAppService
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.car.app.validation.HostValidator
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import io.github.geiserx.radares.BuildConfig
import io.github.geiserx.radares.R
import io.github.geiserx.radares.RadaresApp

class RadaresCarAppService : CarAppService() {
    override fun createHostValidator(): HostValidator = hostValidator(this, BuildConfig.DEBUG)

    override fun onCreateSession(): Session = RadaresCarSession()

    companion object {
        /** Debug builds accept any host so the Desktop Head Unit connects; release builds only Android Auto's. */
        fun hostValidator(context: Context, debug: Boolean): HostValidator =
            if (debug) {
                HostValidator.ALLOW_ALL_HOSTS_VALIDATOR
            } else {
                HostValidator.Builder(context).addAllowedHosts(R.array.hosts_allowlist).build()
            }
    }
}

/** One per car connection. Its lifecycle sets AppGraph.carHostConnected, which the Estado "Android Auto" row reads. */
class RadaresCarSession : Session() {
    init {
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onCreate(owner: LifecycleOwner) {
                RadaresApp.graph(carContext).carHostConnected.value = true
            }

            override fun onDestroy(owner: LifecycleOwner) {
                RadaresApp.graph(carContext).carHostConnected.value = false
            }
        })
    }

    override fun onCreateScreen(intent: Intent): Screen = NearbyScreen(carContext, AppCarData.from(carContext))
}
