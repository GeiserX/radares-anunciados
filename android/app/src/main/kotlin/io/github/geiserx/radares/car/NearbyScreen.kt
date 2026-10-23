// SPDX-License-Identifier: GPL-3.0-or-later
//
// The radar list on the car screen. It recomputes from the latest position at most once every 10 seconds and asks
// the host for a new template only when the rows changed, so it is never a live countdown.
//
// The host allows five templates per task and closes the app with an error when a sixth arrives. A template with the
// same row count and row titles is a refresh and costs nothing, so most updates are free: new distances, or one
// radar replaced by another of the same kind. A different set of rows costs one, so the screen spends at most
// NEW_SETS of them by itself; after that it keeps the rows it shows and only updates their distances until the
// driver asks for a refresh (free, car API 5 and later) or opens the app again from the launcher or a warning,
// which starts a new task with a new quota.

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
    private var newSetsLeft = NEW_SETS

    init {
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                while (true) {
                    delay(REFRESH_MS)
                    val (next, spent) = next(content, compute(), data, newSetsLeft)
                    newSetsLeft -= spent
                    if (next != content) {
                        content = next
                        invalidate()
                    }
                }
            }
        }
    }

    private fun compute(): NearbyContent = NearbyContent.make(data.position(), data.store(), now(), locale)

    override fun onGetTemplate(): Template {
        // The driver's own refresh request is never counted against the quota, so it may bring in any new set.
        val onRefresh: (() -> Unit)? = if (carContext.carAppApiLevel >= 5) {
            { content = compute(); invalidate() }
        } else {
            null
        }
        return CarTemplates.nearby(content, locale, data.locationPermitted(), onRefresh) {
            screenManager.push(SourcesScreen(carContext, content))
        }
    }

    companion object {
        /** The CarPlay screen's limit, kept for Android Auto: no data item refreshes more often than this. */
        const val REFRESH_MS = 10_000L

        /**
         * New row sets the screen sends by itself. Quota arithmetic: the first template (1) plus these (2) plus the
         * Sources screen (1) is 4 of the host's 5; going back from Sources gives its template back.
         */
        const val NEW_SETS = 2

        /**
         * What the screen shows after `shown` when the newest content is `fresh`, and how many new sets that spent
         * (0 or 1). A refresh is always taken; a new set only while `newSetsLeft` allows; otherwise the shown rows
         * stay with updated distances.
         */
        fun next(shown: NearbyContent, fresh: NearbyContent, data: CarData, newSetsLeft: Int): Pair<NearbyContent, Int> =
            when {
                shown.isRefreshedBy(fresh) -> fresh to 0
                newSetsLeft >= 0 -> fresh to 1
                else -> shown.withDistancesFrom(data.position(), data.store()) to 0
            }
    }
}

class SourcesScreen(carContext: CarContext, private val content: NearbyContent) : Screen(carContext) {
    override fun onGetTemplate(): Template =
        CarTemplates.sources(content, carContext.resources.configuration.locales[0])
}
