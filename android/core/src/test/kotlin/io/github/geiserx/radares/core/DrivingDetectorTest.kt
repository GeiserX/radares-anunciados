// SPDX-License-Identifier: GPL-3.0-or-later
// Port of DrivingDetectorTests.swift.

package io.github.geiserx.radares.core

import io.github.geiserx.radares.core.engine.DriveSignal
import io.github.geiserx.radares.core.engine.DrivingDetector
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class DrivingDetectorTest {
    private val p = at(41.3, -1.9)
    private fun fix(seconds: Double, speed: Double?, stationary: Boolean = false) = makeFix(p, t0.plusSeconds(seconds), speed = speed, course = 0.0, stationary = stationary)

    @Test
    fun threeFastFixesStartADrive() {
        val d = DrivingDetector()
        assertEquals(DriveSignal.NONE, d.ingest(fix(0.0, 7.0)))
        assertEquals(DriveSignal.NONE, d.ingest(fix(1.0, 2.0)), "a slow fix does not count")
        assertEquals(DriveSignal.NONE, d.ingest(fix(2.0, 7.0)))
        assertEquals(DriveSignal.STARTED, d.ingest(fix(3.0, 6.0)))
        assertEquals(DrivingDetector.Phase.Driving, d.phase)
        assertEquals(DriveSignal.NONE, d.ingest(fix(4.0, 30.0)))
    }

    @Test
    fun stationaryResetsTheCountAndPausesADrive() {
        val d = DrivingDetector()
        d.ingest(fix(0.0, 7.0))
        d.ingest(fix(1.0, 7.0))
        assertEquals(DriveSignal.NONE, d.ingest(fix(2.0, 0.0, stationary = true)))
        assertEquals(DriveSignal.NONE, d.ingest(fix(3.0, 7.0)), "the count restarted")
        d.ingest(fix(4.0, 7.0))
        assertEquals(DriveSignal.STARTED, d.ingest(fix(5.0, 7.0)))
        assertEquals(DriveSignal.PAUSED, d.ingest(fix(6.0, 0.0, stationary = true)))
        assertEquals(DrivingDetector.Phase.Paused(t0.plusSeconds(6.0)), d.phase)
    }

    @Test
    fun twoMinutesUnderOneMetrePerSecondPauses() {
        val d = DrivingDetector()
        for (s in 0 until 3) d.ingest(fix(s.toDouble(), 10.0))
        for (s in 3 until 122) assertEquals(DriveSignal.NONE, d.ingest(fix(s.toDouble(), 0.5)), "$s")
        assertEquals(DriveSignal.PAUSED, d.ingest(fix(123.0, 0.5)))

        val jam = DrivingDetector()
        for (s in 0 until 3) jam.ingest(fix(s.toDouble(), 10.0))
        for (s in 3 until 100) jam.ingest(fix(s.toDouble(), 0.5))
        assertEquals(DriveSignal.NONE, jam.ingest(fix(100.0, 2.0)), "a creep resets the slow clock")
        for (s in 101 until 220) assertEquals(DriveSignal.NONE, jam.ingest(fix(s.toDouble(), 0.5)), "$s")
    }

    @Test
    fun resumeWithinTenMinutesContinuesTheDrive() {
        val d = DrivingDetector()
        for (s in 0 until 3) d.ingest(fix(s.toDouble(), 10.0))
        assertEquals(DriveSignal.PAUSED, d.ingest(fix(3.0, 0.0, stationary = true)))
        assertEquals(DriveSignal.NONE, d.ingest(fix(200.0, 2.0)), "under 3 m/s is not a resume")
        assertEquals(DriveSignal.RESUMED, d.ingest(fix(9 * 60.0, 4.0)))
        assertEquals(DrivingDetector.Phase.Driving, d.phase)
    }

    @Test
    fun resumeAfterTenMinutesEndsTheDrive() {
        val d = DrivingDetector()
        for (s in 0 until 3) d.ingest(fix(s.toDouble(), 10.0))
        d.ingest(fix(3.0, 0.0, stationary = true))
        assertEquals(DriveSignal.ENDED, d.ingest(fix(11 * 60.0, 8.0)))
        assertEquals(DrivingDetector.Phase.Idle, d.phase)
        assertEquals(DriveSignal.NONE, d.ingest(fix(11 * 60 + 1.0, 8.0)))
        assertEquals(DriveSignal.STARTED, d.ingest(fix(11 * 60 + 2.0, 8.0)), "the fast fix that ended the pause counts toward the re-probe")
    }
}
