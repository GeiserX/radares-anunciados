// SPDX-License-Identifier: GPL-3.0-or-later
//
// events.jsonl through the core's EventLog (SPEC 9): one JSON object per line, rotated at 2,000 lines, exportable,
// wipeable. Android wake-ups use the iOS row names: a system-held wake condition (the parked fence, an activity
// transition) is source "monitor" with the Android cause in `flags` ("geofence", "in_vehicle", ...). Failures that
// have no row of their own (a refused foreground start) are `monitorEvent` rows with identifier "android".

package io.github.geiserx.radares.health

import android.util.Log
import io.github.geiserx.radares.core.engine.AlertEvent
import io.github.geiserx.radares.core.engine.Level
import io.github.geiserx.radares.core.health.DriveReason
import io.github.geiserx.radares.core.health.EventLog
import io.github.geiserx.radares.core.health.LaunchContext
import io.github.geiserx.radares.core.health.LogEntry
import io.github.geiserx.radares.core.health.LogEvent
import io.github.geiserx.radares.core.health.ProbeResult
import io.github.geiserx.radares.core.health.SinkOutcome
import io.github.geiserx.radares.core.health.StretchExitReason
import io.github.geiserx.radares.core.health.WakeSource
import io.github.geiserx.radares.core.model.Coordinate
import io.github.geiserx.radares.core.model.Fix
import io.github.geiserx.radares.drive.Wake
import java.io.File

class AppLog(file: File, private val inFront: () -> Boolean = { false }) : AppEvents {
    private val log = EventLog(file)

    @Synchronized
    fun post(event: LogEvent) {
        log.append(event)
        Log.i(TAG, event.toJson().toString())
    }

    @Synchronized
    fun recent(n: Int): List<LogEntry> = log.recent(n)

    @Synchronized
    fun export(): ByteArray? = log.export()

    @Synchronized
    fun wipe() = log.wipe()

    override fun note(text: String) = post(LogEvent.MonitorEvent(identifier = "android", state = text.take(300), flags = emptyList()))

    override fun wakeup(wake: Wake) = post(LogEvent.Wakeup(WakeSource.MONITOR, listOf(wake.wire)))

    override fun probe(result: String, maxSpeedMps: Double, seconds: Double) {
        val r = when (result) {
            "driving" -> ProbeResult.DRIVING
            "timeout" -> ProbeResult.TIMEOUT
            else -> ProbeResult.IDLE
        }
        post(LogEvent.Probe(r, motion = null, maxSpeedMps = maxSpeedMps, seconds = seconds))
        if (result != r.raw) note("probe $result")
    }

    override fun driveStarted(wake: Wake) = post(
        LogEvent.DriveStarted(if (wake == Wake.SelfTest) DriveReason.Test else DriveReason.Wakeup(WakeSource.MONITOR)),
    )

    override fun fix(fix: Fix) = post(LogEvent.FixRow(fix.speed, fix.horizontalAccuracy, fix.isStationary))

    override fun alert(event: AlertEvent, level: Level, fix: Fix?, sinks: List<AppEvents.Sink>, spoken: String?) {
        val radar = event.radar
        post(
            LogEvent.Alert(
                id = radar?.id ?: "",
                level = level,
                distance = event.distance ?: (event.content.distanceMetres ?: 0).toDouble(),
                speedMps = fix?.speed ?: event.content.speedKmh?.let { it / 3.6 },
                late = event.late,
                crossTrackMetres = event.crossTrackMetres,
                suppressedByDirection = level == Level.VISUAL && event.content.opposite,
                coordinate = fix?.coordinate ?: radar?.start ?: Coordinate(0.0, 0.0),
                sinks = sinks.map {
                    SinkOutcome(if (it.sink == "speech") SinkOutcome.Sink.SPEECH else SinkOutcome.Sink.NOTIFICATION, it.ok, it.detail)
                },
                spoken = spoken,
            ),
        )
    }

    override fun passed(id: String) = post(LogEvent.Passed(id))
    override fun stretchEntered(id: String) = post(LogEvent.StretchEntered(id))
    override fun stretchExited(id: String, reason: StretchExitReason) = post(LogEvent.StretchExited(id, reason))
    override fun drivePaused() = post(LogEvent.DrivePaused)
    override fun driveResumed(pausedSeconds: Double) = post(LogEvent.DriveResumed(pausedSeconds))

    override fun driveEnded(
        fixes: Int, maxGapSeconds: Double, alerts: Int,
        firstFixAfterWakeS: Double?, firstWarnAfterWakeM: Double?, hadLateAlert: Boolean, why: String,
    ) {
        post(LogEvent.DriveEnded(fixes, maxGapSeconds, alerts, firstFixAfterWakeS, firstWarnAfterWakeM))
        note("drive ended: $why")
    }

    override fun speech(sentence: String, error: String?) = post(
        LogEvent.Speech(route = "tts", setActiveError = error, finished = false,
            launchContext = if (inFront()) LaunchContext.FOREGROUND else LaunchContext.BACKGROUND),
    )

    override fun notificationPosted(tag: String, error: String?) = post(LogEvent.NotificationPosted(tag, error))
    override fun feedChecked(etag: String?, notModified: Boolean) = post(LogEvent.FeedChecked(etag, notModified))
    override fun feedUpdated(count: Int, etag: String?) = post(LogEvent.FeedUpdated(count, etag))
    override fun feedFailed(error: String) = post(LogEvent.FeedFailed(error))
    override fun bgTaskRan(expired: Boolean) = post(LogEvent.BgTaskRan(expired))

    private companion object {
        const val TAG = "Radares"
    }
}
