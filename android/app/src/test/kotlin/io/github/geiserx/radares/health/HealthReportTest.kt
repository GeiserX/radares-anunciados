// SPDX-License-Identifier: GPL-3.0-or-later
//
// One positive and one negative case per Estado row.

package io.github.geiserx.radares.health

import android.app.NotificationManager
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.time.Duration
import java.time.Instant

class HealthReportTest {
    private val now = Instant.parse("2026-10-23T10:00:00Z")

    /** Every row green. */
    private val healthy = HealthInputs(
        now = now, fineLocation = true, coarseLocation = true, backgroundLocation = true, activityRecognition = true,
        notificationsEnabled = true, radarChannelImportance = NotificationManager.IMPORTANCE_HIGH,
        fenceResult = "ok", transitionsResult = "ok",
        feedFetchedAt = now.minus(Duration.ofHours(3)), feedFeatureCount = 4500, feedConsecutiveFailures = 0,
        refreshScheduled = true, lastRefreshRun = now.minus(Duration.ofHours(5)), backgroundRestricted = false,
        voiceReady = true, carHostConnected = false, filesWritable = true,
        lastDriveMaxGapSeconds = 2.0, lastDriveHadLateAlert = false,
    )

    private fun row(i: HealthInputs, id: String) = healthReport(i).single { it.id == id }

    private fun assertStatus(expected: HealthStatus, i: HealthInputs, id: String) =
        assertEquals(expected, row(i, id).status, row(i, id).toString())

    @Test
    fun twelveRowsAllGreenWhenEverythingIsFine() {
        val rows = healthReport(healthy)
        assertEquals(12, rows.size)
        assertTrue(rows.all { it.status == HealthStatus.OK }, rows.filter { it.status != HealthStatus.OK }.toString())
        assertEquals(12, rows.map { it.id }.toSet().size)
    }

    @Test fun precise() {
        assertStatus(HealthStatus.OK, healthy, HealthIds.PRECISE)
        assertStatus(HealthStatus.RED, healthy.copy(fineLocation = false), HealthIds.PRECISE)
        assertStatus(HealthStatus.RED, healthy.copy(fineLocation = false, coarseLocation = false), HealthIds.PRECISE)
    }

    @Test fun always() {
        assertStatus(HealthStatus.OK, healthy, HealthIds.ALWAYS)
        assertStatus(HealthStatus.RED, healthy.copy(backgroundLocation = false), HealthIds.ALWAYS)
    }

    @Test fun activity() {
        assertStatus(HealthStatus.OK, healthy, HealthIds.ACTIVITY)
        assertStatus(HealthStatus.AMBER, healthy.copy(activityRecognition = false), HealthIds.ACTIVITY)
    }

    @Test fun notifications() {
        assertStatus(HealthStatus.OK, healthy, HealthIds.NOTIFICATIONS)
        assertStatus(HealthStatus.RED, healthy.copy(notificationsEnabled = false), HealthIds.NOTIFICATIONS)
        assertStatus(HealthStatus.AMBER, healthy.copy(radarChannelImportance = NotificationManager.IMPORTANCE_DEFAULT), HealthIds.NOTIFICATIONS)
    }

    @Test fun fence() {
        assertStatus(HealthStatus.OK, healthy, HealthIds.FENCE)
        assertStatus(HealthStatus.RED, healthy.copy(fenceResult = "1000: GEOFENCE_NOT_AVAILABLE"), HealthIds.FENCE)
        assertStatus(HealthStatus.AMBER, healthy.copy(fenceResult = null), HealthIds.FENCE)
    }

    @Test fun transitions() {
        assertStatus(HealthStatus.OK, healthy, HealthIds.TRANSITIONS)
        assertStatus(HealthStatus.RED, healthy.copy(transitionsResult = "permission denied"), HealthIds.TRANSITIONS)
        assertStatus(HealthStatus.AMBER, healthy.copy(transitionsResult = null), HealthIds.TRANSITIONS)
    }

    @Test fun feed() {
        assertStatus(HealthStatus.OK, healthy, HealthIds.FEED)
        assertStatus(HealthStatus.RED, healthy.copy(feedFetchedAt = null), HealthIds.FEED)
        assertStatus(HealthStatus.AMBER, healthy.copy(feedFetchedAt = now.minus(Duration.ofDays(3))), HealthIds.FEED)
        assertStatus(HealthStatus.RED, healthy.copy(feedFetchedAt = now.minus(Duration.ofDays(8))), HealthIds.FEED)
        assertStatus(HealthStatus.RED, healthy.copy(feedConsecutiveFailures = 3), HealthIds.FEED)
        assertStatus(HealthStatus.RED, healthy.copy(feedFeatureCount = 1999), HealthIds.FEED)
    }

    @Test fun refresh() {
        assertStatus(HealthStatus.OK, healthy, HealthIds.REFRESH)
        assertStatus(HealthStatus.RED, healthy.copy(backgroundRestricted = true), HealthIds.REFRESH)
        assertStatus(HealthStatus.RED, healthy.copy(refreshScheduled = false), HealthIds.REFRESH)
        assertStatus(HealthStatus.AMBER, healthy.copy(lastRefreshRun = now.minus(Duration.ofDays(4))), HealthIds.REFRESH)
    }

    @Test fun voice() {
        assertStatus(HealthStatus.OK, healthy, HealthIds.VOICE)
        assertStatus(HealthStatus.RED, healthy.copy(voiceReady = false, voiceError = "voice missing for es-ES"), HealthIds.VOICE)
        assertStatus(HealthStatus.AMBER, healthy.copy(voiceReady = null), HealthIds.VOICE)
    }

    @Test fun androidAutoIsNeverRed() {
        assertStatus(HealthStatus.OK, healthy, HealthIds.AUTO)
        assertStatus(HealthStatus.OK, healthy.copy(carHostConnected = true), HealthIds.AUTO)
        assertStatus(HealthStatus.AMBER, healthy.copy(carHostConnected = true, radarChannelImportance = NotificationManager.IMPORTANCE_LOW), HealthIds.AUTO)
        assertStatus(HealthStatus.OK, healthy.copy(notificationsEnabled = false), HealthIds.AUTO)
    }

    @Test fun files() {
        assertStatus(HealthStatus.OK, healthy, HealthIds.FILES)
        assertStatus(HealthStatus.RED, healthy.copy(filesWritable = false), HealthIds.FILES)
    }

    @Test fun lastDrive() {
        assertStatus(HealthStatus.OK, healthy, HealthIds.LAST_DRIVE)
        assertStatus(HealthStatus.AMBER, healthy.copy(lastDriveMaxGapSeconds = 30.0), HealthIds.LAST_DRIVE)
        assertStatus(HealthStatus.AMBER, healthy.copy(lastDriveHadLateAlert = true), HealthIds.LAST_DRIVE)
    }

    @Test fun englishTitles() {
        assertEquals("Precise location", healthReport(healthy, english = true).first().title)
        assertEquals("Ubicación precisa", healthReport(healthy).first().title)
    }
}
