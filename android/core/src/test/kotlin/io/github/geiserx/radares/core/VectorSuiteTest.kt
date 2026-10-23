// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Tests/RadaresCoreTests/AlertEngineVectorTests.swift (the runner and the per-vector checks).
// Every *.json in Fixtures/vectors is a drive over the fixture with the events the engine must produce (SPEC 10).
// One dynamic test per file, named by the file, so a vector added on main is run here without a code change.

package io.github.geiserx.radares.core

import io.github.geiserx.radares.core.engine.AlertEngine
import io.github.geiserx.radares.core.engine.AlertEvent
import io.github.geiserx.radares.core.engine.PassLedger
import io.github.geiserx.radares.core.feed.RadarStore
import io.github.geiserx.radares.core.model.Fix
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DynamicTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestFactory
import java.io.File
import kotlin.math.abs

@Serializable
data class Vector(
    val name: String,
    val description: String,
    val locale: String? = null,
    val negativeControl: Boolean? = null,
    val fixes: List<VFix>,
    val expected: List<VEvent>,
    val snapshots: List<VSnapshot>? = null,
) {
    @Serializable
    data class VFix(val t: String, val lat: Double, val lon: Double, val speed: Double? = null, val course: Double? = null, val accuracy: Double, val stationary: Boolean)

    @Serializable
    data class VEvent(
        val kind: String,
        val level: String? = null,
        val radar: String? = null,
        val distance: Double? = null,
        val tolerance: Double? = null,
        val late: Boolean? = null,
        val opposite: Boolean? = null,
        val spoken: String? = null,
        val exitReason: String? = null,
    )

    @Serializable
    data class VSnapshot(
        val fixIndex: Int,
        val stretch: String? = null,
        val remainingMetres: Double? = null,
        val tolerance: Double? = null,
        val avgKmh: Double? = null,
        val avgTolerance: Double? = null,
        val phase: String? = null,
    )

    val fixList: List<Fix>
        get() = fixes.map { f ->
            Fix(coordinate = at(f.lat, f.lon), timestamp = InstantSerializer.parseIso(f.t), speed = f.speed, course = f.course, horizontalAccuracy = f.accuracy, isStationary = f.stationary)
        }

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun load(file: File): Vector = json.decodeFromString(serializer(), file.readText())

        fun load(name: String): Vector = load(File(Fixtures.vectorsDir, "$name.json"))

        fun files(): List<File> = (Fixtures.vectorsDir.listFiles { f -> f.name.endsWith(".json") } ?: emptyArray()).sortedBy { it.name }
    }
}

class VectorRun {
    val events = mutableListOf<Pair<Int, AlertEvent>>()
    val mismatches = mutableListOf<String>()
}

object VectorRunner {
    /// Swift's procedure exactly: a new engine with the wall-clock default `now`, an empty ledger, the vector's locale.
    /// The wall clock matters: the "Radar superado" card lasts 4 s of `now`, and the vectors are dated 2026-10-07, so
    /// after a pass the phase reads `watching`, as it does on iOS.
    fun run(vector: Vector, store: RadarStore, ledger: PassLedger = PassLedger()): VectorRun {
        val engine = AlertEngine(store, ledger, locale = localeOf(vector.locale ?: "es_ES"))
        val run = VectorRun()
        // A snapshot check the fix loop never reaches would otherwise pass silently.
        for (check in vector.snapshots ?: emptyList()) {
            if (check.fixIndex >= vector.fixes.size) run.mismatches.add("snapshot at ${check.fixIndex} never reached: the vector has ${vector.fixes.size} fixes")
        }
        for ((i, fix) in vector.fixList.withIndex()) {
            for (e in engine.ingest(fix)) run.events.add(i to e)
            for (check in vector.snapshots ?: emptyList()) {
                if (check.fixIndex != i) continue
                val s = engine.snapshot
                if (check.stretch != null && s.stretch?.radar?.id != check.stretch) run.mismatches.add("fix $i: expected inside ${check.stretch}, got ${s.stretch?.radar?.id ?: "nil"}")
                if (check.remainingMetres != null) {
                    val got = s.stretch?.remainingMetres ?: -1.0
                    if (abs(got - check.remainingMetres) > (check.tolerance ?: 50.0)) run.mismatches.add("fix $i: remaining $got vs ${check.remainingMetres}")
                }
                if (check.avgKmh != null) {
                    val got = s.stretch?.avgKmh ?: -1.0
                    if (abs(got - check.avgKmh) > (check.avgTolerance ?: 3.0)) run.mismatches.add("fix $i: avg $got vs ${check.avgKmh}")
                }
                if (check.phase != null && s.content.phase.raw != check.phase) run.mismatches.add("fix $i: phase ${s.content.phase.raw} vs ${check.phase}")
            }
        }
        run.mismatches.addAll(compare(run.events.map { it.second }, vector.expected))
        return run
    }

    fun describe(e: AlertEvent): String =
        "${e.kind} ${e.radar?.id ?: "-"} ${e.distance?.toInt() ?: -1} m late=${e.late} spoken=${e.phrase?.spoken ?: "nil"}"

