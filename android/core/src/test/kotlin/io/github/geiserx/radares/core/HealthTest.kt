// SPDX-License-Identifier: GPL-3.0-or-later
// The event log (port of EventLogTests.swift's rules: JSONL, sorted keys, rotation, wipe, never throwing) and the
// two platform-neutral health rules, each with a positive and a negative case.

package io.github.geiserx.radares.core

import io.github.geiserx.radares.core.engine.Level
import io.github.geiserx.radares.core.health.DriveReason
import io.github.geiserx.radares.core.health.EventLog
import io.github.geiserx.radares.core.health.HealthItem
import io.github.geiserx.radares.core.health.HealthRules
import io.github.geiserx.radares.core.health.LaunchReason
import io.github.geiserx.radares.core.health.LaunchState
import io.github.geiserx.radares.core.health.LogEntry
import io.github.geiserx.radares.core.health.LogEvent
import io.github.geiserx.radares.core.health.SinkOutcome
import io.github.geiserx.radares.core.health.StretchExitReason
import io.github.geiserx.radares.core.health.WakeSource
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

class HealthTest {
    @Test
    fun aLineIsSwiftsCodableShapeWithSortedKeys() {
        val line = EventLog.encode(LogEntry(t0, LogEvent.DriveStarted(DriveReason.Wakeup(WakeSource.MONITOR))))
        assertEquals("""{"event":{"driveStarted":{"reason":{"wakeup":{"_0":"monitor"}}}},"t":"2026-10-07T10:00:00Z"}""", line)
        assertEquals("""{"event":{"sessionTaken":{}},"t":"2026-10-07T10:00:00Z"}""", EventLog.encode(LogEntry(t0, LogEvent.SessionTaken)))
        val alert = EventLog.encode(LogEntry(t0, LogEvent.Alert("r", Level.FULL, 833.0, 33.3, false, null, false, at(41.0, -1.5), listOf(SinkOutcome(SinkOutcome.Sink.SPEECH, true)), "Radar fijo a 850 metros.")))
        assertEquals(
            """{"event":{"alert":{"coordinate":{"latitude":41,"longitude":-1.5},"distance":833,"id":"r","late":false,"level":"full","sinks":[{"ok":true,"sink":"speech"}],"speedMps":33.3,"spoken":"Radar fijo a 850 metros.","suppressedByDirection":false}},"t":"2026-10-07T10:00:00Z"}""",
            alert,
        )
    }

    @Test
    fun everyEventRoundTrips() {
        val events = listOf(
            LogEvent.Launch(LaunchReason.MONITOR_EVENT, LaunchState.BACKGROUND),
            LogEvent.SessionTaken,
            LogEvent.Wakeup(WakeSource.SLC, listOf("a", "b")),
            LogEvent.Probe(io.github.geiserx.radares.core.health.ProbeResult.DRIVING, true, 12.5, 8.0),
            LogEvent.DriveStarted(DriveReason.Foreground),
            LogEvent.DriveStarted(DriveReason.Test),
            LogEvent.FixRow(null, 5.0, false),
            LogEvent.Alert("r", Level.VISUAL, 120.5, null, true, -3.2, true, at(41.0, -1.5), emptyList()),
            LogEvent.Passed("r"),
            LogEvent.StretchEntered("s"),
            LogEvent.StretchExited("s", StretchExitReason.TIME),
            LogEvent.DrivePaused,
            LogEvent.DriveResumed(90.0),
            LogEvent.DriveEnded(600, 2.5, 3, 12.0, null),
            LogEvent.FeedChecked("e", true),
            LogEvent.FeedUpdated(4450, null),
            LogEvent.FeedFailed("timeout"),
            LogEvent.BgTaskRan(false),
            LogEvent.NotificationPosted("r#1", null),
            LogEvent.Speech("car", null, true, io.github.geiserx.radares.core.health.LaunchContext.BACKGROUND),
            LogEvent.MonitorEvent("radares.wake", "unsatisfied", emptyList()),
            LogEvent.ProtectionVerified(true),
            LogEvent.WillTerminate,
        )
        for (e in events) assertEquals(LogEntry(t0, e), EventLog.decode(EventLog.encode(LogEntry(t0, e))), "$e")
        assertNull(EventLog.decode("""{"event":{"somethingNew":{}},"t":"2026-10-07T10:00:00Z"}"""), "an unknown row is skipped")
    }

    @Test
    fun theLogRotatesAtTheLimitKeepingTheNewestHalf(@TempDir dir: File) {
        val log = EventLog(File(dir, "logs/events.jsonl"))
        for (i in 0 until Thresholds.logMaxLines) log.append(LogEvent.Passed("r$i"), t0)
        assertEquals(Thresholds.logMaxLines, log.count)
        log.append(LogEvent.Passed("last"), t0)
        assertEquals(Thresholds.logMaxLines / 2 + 1, log.count)
        assertEquals(Thresholds.logMaxLines / 2 + 1, File(dir, "logs/events.jsonl").readLines().size)
        val recent = log.recent(2).map { it.event }
        assertEquals(listOf(LogEvent.Passed("r${Thresholds.logMaxLines - 1}"), LogEvent.Passed("last")), recent)
        assertTrue(log.export()!!.isNotEmpty())
        log.wipe()
        assertEquals(0, log.count)
        assertEquals(emptyList<LogEntry>(), log.recent(5))
    }

    @Test
    fun writesNeverThrow(@TempDir dir: File) {
        val blocker = File(dir, "file")
        blocker.writeText("x")
        val log = EventLog(File(blocker, "events.jsonl"))
        log.append(LogEvent.DrivePaused)
        assertEquals(emptyList<LogEntry>(), log.recent(1))
    }

    @Test
    fun feedRule() {
        val now = t0
        assertEquals(HealthItem.Status.FAIL, HealthRules.feed(null, 0, 0, now).status)
        assertEquals(HealthItem.Status.OK, HealthRules.feed(now.plusSeconds(-3600.0), 4450, 0, now).status)
        assertEquals(HealthItem.Status.WARN, HealthRules.feed(now.plusSeconds(-3 * 86_400.0), 4450, 0, now).status)
        assertEquals(HealthItem.Status.FAIL, HealthRules.feed(now.plusSeconds(-8 * 86_400.0), 4450, 0, now).status)
        assertEquals(HealthItem.Status.FAIL, HealthRules.feed(now.plusSeconds(-3600.0), 1500, 0, now).status)
        assertEquals(HealthItem.Status.FAIL, HealthRules.feed(now.plusSeconds(-3600.0), 4450, 3, now).status)
        assertEquals("Datos de hace 3 días", HealthRules.feed(now.plusSeconds(-3 * 86_400.0), 4450, 0, now).detail)
        assertEquals("4450 radares, hace 5 h", HealthRules.feed(now.plusSeconds(-5 * 3600.0), 4450, 0, now).detail)
    }

    @Test
    fun lastDriveRule() {
        assertEquals(HealthItem.Status.OK, HealthRules.lastDrive(null, false).status)
        assertEquals(HealthItem.Status.OK, HealthRules.lastDrive(2.0, false).status)
        assertEquals(HealthItem.Status.WARN, HealthRules.lastDrive(15.0, false).status)
        assertEquals(HealthItem.Status.WARN, HealthRules.lastDrive(2.0, true).status)
        assertEquals("Último viaje", HealthRules.lastDrive(2.0, false).title)
    }
}
