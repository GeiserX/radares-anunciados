// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Engine/StretchTracker.swift.
// Two gates plus an inside state per stretch: entry at a gate or between the gates, remaining, average speed, the
// four exits (design 2.5). The chord is used for the remaining estimate and for the mid-stretch join; the gates are
// exact. The inside state can be restored from the persisted ledger, so a relaunch mid-stretch still says
// "Fin de tramo" at the far gate.

package io.github.geiserx.radares.core.engine

import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.feed.RadarStore
import io.github.geiserx.radares.core.geo.Geo
import io.github.geiserx.radares.core.health.StretchExitReason
import io.github.geiserx.radares.core.model.Coordinate
import io.github.geiserx.radares.core.model.Fix
import io.github.geiserx.radares.core.model.Radar
import io.github.geiserx.radares.core.model.Role
import io.github.geiserx.radares.core.secondsSince
import java.time.Instant
import kotlin.math.abs
import kotlin.math.max

class StretchTracker() {
    sealed class Change {
        /// The point rule held at the near gate and the course points into the stretch, or the car joined the stretch
        /// between its gates (`remainingMetres` set). `VISUAL` means an OSM bearing on an average-speed section
        /// disagreed with the course: shown, not spoken, and not entered.
        data class Entered(val radar: Radar, val gate: Coordinate, val approach: Approach, val level: Level, val remainingMetres: Double?) : Change()
        data class Exited(val radar: Radar, val reason: StretchExitReason) : Change()
    }

    var inside: DriveSnapshot.StretchState? = null
        private set

    /// Distances to the nearer gate of each candidate line on earlier fixes, oldest first (first kept, tail bounded).
    private var histories: MutableMap<String, List<Double>> = mutableMapOf()
    /// Consecutive fixes on which each candidate line qualified for a mid-stretch join.
    private var midJoinRuns: MutableMap<String, Int> = mutableMapOf()
    private var farGate: Coordinate? = null
    private var straightChord: Double = 0.0
    private var entrySpeedMps: Double? = null
    private var pathMetres: Double = 0.0
    private var lastCoordinate: Coordinate? = null
    /// Restored from the ledger: the path before the relaunch is unknown until the first fix estimates it.
    private var pathUnknown = false

    /// Resume the stretch the car was inside when the process died (the ledger's `stretch`).
    constructor(resuming: DriveSnapshot.StretchState?) : this() {
        val state = resuming ?: return
        val end = state.radar.end ?: return
        inside = state
        val far = if (state.entryGate == end) state.radar.start else end
        farGate = far
        straightChord = Geo.distance(state.entryGate, far)
        entrySpeedMps = state.entrySpeedMps
        pathUnknown = true
    }

