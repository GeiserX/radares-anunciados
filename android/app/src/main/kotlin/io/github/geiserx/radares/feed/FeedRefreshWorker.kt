// SPDX-License-Identifier: GPL-3.0-or-later
//
// The periodic feed job (SPEC 1): every 6 h on any network, plus the once-a-day health notice (SPEC 9): when Estado
// is red and the app is not in front, one plain notification on the "estado" channel at most every 24 h.

package io.github.geiserx.radares.feed

import android.app.NotificationManager
import android.content.Context
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.edit
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.github.geiserx.radares.AppGraph
import io.github.geiserx.radares.R
import io.github.geiserx.radares.RadaresApp
import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.feed.FeedRefreshPolicy
import io.github.geiserx.radares.health.HealthCollector
import io.github.geiserx.radares.health.HealthStatus
import io.github.geiserx.radares.health.healthReport
import io.github.geiserx.radares.surfaces.Notifier
import java.util.Locale
import java.util.concurrent.TimeUnit

class FeedRefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val graph = RadaresApp.graph(applicationContext)
        graph.prefs.edit { putLong(AppGraph.KEY_LAST_REFRESH_RUN, System.currentTimeMillis()) }
        graph.installSnapshotIfNeeded()
        graph.feed.loadIfNeeded()
        graph.feed.refreshIfNeeded(FeedRefreshPolicy.Trigger.BACKGROUND)
        graph.log.bgTaskRan(expired = false)
        postHealthNoticeIfRed(applicationContext, graph)
        return Result.success()
    }

    companion object {
        const val NAME = "feed-refresh"

        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<FeedRefreshWorker>(Thresholds.refreshBackgroundHours.toLong(), TimeUnit.HOURS)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }

        fun postHealthNoticeIfRed(context: Context, graph: AppGraph) {
            val inFront = ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
            if (inFront) return
            val last = graph.prefs.getLong(AppGraph.KEY_HEALTH_NOTICE_AT, 0)
            if (System.currentTimeMillis() - last < (Thresholds.healthNoticeHours * 3600_000).toLong()) return
            val english = Locale.getDefault().language == "en"
            val red = healthReport(HealthCollector(context, graph).collect(), english).firstOrNull { it.status == HealthStatus.RED } ?: return
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            val text = context.getString(R.string.health_notice, red.title.lowercase(Locale.getDefault()), red.detail)
            val notification = NotificationCompat.Builder(context, Notifier.CHANNEL_ESTADO)
                .setSmallIcon(R.drawable.ic_stat_radar)
                .setContentTitle(red.title)
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setAutoCancel(true)
                .setContentIntent(
                    android.app.PendingIntent.getActivity(
                        context, 0, android.content.Intent(context, io.github.geiserx.radares.ui.MainActivity::class.java),
                        android.app.PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
                .build()
            context.getSystemService(NotificationManager::class.java).notify(Notifier.HEALTH_ID, notification)
            graph.prefs.edit { putLong(AppGraph.KEY_HEALTH_NOTICE_AT, System.currentTimeMillis()) }
        }
    }
}
