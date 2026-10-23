// SPDX-License-Identifier: GPL-3.0-or-later
// Ports of PassTrackerTests.swift and the relaunch tests of AlertEngineVectorTests.swift: once per pass, the
// 10 min AND 2 km cooldown, the prune at drive end, and a process restart mid-drive and mid-stretch.

package io.github.geiserx.radares.core

import io.github.geiserx.radares.core.engine.AlertEngine
import io.github.geiserx.radares.core.engine.AlertEvent
import io.github.geiserx.radares.core.engine.DrivePhase
import io.github.geiserx.radares.core.engine.DriveSnapshot
import io.github.geiserx.radares.core.engine.Level
import io.github.geiserx.radares.core.engine.PassLedger
import io.github.geiserx.radares.core.engine.PassLedgerFile
import io.github.geiserx.radares.core.engine.PassTracker
import io.github.geiserx.radares.core.health.StretchExitReason
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

class LedgerTest {
    @Test
    fun theStateMachineRoundTrip() {
        val tracker = PassTracker(PassLedger())
        assertEquals(PassTracker.State.Idle, tracker.state("r", t0))
        tracker.arm("r")
        assertEquals(PassTracker.State.Armed, tracker.state("r", t0))
        tracker.disarm("r")
        assertEquals(PassTracker.State.Idle, tracker.state("r", t0))
        tracker.arm("r")
        tracker.fire("r", Level.FULL, t0)
        assertEquals(PassTracker.State.Fired(Level.FULL), tracker.state("r", t0.plusSeconds(5.0)))
        assertFalse(tracker.canFire("r", t0.plusSeconds(5.0)))
        tracker.markPassed("r", t0.plusSeconds(30.0))
        assertEquals(PassTracker.State.Passed, tracker.state("r", t0.plusSeconds(31.0)))
        assertEquals(PassTracker.State.Cooldown, tracker.state("r", t0.plusSeconds(35.0)), "the passed card lasts 4 s")
        assertEquals(emptyList<String>(), tracker.firedIds)
    }

    @Test
    fun cooldownNeedsBothTenMinutesAndTwoKilometres() {
        val tracker = PassTracker(PassLedger())
        tracker.fire("r", Level.FULL, t0)
        tracker.markPassed("r", t0.plusSeconds(20.0))
        tracker.observe("r", 3000.0)
        assertEquals(PassTracker.State.Cooldown, tracker.state("r", t0.plusSeconds(5 * 60.0)), "3 km but only 5 min")
        assertEquals(PassTracker.State.Idle, tracker.state("r", t0.plusSeconds(11 * 60.0)), "11 min and 3 km")
        // Exactly at both limits the pass is over (>= on both).
        assertTrue(PassLedger.Entry("x", t0, farthestMetres = 2000.0).cooldownOver(t0.plusSeconds(600.0)))
        assertFalse(PassLedger.Entry("x", t0, farthestMetres = 1999.0).cooldownOver(t0.plusSeconds(600.0)))
        assertFalse(PassLedger.Entry("x", t0, farthestMetres = 2000.0).cooldownOver(t0.plusSeconds(599.0)))

        val short = PassTracker(PassLedger())
        short.fire("s", Level.FULL, t0)
        short.markPassed("s", t0.plusSeconds(20.0))
        short.observe("s", 1000.0)
        assertEquals(PassTracker.State.Cooldown, short.state("s", t0.plusSeconds(11 * 60.0)), "11 min but only 1 km")
        assertFalse(short.canFire("s", t0.plusSeconds(11 * 60.0)))
    }

    @Test
    fun aFiredRadarNeverPassedStillCoolsDownAndFarthestNeverShrinks() {
        val tracker = PassTracker(PassLedger())
        tracker.fire("r", Level.VISUAL, t0)
        assertEquals(PassTracker.State.Fired(Level.VISUAL), tracker.state("r", t0.plusSeconds(60.0)))
        tracker.observe("r", 2500.0)
        tracker.observe("r", 100.0)
        assertEquals(2500.0, tracker.ledger.entry("r")?.farthestMetres, "farthest never goes down")
        assertEquals(PassTracker.State.Idle, tracker.state("r", t0.plusSeconds(10 * 60.0)))
    }

