// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reads the system and the log into HealthInputs for the twelve Estado rows. Call off the main thread: it asks
// WorkManager and reads the log.

package io.github.geiserx.radares.health

import android.Manifest
import android.app.ActivityManager
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.WorkInfo
import androidx.work.WorkManager
import io.github.geiserx.radares.AppGraph
import io.github.geiserx.radares.core.health.LogEvent
import io.github.geiserx.radares.drive.WakeUps
import io.github.geiserx.radares.feed.FeedRefreshWorker
import io.github.geiserx.radares.surfaces.Notifier
import java.time.Instant

class HealthCollector(private val context: Context, private val graph: AppGraph) {

    fun collect(now: Instant = Instant.now()): HealthInputs {
        val meta = graph.feed.meta()
        val wake = WakeUps.prefs(context)
        val (gap, late) = lastDrive()
        return HealthInputs(
            now = now,
            fineLocation = granted(Manifest.permission.ACCESS_FINE_LOCATION),
            coarseLocation = granted(Manifest.permission.ACCESS_COARSE_LOCATION),
            backgroundLocation = granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
            activityRecognition = granted(Manifest.permission.ACTIVITY_RECOGNITION),
            notificationsEnabled = NotificationManagerCompat.from(context).areNotificationsEnabled(),
            radarChannelImportance = context.getSystemService(NotificationManager::class.java)
                .getNotificationChannel(Notifier.CHANNEL_RADARES)?.importance,
            fenceResult = wake.getString(WakeUps.KEY_FENCE_RESULT, null),
            transitionsResult = wake.getString(WakeUps.KEY_TRANSITIONS_RESULT, null),
            feedFetchedAt = meta.fetchedAt,
            feedFeatureCount = meta.featureCount,
            feedConsecutiveFailures = meta.consecutiveFailures,
            refreshScheduled = refreshScheduled(),
            lastRefreshRun = graph.prefs.getLong(AppGraph.KEY_LAST_REFRESH_RUN, 0).takeIf { it > 0 }?.let(Instant::ofEpochMilli),
            backgroundRestricted = context.getSystemService(ActivityManager::class.java).isBackgroundRestricted,
            voiceReady = graph.speaker.voiceReady,
            voiceError = graph.speaker.lastError,
            carHostConnected = graph.carHostConnected.value,
            filesWritable = graph.files.verifyWritable(),
            lastDriveMaxGapSeconds = gap,
            lastDriveHadLateAlert = late,
        )
    }

    private fun granted(permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private fun refreshScheduled(): Boolean = runCatching {
        WorkManager.getInstance(context).getWorkInfosForUniqueWork(FeedRefreshWorker.NAME).get()
            .any { it.state == WorkInfo.State.ENQUEUED || it.state == WorkInfo.State.RUNNING }
    }.getOrDefault(false)

    /** The last drive's max gap, and whether one of its alerts was late, from the log. */
    private fun lastDrive(): Pair<Double?, Boolean> {
        val entries = graph.log.recent(2000)
        val endIndex = entries.indexOfLast { it.event is LogEvent.DriveEnded }
        if (endIndex < 0) return null to false
        val startIndex = entries.subList(0, endIndex).indexOfLast { it.event is LogEvent.DriveStarted }
        val late = entries.subList(startIndex + 1, endIndex).any { (it.event as? LogEvent.Alert)?.late == true }
        return (entries[endIndex].event as LogEvent.DriveEnded).maxGapSeconds to late
    }
}
