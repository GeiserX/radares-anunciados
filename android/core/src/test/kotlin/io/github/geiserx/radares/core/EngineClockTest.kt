// SPDX-License-Identifier: GPL-3.0-or-later
// The engine tests of AlertEngineVectorTests.swift that need a clock or a hand-made layout: the 4 s passed card, a
// point inside a stretch, pacing around a stretch entry, drive end, the 30 m pass rule, the card's stability.

package io.github.geiserx.radares.core

import io.github.geiserx.radares.core.engine.AlertEngine
import io.github.geiserx.radares.core.engine.AlertEvent
import io.github.geiserx.radares.core.engine.DriveContent
import io.github.geiserx.radares.core.engine.DrivePhase
import io.github.geiserx.radares.core.engine.Level
import io.github.geiserx.radares.core.engine.PassLedger
import io.github.geiserx.radares.core.feed.RadarStore
import io.github.geiserx.radares.core.geo.Geo
import io.github.geiserx.radares.core.health.StretchExitReason
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.time.Instant

class EngineClockTest {
    /// "Radar superado" holds for exactly Thresholds.passedCardSeconds of the injected clock, then the card goes back.
    @Test
    fun thePassedCardRevertsAfterFourSeconds() {
        var clock = t0
        val engine = AlertEngine(Fixtures.store, PassLedger(), now = { clock }, locale = Fixtures.es)
        val a2 = Fixtures.radar("dgt-CABINACINEMOMETRO_120001")
        val fixes = straightFixes(a2.start, course = 60.0, speed = 25.0, metresBefore = 1010.0, metresAfter = 200.0)
        var passedAt: Instant? = null
        for (fix in fixes) {
            clock = fix.timestamp
            if (engine.ingest(fix).any { it.kind == AlertEvent.Kind.Passed }) {
                passedAt = fix.timestamp
                break
            }
        }
        val at = passedAt ?: error("never passed")
        assertEquals(DrivePhase.PASSED, engine.snapshot.content.phase)
        assertEquals("Radar superado", engine.snapshot.content.title)
        clock = at.plusSeconds(3.9)
        assertEquals(DrivePhase.PASSED, engine.snapshot.content.phase, "still inside the 4 s")
        clock = at.plusSeconds(Thresholds.passedCardSeconds)
        assertEquals(DrivePhase.WATCHING, engine.snapshot.content.phase, "back to watching after 4 s")
    }

    /// A point inside a corridor owns the card while ahead and for the 4 s passed card, then the stretch card returns.
    @Test
    fun aPointInsideAStretchOwnsTheCardUntilPassed() {
        val vector = Vector.load("corridor-n232-from-west")
        val corridor = Fixtures.radar("dgt_invive-Tramo_Invive_344")
        val end = corridor.end!!
        val onChord = Geo.destination(corridor.start, Geo.bearing(corridor.start, end), 5000.0)
        val point = makeRadar(id = "inside", start = onChord, name = "Radar fijo N-232", road = "N-232", kmFrom = 25.8, maxspeed = 90)
        var clock = t0
        val engine = AlertEngine(RadarStore(Fixtures.store.all + point), PassLedger(), now = { clock }, locale = Fixtures.es)
        val kinds = mutableListOf<AlertEvent.Kind>()
        val cardWhileAhead = mutableListOf<DriveContent>()
        var passedCards = 0
        var backInside = false
        var fired = false
        var passed = false
        for (fix in vector.fixList) {
            clock = fix.timestamp
            val events = engine.ingest(fix)
            kinds.addAll(events.map { it.kind })
            for (e in events.filter { it.radar?.id == point.id }) {
                if (e.kind == AlertEvent.Kind.Warn(Level.FULL)) {
                    fired = true
                    assertEquals("Radar fijo a 600 metros. Límite 90.", e.phrase?.spoken)
                }
                if (e.kind == AlertEvent.Kind.Passed) passed = true
            }
            val card = engine.snapshot.content
            if (fired && !passed) cardWhileAhead.add(card)
            if (passed && card.phase == DrivePhase.PASSED) passedCards += 1
            if (passed && card.phase == DrivePhase.INSIDE_STRETCH) backInside = true
        }
        assertTrue(fired && passed)
        assertTrue(cardWhileAhead.isNotEmpty())
        assertTrue(cardWhileAhead.all { it.phase == DrivePhase.ALERT && it.title == "Radar fijo" && it.distanceMetres != null }, "${cardWhileAhead.map { it.phase }}")
        val distances = cardWhileAhead.mapNotNull { it.distanceMetres }
        assertTrue(distances.first() > distances.last(), "the card counts down: $distances")
        assertEquals(Thresholds.passedCardSeconds.toInt(), passedCards, "Radar superado holds for the designed seconds at 1 Hz")
        assertTrue(backInside, "the stretch card returns after the pass")
        assertTrue(AlertEvent.Kind.StretchExited(StretchExitReason.FAR_GATE) in kinds)
        assertEquals(DrivePhase.WATCHING, engine.snapshot.content.phase)
    }

