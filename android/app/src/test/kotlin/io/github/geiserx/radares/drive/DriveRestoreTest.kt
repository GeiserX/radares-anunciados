// SPDX-License-Identifier: GPL-3.0-or-later
//
// A process killed mid-drive (SPEC 4, 5): the restarted service continues the same drive from its record, keeps the
// stretch it was inside so "Fin de tramo" is still said at the far gate, and writes no second driveStarted row.

package io.github.geiserx.radares.drive

import io.github.geiserx.radares.FakePoster
import io.github.geiserx.radares.FakeSpeaker
import io.github.geiserx.radares.Fixtures
import io.github.geiserx.radares.RecordingEvents
import io.github.geiserx.radares.core.engine.AlertEngine
import io.github.geiserx.radares.core.engine.PassLedger
import io.github.geiserx.radares.surfaces.AlertDispatcher
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.time.Instant

class DriveRestoreTest {

    private class MemoryRecords : DriveRecordStore {
        var record: DriveRecord? = null
        override fun load() = record
        override fun save(record: DriveRecord) { this.record = record }
        override fun clear() { record = null }
    }

    /** What survives the process: passes.json, the drive record, the log. Everything else is rebuilt. */
    private val records = MemoryRecords()
    private var ledger = PassLedger()
    private val speaker = FakeSpeaker()
    private val events = RecordingEvents()
    private var now = Instant.EPOCH
    private val resumingCalls = mutableListOf<Boolean>()

    private fun process(vector: Fixtures.Vector): DriveController {
        var seq = 0
        val dispatcher = AlertDispatcher(speaker, FakePoster(), events, { ++seq }, vector.locale)
        return DriveController(
            clock = { now },
            engineFactory = { resuming ->
                resumingCalls += resuming
                AlertEngine(Fixtures.store, if (resuming) ledger else ledger.copy(stretch = null), locale = vector.locale)
            },
            sink = dispatcher,
            events = events,
            ledgerSaver = { ledger = it },
            armFence = {},
            stopService = {},
            recentInVehicle = { true },
            locale = vector.locale,
            records = records,
        )
    }

    @Test
    fun aKillInsideTheStretchStillSaysFinDeTramo() {
        val vector = Fixtures.vectors().single { it.name == "corridor-n232-from-west" }
        val first = process(vector)
        now = vector.fixes.first().timestamp
        first.onWake(Wake.InVehicle)
        val entered = "Tramo de radar móvil, N-232, 10 kilómetros."
        var i = 0
        while (entered !in speaker.spoken) {
            now = vector.fixes[i].timestamp
            first.onFix(vector.fixes[i++])
        }
        // Thirty more seconds inside the stretch, then the process dies with no endDrive.
        repeat(30) { now = vector.fixes[i].timestamp; first.onFix(vector.fixes[i++]) }
        assertNotNull(ledger.stretch, "the ledger written at stretch entry carries the stretch")
        assertNotNull(records.record, "the drive record is on disk")

        val second = process(vector)
        now = now.plusSeconds(20)
        assertTrue(second.restore(), "a fresh record resumes the drive")
        assertEquals(DriveController.State.Driving, second.state)
        assertEquals(listOf(false, true), resumingCalls, "the restored engine is built with the stretch")
        second.onWake(Wake.Fence) // the START_STICKY restart's wake: no probe, the drive is on
        while (i < vector.fixes.size) {
            now = vector.fixes[i].timestamp
            second.onFix(vector.fixes[i++])
        }
        assertEquals(vector.expected.mapNotNull { it.spoken }, speaker.spoken)
        assertEquals(1, events.rows.count { it == "driveStarted" }, events.rows.toString())
        assertFalse(events.rows.any { it.startsWith("probe:") && it != "probe:driving" }, events.rows.toString())
    }

    @Test
    fun aStaleRecordIsNoDriveAndTheRestartProbes() {
        val vector = Fixtures.vectors().single { it.name == "a2-120kmh-ne" }
        val first = process(vector)
        now = vector.fixes.first().timestamp
        first.onWake(Wake.InVehicle)
        assertNotNull(records.record)
        val second = process(vector)
        now = now.plusSeconds(11 * 60)
        assertFalse(second.restore())
        assertNull(records.record, "the stale record is cleared")
        assertEquals(DriveController.State.Idle, second.state)
    }

    @Test
    fun aDriveEndClearsTheRecord() {
        val vector = Fixtures.vectors().single { it.name == "a2-120kmh-ne" }
        val first = process(vector)
        now = vector.fixes.first().timestamp
        first.onWake(Wake.InVehicle)
        assertNotNull(records.record)
        first.onWake(Wake.OnFoot)
        assertNull(records.record)
        assertFalse(process(vector).restore())
    }
}