    @Test
    fun pruneDropsOldEntriesAndCapsTheCount() {
        val ledger = PassLedger()
            .upsert(PassLedger.Entry(id = "old", firedAt = t0.plusSeconds(-25 * 3600.0)))
            .upsert(PassLedger.Entry(id = "fresh", firedAt = t0.plusSeconds(-23 * 3600.0)))
            .prune(t0)
        assertEquals(listOf("fresh"), ledger.entries.map { it.id })

        var big = PassLedger()
        for (i in 0 until 250) big = big.upsert(PassLedger.Entry(id = "r$i", firedAt = t0.plusSeconds(i.toDouble())))
        big = big.prune(t0.plusSeconds(300.0))
        assertEquals(Thresholds.ledgerMaxEntries, big.entries.size)
        assertNull(big.entry("r0"), "the oldest went first")
        assertNotNull(big.entry("r249"))
    }

    @Test
    fun trackerPruneDropsFinishedPasses() {
        val tracker = PassTracker(PassLedger())
        tracker.fire("done", Level.FULL, t0)
        tracker.markPassed("done", t0.plusSeconds(10.0))
        tracker.observe("done", 2500.0)
        tracker.fire("recent", Level.FULL, t0.plusSeconds(500.0))
        tracker.prune(t0.plusSeconds(700.0))
        assertEquals(listOf("recent"), tracker.ledger.entries.map { it.id })
    }

    /// The engine prunes at drive end against its own clock, injected here: 24 h old entries go, fresh ones stay.
    @Test
    fun endDrivePrunesAgainstTheInjectedClock() {
        val ledger = PassLedger()
            .upsert(PassLedger.Entry(id = "yesterday", firedAt = t0.plusSeconds(-25 * 3600.0), passedAt = t0.plusSeconds(-25 * 3600.0 + 30)))
            .upsert(PassLedger.Entry(id = "today", firedAt = t0.plusSeconds(-60.0), passedAt = t0.plusSeconds(-30.0)))
        val engine = AlertEngine(Fixtures.store, ledger, now = { t0 }, locale = Fixtures.es)
        val events = engine.endDrive()
        assertEquals(listOf<AlertEvent.Kind>(AlertEvent.Kind.DriveEnded), events.map { it.kind })
        assertEquals(listOf("today"), engine.ledger.entries.map { it.id })
    }

    @Test
    fun theLedgerFileRoundTripsAndToleratesGarbage(@TempDir dir: File) {
        val corridor = Fixtures.radar("dgt_invive-Tramo_Invive_344")
        val ledger = PassLedger()
            .upsert(PassLedger.Entry(id = "a", firedAt = t0, level = Level.FULL, farthestMetres = 120.0, passedAt = t0.plusSeconds(40.0)))
            .upsert(PassLedger.Entry(id = "b", firedAt = t0.plusSeconds(100.0), level = Level.VISUAL))
            .copy(stretch = DriveSnapshot.StretchState(radar = corridor, enteredAt = t0, entryGate = corridor.start, entrySpeedMps = 25.0, entryCoordinate = at(41.0, -1.0)))
        val file = PassLedgerFile(File(dir, "passes.json"))
        assertTrue(file.save(ledger))
        assertEquals(ledger, file.load())
        File(dir, "passes.json").writeText("{not json")
        assertEquals(PassLedger(), file.load(), "a broken file never blocks a drive")
        assertEquals(PassLedger(), PassLedgerFile(File(dir, "missing.json")).load())
    }

