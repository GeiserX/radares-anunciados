// SPDX-License-Identifier: GPL-3.0-or-later
//
// Every route vector driven through the app's own drive path: DriveController -> AlertEngine -> AlertDispatcher,
// with a fake voice and a fake notification poster. What the voice says must be, in order, exactly the vector's
// `spoken` lines; every warning and stretch entry posts one notification, silent for the opposite flow.

package io.github.geiserx.radares.surfaces

import io.github.geiserx.radares.FakePoster
import io.github.geiserx.radares.FakeSpeaker
import io.github.geiserx.radares.Fixtures
import io.github.geiserx.radares.RecordingEvents
import io.github.geiserx.radares.core.engine.AlertEngine
import io.github.geiserx.radares.core.engine.PassLedger
import io.github.geiserx.radares.drive.DriveController
import io.github.geiserx.radares.drive.Wake
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DynamicTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestFactory

class DispatcherTest {

    private class Run(val speaker: FakeSpeaker, val poster: FakePoster, val events: RecordingEvents)

    private fun drive(vector: Fixtures.Vector): Run {
        val speaker = FakeSpeaker()
        val poster = FakePoster()
        val events = RecordingEvents()
        var seq = 0
        val dispatcher = AlertDispatcher(speaker, poster, events, { ++seq }, vector.locale)
        var now = vector.fixes.first().timestamp
        val controller = DriveController(
            clock = { now },
            // The wall-clock default, exactly as the core vector suite builds the engine.
            engineFactory = { AlertEngine(Fixtures.store, PassLedger(), locale = vector.locale) },
            sink = dispatcher,
            events = events,
            ledgerSaver = {},
            armFence = {},
            stopService = {},
            recentInVehicle = { true },
            locale = vector.locale,
        )
        controller.onWake(Wake.InVehicle)
        for (fix in vector.fixes) {
            now = fix.timestamp
            controller.onFix(fix)
        }
        return Run(speaker, poster, events)
    }

    @TestFactory
    fun everyVectorSpeaksItsSentences(): List<DynamicTest> = Fixtures.vectors().filter { !it.negativeControl }.map { vector ->
        DynamicTest.dynamicTest(vector.name) {
            val run = drive(vector)
            assertEquals(vector.expected.mapNotNull { it.spoken }, run.speaker.spoken, "spoken sentences of ${vector.name}")
            val warnings = vector.expected.filter { it.kind == "warn" || it.kind == "stretchEntered" }
            assertEquals(warnings.size, run.poster.posted.size, "notifications of ${vector.name}")
            warnings.zip(run.poster.posted).forEach { (expected, posted) ->
                expected.radar?.let { assertTrue(posted.tag.startsWith("$it#"), "tag ${posted.tag} for $it") }
                if (expected.opposite == true) {
                    assertTrue(posted.silent, "opposite flow is silent in ${vector.name}")
                    assertTrue(posted.text.title.endsWith(", sentido contrario"), posted.text.title)
                }
            }
            val passed = vector.expected.filter { it.kind == "passed" }.mapNotNull { it.radar }
            assertEquals(passed, run.poster.removed, "removed on pass in ${vector.name}")
        }
    }

    @Test
    fun theNegativeControlDiffers() {
        val control = Fixtures.vectors().single { it.negativeControl }
        val run = drive(control)
        // The vector is deliberately wrong (it expects no warning); the app path must warn, so the two differ.
        assertNotEquals(control.expected.count { it.kind == "warn" }, run.poster.posted.size)
    }

    @Test
    fun passSequenceMakesEveryTagUnique() {
        val run = drive(Fixtures.vectors().single { it.name == "a2-uturn-11min-3km" })
        assertEquals(2, run.poster.posted.size)
        assertEquals(2, run.poster.posted.map { it.tag }.toSet().size)
    }

    @Test
    fun aVoiceFailureIsLoggedAndTheNotificationStillPosts() {
        val vector = Fixtures.vectors().single { it.name == "a2-120kmh-ne" }
        val speaker = FakeSpeaker(failWith = "voice missing for es-ES")
        val poster = FakePoster()
        val events = RecordingEvents()
        val dispatcher = AlertDispatcher(speaker, poster, events, { 1 }, vector.locale)
        val engine = AlertEngine(Fixtures.store, PassLedger(), locale = vector.locale)
        vector.fixes.forEach { fix -> engine.ingest(fix).forEach { dispatcher.handle(it, fix) } }
        assertEquals(1, poster.posted.size)
        val (_, sinks, spoken) = events.alerts.single()
        assertEquals(listOf("notification" to true, "speech" to false), sinks.map { it.sink to it.ok })
        assertEquals(null, spoken, "the row never claims a sentence the voice did not say")
    }
}