    /// A stretch entry is spoken inside the pacing gap after a point; a point inside the gap after the entry is visual.
    @Test
    fun aStretchEntryIsSpokenInsideThePacingGap() {
        val vector = Vector.load("corridor-n232-from-west")
        val corridor = Fixtures.radar("dgt_invive-Tramo_Invive_344")
        val end = corridor.end!!
        val into = Geo.bearing(corridor.start, end)
        val before = Geo.destination(corridor.start, Geo.normalize(into + 180), 100.0)
        val point = makeRadar(id = "beforeGate", start = before, name = "Radar fijo N-232", road = "N-232", kmFrom = 20.7, maxspeed = 90)
        val engine = AlertEngine(RadarStore(Fixtures.store.all + point), PassLedger(), locale = Fixtures.es)
        val events = vector.fixList.flatMap { fix -> engine.ingest(fix).map { fix.timestamp to it } }
        val warn = events.first { it.second.kind == AlertEvent.Kind.Warn(Level.FULL) && it.second.radar?.id == point.id }
        val entered = events.first { it.second.kind == AlertEvent.Kind.StretchEntered }
        assertTrue(entered.first.secondsSince(warn.first) < Thresholds.pacingSeconds, "the layout must put the entry inside the gap")
        assertEquals("Radar fijo a 600 metros. Límite 90.", warn.second.phrase?.spoken)
        assertEquals("Tramo de radar móvil, N-232, 10 kilómetros.", entered.second.phrase?.spoken)
        assertEquals("Fin de tramo.", events.last().second.phrase?.spoken)

        val after = Geo.destination(corridor.start, into, 100.0)
        val pointAfter = makeRadar(id = "afterGate", start = after, name = "Radar fijo N-232", road = "N-232", kmFrom = 20.9, maxspeed = 90)
        val second = AlertEngine(RadarStore(Fixtures.store.all + pointAfter), PassLedger(), locale = Fixtures.es)
        val later = vector.fixList.flatMap { second.ingest(it) }
        val afterWarn = later.first { it.radar?.id == pointAfter.id }
        assertEquals(AlertEvent.Kind.Warn(Level.VISUAL), afterWarn.kind)
        assertNull(afterWarn.phrase)
    }