    /// Killed two fixes after the warning and relaunched with the persisted ledger: the voice never repeats.
    @Test
    fun theLedgerSurvivesARelaunchMidDrive() {
        val fixes = Vector.load("a2-120kmh-ne").fixList
        val first = AlertEngine(Fixtures.store, PassLedger(), locale = Fixtures.es)
        val fired = fixes.indexOfFirst { fix -> first.ingest(fix).any { it.kind is AlertEvent.Kind.Warn } }
        assertTrue(fired >= 0)
        first.ingest(fixes[fired + 1])
        val second = AlertEngine(Fixtures.store, first.ledger, locale = Fixtures.es)
        val events = fixes.drop(fired + 2).flatMap { second.ingest(it) }
        assertFalse(events.any { it.kind is AlertEvent.Kind.Warn }, "the voice must not repeat after a relaunch")
        assertEquals(1, events.count { it.kind == AlertEvent.Kind.Passed })
    }

    /// Killed inside the corridor and relaunched: still inside, "Fin de tramo." at the far gate, then the card leaves.
    @Test
    fun aRelaunchMidStretchStillExitsAtTheFarGate() {
        val fixes = Vector.load("corridor-n232-from-west").fixList
        val first = AlertEngine(Fixtures.store, PassLedger(), locale = Fixtures.es)
        fixes.take(150).forEach { first.ingest(it) }
        assertNotNull(first.snapshot.stretch)
        assertEquals("dgt_invive-Tramo_Invive_344", first.ledger.stretch?.radar?.id, "the ledger carries the stretch for the relaunch")

        val second = AlertEngine(Fixtures.store, first.ledger, locale = Fixtures.es)
        assertEquals("dgt_invive-Tramo_Invive_344", second.snapshot.stretch?.radar?.id, "restored before the first fix")
        assertEquals(DrivePhase.INSIDE_STRETCH, second.snapshot.content.phase, "the card is the stretch's from the start")
        assertEquals("dgt_invive-Tramo_Invive_344", second.snapshot.next?.id)
        val events = mutableListOf<AlertEvent>()
        val phasesAfterExit = mutableListOf<DrivePhase>()
        for (fix in fixes.drop(150)) {
            events.addAll(second.ingest(fix))
            if (events.any { it.kind is AlertEvent.Kind.StretchExited }) phasesAfterExit.add(second.snapshot.content.phase)
        }
        assertEquals(listOf<AlertEvent.Kind>(AlertEvent.Kind.StretchExited(StretchExitReason.FAR_GATE)), events.map { it.kind })
        assertEquals("Fin de tramo.", events.first().phrase?.spoken)
        assertNull(second.ledger.stretch, "the exit clears the stretch in the ledger")
        assertFalse(DrivePhase.INSIDE_STRETCH in phasesAfterExit, "the card leaves the stretch: $phasesAfterExit")
        assertEquals(DrivePhase.WATCHING, second.snapshot.content.phase)
    }

    /// A stretch whose pass is already over is not restored.
    @Test
    fun aRelaunchAfterTheStretchWasPassedDoesNotRestoreIt() {
        val corridor = Fixtures.radar("dgt_invive-Tramo_Invive_344")
        val ledger = PassLedger(entries = listOf(PassLedger.Entry(id = corridor.id, firedAt = t0, level = Level.FULL, passedAt = t0.plusSeconds(600.0))))
            .copy(stretch = DriveSnapshot.StretchState(radar = corridor, enteredAt = t0, entryGate = corridor.start))
        val engine = AlertEngine(Fixtures.store, ledger, locale = Fixtures.es)
        assertNull(engine.snapshot.stretch)
        assertNull(engine.ledger.stretch)
    }

    /// A relaunch inside an average-speed section estimates the path before the relaunch from the entry position.
    @Test
    fun aRelaunchInsideASectionKeepsTheAverage() {
        val fixes = Vector.load("section-z40-100kmh").fixList
        val first = AlertEngine(Fixtures.store, PassLedger(), locale = Fixtures.es)
        fixes.take(107).forEach { first.ingest(it) }
        val second = AlertEngine(Fixtures.store, first.ledger, locale = Fixtures.es)
        fixes.subList(107, 140).forEach { second.ingest(it) }
        val avg = second.snapshot.stretch?.avgKmh ?: error("not inside")
        assertTrue(kotlin.math.abs(avg - 100) <= 5, "the path before the relaunch is estimated; a restart from zero would read about 50, got $avg")
    }
}
