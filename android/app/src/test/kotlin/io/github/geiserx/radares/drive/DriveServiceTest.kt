// SPDX-License-Identifier: GPL-3.0-or-later
//
// The drive service's rules, through the DriveController it hosts: the probe, the motion start, walking, the
// pause timer, and the parked fence re-armed at every way out.

package io.github.geiserx.radares.drive

import io.github.geiserx.radares.Fixtures
import io.github.geiserx.radares.RecordingEvents
import io.github.geiserx.radares.core.engine.AlertEngine
import io.github.geiserx.radares.core.engine.PassLedger
import io.github.geiserx.radares.core.model.Coordinate
import io.github.geiserx.radares.core.model.Fix
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.time.Instant

class DriveServiceTest {
    private var now = Instant.parse("2026-10-07T08:00:00Z")
    private val events = RecordingEvents()
    private val fences = mutableListOf<Coordinate>()
    private var stops = 0
    private var ledgerWrites = 0
    private var inVehicle = false

    private val controller = DriveController(
        clock = { now },
        engineFactory = { AlertEngine(Fixtures.store, PassLedger()) },
        sink = { _, _ -> },
        events = events,
        ledgerSaver = { ledgerWrites++ },
        armFence = { fences += it },
        stopService = { stops++ },
        recentInVehicle = { inVehicle },
    )

    private val start = Coordinate(41.0, -3.0)

    private fun fix(i: Int, speed: Double, stationary: Boolean = false) = Fix(
        coordinate = Coordinate(start.latitude + i * 0.0001, start.longitude),
        timestamp = now, speed = speed, course = 0.0, horizontalAccuracy = 5.0, isStationary = stationary,
    )

    private fun second(i: Int, speed: Double, stationary: Boolean = false) {
        now = now.plusSeconds(1)
        controller.onFix(fix(i, speed, stationary))
        controller.onTick()
    }

    @Test
    fun aFenceWakeWithoutDrivingTimesOutReArmsTheFenceAndStops() {
        controller.onWake(Wake.Fence)
        assertTrue(controller.state is DriveController.State.Probing)
        var last = 0
        while (controller.state != DriveController.State.Idle && last < 120) second(++last, speed = 1.0)
        assertEquals(60, last, "the probe lasts Thresholds.probeSeconds")
        assertTrue("probe:timeout" in events.rows, events.rows.toString())
        assertEquals(1, stops)
        assertEquals(fix(last, 1.0).coordinate, fences.single(), "the fence is re-armed where the phone is")
    }

    @Test
    fun theProbeStartsADriveAfterThreeFastFixes() {
        controller.onWake(Wake.Fence)
        second(1, 7.0)
        second(2, 7.0)
        assertTrue(controller.state is DriveController.State.Probing)
        second(3, 7.0)
        assertEquals(DriveController.State.Driving, controller.state)
        assertTrue("probe:driving" in events.rows)
        assertEquals(0, stops)
    }

    @Test
    fun anInVehicleTransitionStartsTheDriveAtOnce() {
        controller.onWake(Wake.InVehicle)
        assertEquals(DriveController.State.Driving, controller.state)
        assertEquals(listOf("wakeup:in_vehicle", "probe:driving", "driveStarted"), events.rows)
    }

    @Test
    fun aFenceWakeAfterARecentInVehicleTransitionStartsAtOnce() {
        inVehicle = true
        controller.onWake(Wake.Fence)
        assertEquals(DriveController.State.Driving, controller.state)
    }

    @Test
    fun walkingEndsTheDriveAndReArmsTheFenceAtTheLastFix() {
        controller.onWake(Wake.InVehicle)
        for (i in 1..20) second(i, 15.0)
        controller.onWake(Wake.OnFoot)
        assertEquals(DriveController.State.Idle, controller.state)
        assertTrue("driveEnded:on_foot" in events.rows, events.rows.toString())
        assertEquals(fix(20, 15.0).coordinate, fences.single())
        assertEquals(1, stops)
        assertTrue(ledgerWrites >= 1, "the ledger is written at drive end")
    }

    @Test
    fun walkingWhileProbingIsNoDrive() {
        controller.onWake(Wake.Fence)
        second(1, 1.0)
        controller.onWake(Wake.OnFoot)
        assertEquals(DriveController.State.Idle, controller.state)
        assertTrue("probe:idle" in events.rows)
        assertEquals(1, stops)
    }

    @Test
    fun aPauseOverTenMinutesEndsTheDrive() {
        controller.onWake(Wake.InVehicle)
        for (i in 1..5) second(i, 15.0)
        second(6, 0.0, stationary = true)
        // The detector counts its own three fast fixes before its pause rules apply; the stationary flag pauses.
        assertTrue(controller.state is DriveController.State.Paused, controller.state.toString())
        for (i in 7..(7 + 10 * 60)) second(6, 0.0, stationary = true)
        assertEquals(DriveController.State.Idle, controller.state)
        assertTrue("driveEnded:pause_over" in events.rows, events.rows.toString())
        assertEquals(1, fences.size)
    }

    @Test
    fun aResumeWithinTenMinutesContinuesTheSameDrive() {
        controller.onWake(Wake.InVehicle)
        for (i in 1..5) second(i, 15.0)
        for (i in 0..60) second(6, 0.0, stationary = true)
        second(7, 10.0)
        assertEquals(DriveController.State.Driving, controller.state)
        assertTrue("driveResumed" in events.rows)
        assertEquals(0, stops)
    }
}
