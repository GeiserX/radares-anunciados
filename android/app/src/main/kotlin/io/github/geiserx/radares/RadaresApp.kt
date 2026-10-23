// SPDX-License-Identifier: GPL-3.0-or-later
//
// Process start: the three channels, the bundled snapshot on first launch, the periodic feed job, the wake-ups.

package io.github.geiserx.radares

import android.app.Application
import android.content.Context
import io.github.geiserx.radares.drive.WakeUps
import io.github.geiserx.radares.feed.FeedRefreshWorker
import io.github.geiserx.radares.surfaces.Notifier
import java.util.concurrent.Executors

class RadaresApp : Application() {
    lateinit var graph: AppGraph
        private set

    override fun onCreate() {
        super.onCreate()
        graph = AppGraph(this)
        Notifier.createChannels(this)
        // Off the main thread: the snapshot is 3 MB to copy and decode.
        Executors.newSingleThreadExecutor().execute {
            graph.installSnapshotIfNeeded()
            graph.feed.loadIfNeeded()
        }
        FeedRefreshWorker.schedule(this)
        WakeUps.register(this)
    }

    companion object {
        fun graph(context: Context): AppGraph = (context.applicationContext as RadaresApp).graph
    }
}
