// SPDX-License-Identifier: GPL-3.0-or-later
//
// The radar list on the car screen. It recomputes from the latest position at most once every 10 seconds and asks
// the host for a new template only when the rows changed, so it is never a live countdown and stays inside the
// host's template refresh limits.

package io.github.geiserx.radares.car

import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.model.Template
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.Locale

class NearbyScreen(
    carContext: CarContext,
    private val data: CarData,
    private val now: () -> Instant = Instant::now,
) : Screen(carContext) {
    private val locale: Locale get() = carContext.resources.configuration.locales[0]
    private var content: NearbyContent = compute()

    init {
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                while (true) {
                    delay(REFRESH_MS)
                    val next = compute()
                    if (next != content) {
                        content = next
                        invalidate()
                    }
                }
            }
        }
    }

    private fun compute(): NearbyContent = NearbyContent.make(data.position(), data.store(), now(), locale)

    override fun onGetTemplate(): Template =
        CarTemplates.nearby(content, locale, data.locationPermitted()) {
            screenManager.push(SourcesScreen(carContext, content))
        }

    companion object {
        /** The CarPlay screen's limit, kept for Android Auto: no data item refreshes more often than this. */
        const val REFRESH_MS = 10_000L
    }
}

class SourcesScreen(carContext: CarContext, private val content: NearbyContent) : Screen(carContext) {
    override fun onGetTemplate(): Template =
        CarTemplates.sources(content, carContext.resources.configuration.locales[0])
}