    /// One fix. `candidates` are the lines the engine allows to enter (alertable, not fired or cooling down).
    fun ingest(
        fix: Fix,
        courseDegrees: Double?,
        warnDistance: Double,
        speedMps: Double?,
        candidates: List<Radar>,
        now: Instant,
    ): Change? {
        // Keep the gate distances for every candidate line, inside or not.
        val seen = mutableSetOf<String>()
        val previous = mutableMapOf<String, List<Double>>()
        for (radar in candidates) {
            if (!radar.isLine) continue
            seen.add(radar.id)
            val d = RadarStore.gateDistance(fix.coordinate, radar)
            previous[radar.id] = histories[radar.id] ?: emptyList()
            val h = (histories[radar.id] ?: emptyList()).toMutableList()
            h.add(d)
            if (h.size > 8) h.removeAt(1)
            histories[radar.id] = h
        }
        histories = histories.filterKeys { it in seen }.toMutableMap()
        midJoinRuns = midJoinRuns.filterKeys { it in seen }.toMutableMap()

        val current = inside
        val far0 = farGate
        if (current != null && far0 != null) {
            var state = current
            val along = Geo.projection(fix.coordinate, state.entryGate, far0)
            if (pathUnknown) {
                pathMetres = state.entryCoordinate?.let { Geo.distance(it, fix.coordinate) } ?: along
                pathUnknown = false
            } else {
                lastCoordinate?.let { pathMetres += Geo.distance(it, fix.coordinate) }
            }
            lastCoordinate = fix.coordinate
            state = state.copy(remainingMetres = max(0.0, straightChord - along))
            val elapsed = now.secondsSince(state.enteredAt)
            if (state.radar.role == Role.AVERAGE_SPEED_SECTION && elapsed > 0) {
                state = state.copy(avgKmh = pathMetres / elapsed * 3.6)
            }
            inside = state

            val length = max(max(state.radar.roadMetres ?: 0.0, state.radar.chordMetres ?: 0.0), straightChord)
            val v = entrySpeedMps
            val reason: StretchExitReason? = if (Geo.distance(fix.coordinate, far0) <= Thresholds.stretchExitGateM) {
                StretchExitReason.FAR_GATE
            } else if (Geo.distance(fix.coordinate, state.entryGate) > length + Thresholds.stretchExitSlackM) {
                StretchExitReason.DISTANCE
            } else if (v != null && v > 0 && elapsed > Thresholds.stretchExitTraverseFactor * (length / v)) {
                StretchExitReason.TIME
            } else {
                null
            }
            if (reason != null) {
                val radar = state.radar
                leave()
                return Change.Exited(radar, reason)
            }
            return null
        }

        val course = courseDegrees
        if (course == null) {
            // A fix with no course cannot qualify for a join: the runs restart, three fixes means three in a row.
            midJoinRuns = mutableMapOf()
            return null
        }
        val ordered = candidates.filter { it.isLine }.sortedBy { RadarStore.gateDistance(fix.coordinate, it) }
        for (radar in ordered) {
            val end = radar.end ?: continue
            val toStart = Geo.distance(fix.coordinate, radar.start)
            val toEnd = Geo.distance(fix.coordinate, end)
            val near = if (toStart <= toEnd) radar.start else end
            val far = if (toStart <= toEnd) end else radar.start
            val approach = ApproachEvaluator.evaluate(
                gate = near,
                bearing = radar.bearing,
                bidirectional = radar.bidirectional || radar.role == Role.MOBILE_CORRIDOR,
                fix = fix,
                courseDegrees = course,
                previousDistances = previous[radar.id] ?: emptyList(),
                warnDistance = warnDistance,
            )
            val level = approach.level ?: continue
            if (!(Geo.angleDiff(course, Geo.bearing(near, far)) <= Thresholds.stretchEntryDeg)) continue
            if (level == Level.FULL) {
                enter(radar, near, far, speedMps, fix.coordinate, now)
            }
            return Change.Entered(radar, near, approach, level, null)
        }

        // Mid-stretch join (design 2.5): between the gate margins, near the chord and heading along it, on
        // stretchMidJoinFixes consecutive fixes. The chord is not the road, so a bowed stretch can be missed.
        for (radar in ordered) {
            val end = radar.end ?: continue
            val chord = Geo.distance(radar.start, end)
            val chordCourse = Geo.bearing(radar.start, end)
            val along = Geo.alongChord(fix.coordinate, radar.start, end)
            val crossTrack = abs(Geo.crossTrack(fix.coordinate, radar.start, chordCourse))
            val forward = Geo.angleDiff(course, chordCourse) <= Thresholds.stretchEntryDeg
            val backward = Geo.angleDiff(course, Geo.normalize(chordCourse + 180)) <= Thresholds.stretchEntryDeg
            val margin = Thresholds.stretchExitGateM
            var qualifies = along > margin && along < chord - margin &&
                crossTrack <= Thresholds.stretchMidJoinCrossTrackM &&
                (forward || backward)
            // The direction gate of 2.4 as at a gate; a mismatch is no entry here.
            val bearing = radar.bearing
            if (qualifies && bearing != null && !(radar.bidirectional || radar.role == Role.MOBILE_CORRIDOR)) {
                qualifies = Geo.angleDiff(course, bearing) <= Thresholds.bearingToleranceDeg
            }
            if (!qualifies) {
                midJoinRuns[radar.id] = 0
                continue
            }
            val run = (midJoinRuns[radar.id] ?: 0) + 1
            midJoinRuns[radar.id] = run
            if (run < Thresholds.stretchMidJoinFixes) continue
            val entryGate = if (forward) radar.start else end
            val far = if (forward) end else radar.start
            val remaining = if (forward) chord - along else along
            enter(radar, entryGate, far, speedMps, fix.coordinate, now)
            inside = inside?.copy(remainingMetres = remaining)
            midJoinRuns = mutableMapOf()
            val approach = Approach(ahead = true, closing = true, inRange = true, directionMatch = true, late = false, distanceMetres = remaining, crossTrackMetres = crossTrack)
            return Change.Entered(radar, entryGate, approach, Level.FULL, remaining)
        }
        return null
    }

    /// Drive end: the inside state is dropped silently.
    fun endDrive(): Change? {
        midJoinRuns = mutableMapOf()
        val state = inside ?: return null
        leave()
        return Change.Exited(state.radar, StretchExitReason.DRIVE_END)
    }

    private fun enter(radar: Radar, near: Coordinate, far: Coordinate, speedMps: Double?, coordinate: Coordinate, now: Instant) {
        straightChord = Geo.distance(near, far)
        farGate = far
        entrySpeedMps = speedMps
        pathMetres = 0.0
        pathUnknown = false
        lastCoordinate = coordinate
        inside = DriveSnapshot.StretchState(
            radar = radar, enteredAt = now, entryGate = near, remainingMetres = straightChord, avgKmh = null,
            entrySpeedMps = speedMps, entryCoordinate = coordinate,
        )
    }

    private fun leave() {
        inside = null
        farGate = null
        entrySpeedMps = null
        pathMetres = 0.0
        pathUnknown = false
        lastCoordinate = null
    }
}
