// SPDX-License-Identifier: GPL-3.0-or-later

package io.github.geiserx.radares

import io.github.geiserx.radares.core.engine.AlertEvent
import io.github.geiserx.radares.core.engine.Level
import io.github.geiserx.radares.core.model.Fix
import io.github.geiserx.radares.drive.Wake
import io.github.geiserx.radares.health.AppEvents
import io.github.geiserx.radares.surfaces.NotificationText
import io.github.geiserx.radares.surfaces.SpeechSink
import io.github.geiserx.radares.surfaces.WarningPoster

class FakeSpeaker(var failWith: String? = null) : SpeechSink {
    val spoken = mutableListOf<String>()
    override val voiceReady: Boolean = true
    override fun speak(text: String): String? {
        if (failWith == null) spoken += text
        return failWith
    }
}

class FakePoster : WarningPoster {
    data class Posted(val text: NotificationText, val tag: String, val silent: Boolean)

    val posted = mutableListOf<Posted>()
    val removed = mutableListOf<String>()
    override fun post(text: NotificationText, tag: String, silent: Boolean): String? {
        posted += Posted(text, tag, silent)
        return null
    }

    override fun removeRadar(radarId: String) {
        removed += radarId
    }
}

/** Records every row by name. */
class RecordingEvents : AppEvents {
    val rows = mutableListOf<String>()
    val alerts = mutableListOf<Triple<Level, List<AppEvents.Sink>, String?>>()
    override fun wakeup(wake: Wake) { rows += "wakeup:${wake.wire}" }
    override fun probe(result: String, maxSpeedMps: Double, seconds: Double) { rows += "probe:$result" }
    override fun driveStarted(wake: Wake) { rows += "driveStarted" }
    override fun note(text: String) { rows += "note:$text" }
    override fun alert(event: AlertEvent, level: Level, fix: Fix?, sinks: List<AppEvents.Sink>, spoken: String?) {
        rows += "alert"
        alerts += Triple(level, sinks, spoken)
    }
    override fun drivePaused() { rows += "drivePaused" }
    override fun driveResumed(pausedSeconds: Double) { rows += "driveResumed" }
    override fun driveEnded(
        fixes: Int, maxGapSeconds: Double, alerts: Int,
        firstFixAfterWakeS: Double?, firstWarnAfterWakeM: Double?, hadLateAlert: Boolean, why: String,
    ) { rows += "driveEnded:$why" }
}
