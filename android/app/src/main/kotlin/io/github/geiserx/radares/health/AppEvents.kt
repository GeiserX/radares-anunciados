// SPDX-License-Identifier: GPL-3.0-or-later
//
// The rows the app writes to the event log (SPEC 9), as typed calls. AppLog turns each into the core's LogEvent
// and appends it to events.jsonl; the tests use a recorder.

package io.github.geiserx.radares.health

import io.github.geiserx.radares.core.engine.AlertEvent
import io.github.geiserx.radares.core.engine.Level
import io.github.geiserx.radares.core.health.StretchExitReason
import io.github.geiserx.radares.core.model.Fix
import io.github.geiserx.radares.drive.Wake

interface AppEvents {
    data class Sink(val sink: String, val ok: Boolean, val detail: String?)

    fun wakeup(wake: Wake) {}
    fun probe(result: String, maxSpeedMps: Double, seconds: Double) {}
    fun driveStarted(wake: Wake) {}
    fun fix(fix: Fix) {}
    fun alert(event: AlertEvent, level: Level, fix: Fix?, sinks: List<Sink>, spoken: String?) {}
    fun passed(id: String) {}
    fun stretchEntered(id: String) {}
    fun stretchExited(id: String, reason: StretchExitReason) {}
    fun drivePaused() {}
    fun driveResumed(pausedSeconds: Double) {}
    fun driveEnded(
        fixes: Int, maxGapSeconds: Double, alerts: Int,
        firstFixAfterWakeS: Double?, firstWarnAfterWakeM: Double?, hadLateAlert: Boolean, why: String,
    ) {}
    fun speech(sentence: String, error: String?) {}
    fun notificationPosted(tag: String, error: String?) {}
    fun feedChecked(etag: String?, notModified: Boolean) {}
    fun feedUpdated(count: Int, etag: String?) {}
    fun feedFailed(error: String) {}
    fun bgTaskRan(expired: Boolean) {}
    /** A free-text Android row (a refused service start, a drive resumed after a process restart). */
    fun note(text: String) {}
}