    @Test
    fun endDriveClosesAStretchSilentlyAndPrunes() {
        val fixes = Vector.load("corridor-n232-from-west").fixList
        // endDrive prunes against the engine clock: pin it to the drive, not to the day the test runs.
        val driveEnd = fixes.take(150).last().timestamp
        val engine = AlertEngine(Fixtures.store, PassLedger(), now = { driveEnd }, locale = Fixtures.es)
        fixes.take(150).forEach { engine.ingest(it) }
        assertNotNull(engine.snapshot.stretch)
        val events = engine.endDrive()
        assertEquals(listOf(AlertEvent.Kind.StretchExited(StretchExitReason.DRIVE_END), AlertEvent.Kind.DriveEnded), events.map { it.kind })
        assertNull(events.first().phrase)
        assertEquals(StretchExitReason.DRIVE_END, engine.lastStretchExitReason)
        assertNull(engine.snapshot.stretch)
        assertEquals(DrivePhase.WATCHING, engine.snapshot.content.phase)
        assertEquals(1, engine.ledger.entries.size, "the stretch pass is kept until its cooldown is over")
    }

    /// Fires, drives to 10 m from the radar and stops: only the under-30 m rule can mark the pass.
    @Test
    fun stoppingAtTheRadarIsAPassByTheThirtyMetreRule() {
        val engine = AlertEngine(Fixtures.store, PassLedger(), locale = Fixtures.es)
        val a2 = Fixtures.radar("dgt-CABINACINEMOMETRO_120001")
        val fixes = straightFixes(a2.start, 60.0, 25.0, 1010.0, 0.0).dropLast(1).toMutableList()
        val stop = Geo.destination(a2.start, 240.0, 10.0)
        val last = fixes.last().timestamp
        for (i in 1..5) fixes.add(makeFix(stop, last.plusSeconds(i.toDouble()), speed = 0.0, course = null))
        val kinds = fixes.flatMap { fix -> engine.ingest(fix).map { it.kind } }
        assertEquals(listOf(AlertEvent.Kind.Warn(Level.FULL), AlertEvent.Kind.Passed), kinds)
    }

    /// Two radars armed ahead, the nearer one changing: the card keeps the radar it shows while it stays armed.
    @Test
    fun theSnapshotKeepsTheArmedRadarItShows() {
        val origin = at(41.3, -1.9)
        val a = makeRadar(id = "A", start = Geo.destination(origin, 90.0, 940.0))
        val b = makeRadar(id = "B", start = Geo.destination(Geo.destination(origin, 90.0, 700.0), 0.0, 600.0))
        val engine = AlertEngine(RadarStore(listOf(a, b)), PassLedger(), locale = Fixtures.es)
        val shown = mutableListOf<String>()
        for (i in 0 until 7) {
            val fix = makeFix(Geo.destination(origin, 90.0, i * 30.0), Instant.ofEpochSecond(1_800_000_000L + i), speed = 30.0, course = 90.0)
            assertTrue(engine.ingest(fix).isEmpty(), "fix $i must not fire")
            shown.add(engine.snapshot.next?.id ?: "-")
        }
        assertEquals("B", shown.first(), "B is the nearer armed radar at the start")
        assertEquals(1, shown.toSet().size, "the card stays on B while B stays armed: $shown")
    }

    @Test
    fun theSnapshotShowsTheNearestRadarAsCercaWithoutACourse() {
        val engine = AlertEngine(Fixtures.store, PassLedger(), locale = Fixtures.es)
        Vector.load("a2-no-course-2mps").fixList.take(20).forEach { engine.ingest(it) }
        val s = engine.snapshot
        assertNull(s.courseDegrees)
        assertEquals("dgt-CABINACINEMOMETRO_120001", s.next?.id)
        assertEquals("cerca", s.content.subtitle)
        assertEquals(DrivePhase.WATCHING, s.content.phase)
        assertEquals("Radar fijo", s.content.title)
    }

    @Test
    fun theIdleCardFollowsTheLocale() {
        assertEquals("Sin radares cerca", DriveContent.watching(t0, Fixtures.es).title)
        assertEquals("No radars nearby", DriveContent.watching(t0, Fixtures.en).title)
        assertFalse(AlertEngine(Fixtures.store, PassLedger(), locale = Fixtures.en).snapshot.content.title.startsWith("Sin"))
    }
}