    fun compare(events: List<AlertEvent>, expected: List<Vector.VEvent>): List<String> {
        val out = mutableListOf<String>()
        if (events.size != expected.size) {
            out.add("expected ${expected.size} events, got ${events.size}: ${events.map { describe(it) }}")
        }
        for ((i, pair) in events.zip(expected).withIndex()) {
            val (e, x) = pair
            var level: String? = null
            var exitReason: String? = null
            val kind = when (val k = e.kind) {
                is AlertEvent.Kind.Warn -> { level = k.level.raw; "warn" }
                AlertEvent.Kind.Passed -> "passed"
                AlertEvent.Kind.StretchEntered -> { level = "full"; "stretchEntered" }
                is AlertEvent.Kind.StretchExited -> { exitReason = k.reason.raw; "stretchExited" }
                AlertEvent.Kind.DriveEnded -> "driveEnded"
            }
            if (kind != x.kind) out.add("event $i: kind $kind vs ${x.kind}")
            if (x.level != null && x.level != level) out.add("event $i: level ${level ?: "nil"} vs ${x.level}")
            if (x.radar != null && x.radar != e.radar?.id) out.add("event $i: radar ${e.radar?.id ?: "nil"} vs ${x.radar}")
            if (x.distance != null) {
                val got = e.distance ?: -1.0
                if (abs(got - x.distance) > (x.tolerance ?: 40.0)) out.add("event $i: distance $got vs ${x.distance} ± ${x.tolerance ?: 40.0}")
            }
            if (x.late != null && x.late != e.late) out.add("event $i: late ${e.late} vs ${x.late}")
            if (x.opposite != null && x.opposite != e.content.opposite) out.add("event $i: opposite ${e.content.opposite} vs ${x.opposite}")
            if (x.spoken != null && x.spoken != e.phrase?.spoken) out.add("event $i: spoken \"${e.phrase?.spoken ?: "nil"}\" vs \"${x.spoken}\"")
            if (x.spoken == null && kind == "warn" && level == "visual" && e.phrase != null) out.add("event $i: a visual warning must not have a phrase")
            if (x.spoken == null && kind == "stretchExited" && e.phrase != null) out.add("event $i: a silent exit must not have a phrase")
            // The reason rides on the event itself, so the log row can be written from the event alone.
            if (x.exitReason != null && x.exitReason != exitReason) out.add("event $i: exit reason ${exitReason ?: "nil"} vs ${x.exitReason}")
        }
        return out
    }
}

class VectorSuiteTest {
    /// One test per vector file. A negative control must mismatch, and when its event count is what is wrong (the
    /// deleted-warning control on main: "expected 1 events, got 2") that count line comes first.
    @TestFactory
    fun everyRouteVector(): List<DynamicTest> {
        val files = Vector.files()
        return files.map { file ->
            DynamicTest.dynamicTest(file.nameWithoutExtension) {
                val vector = Vector.load(file)
                assertEquals(file.nameWithoutExtension, vector.name, "the vector's name matches its file")
                val run = VectorRunner.run(vector, Fixtures.store)
                if (vector.negativeControl == true) {
                    assertFalse(run.mismatches.isEmpty(), "${vector.name}: the harness accepted a vector whose expectation is known to be wrong")
                    if (run.events.size != vector.expected.size) {
                        val countLine = "expected ${vector.expected.size} events, got ${run.events.size}"
                        assertTrue(run.mismatches.first().contains(countLine), "${vector.name}: ${run.mismatches}")
                    }
                    println("negative control ${vector.name} rejected as it must be: ${run.mismatches.first()}")
                } else {
                    assertTrue(run.mismatches.isEmpty(), "${vector.name}: ${run.mismatches.joinToString(" | ")}")
                }
            }
        }
    }

    /// The suite cannot pass by running nothing: the dir exists, holds at least the 28 vectors of 2026-10-23, and at
    /// least one of them is a negative control.
    @Test
    fun theVectorDirectoryIsThereAndNotEmpty() {
        val files = Vector.files()
        println("route vectors found: ${files.size}")
        assertTrue(files.size >= 28, "expected at least 28 vectors in ${Fixtures.vectorsDir}, found ${files.size}")
        assertTrue(files.any { Vector.load(it).negativeControl == true }, "no negativeControl vector: the suite could not prove it can fail")
    }

    /// The deleted-warning negative control fails on the count line exactly as on iOS.
    @Test
    fun theNegativeControlFailsOnTheEventCount() {
        val negatives = Vector.files().map { Vector.load(it) }.filter { it.negativeControl == true }
        assertTrue(negatives.isNotEmpty())
        val countMismatches = negatives.map { VectorRunner.run(it, Fixtures.store).mismatches.first() }
        assertTrue(countMismatches.any { it.contains("expected 1 events, got 2") }, "$countMismatches")
    }

    /// A snapshot check that names a fix the vector does not have must fail the vector, not pass unnoticed.
    @Test
    fun aSnapshotCheckBeyondTheLastFixFailsTheVector() {
        val vector = Vector.load("corridor-n232-from-west").copy(snapshots = listOf(Vector.VSnapshot(fixIndex = 99_999, remainingMetres = 1.0)))
        val run = VectorRunner.run(vector, Fixtures.store)
        assertTrue(run.mismatches.any { it.contains("never reached") }, "${run.mismatches}")
    }
}
