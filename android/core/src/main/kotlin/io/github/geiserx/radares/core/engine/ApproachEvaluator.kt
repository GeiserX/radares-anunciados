// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Engine/ApproachEvaluator.swift.
// The four tests of design 2.3 against one gate: ahead, closing, inRange, directionMatch; plus late and cross-track.

package io.github.geiserx.radares.core.engine

import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.geo.Geo
import io.github.geiserx.radares.core.model.Coordinate
import io.github.geiserx.radares.core.model.Fix

data class Approach(
    val ahead: Boolean,
    val closing: Boolean,
    val inRange: Boolean,
    val directionMatch: Boolean,
    val late: Boolean,
    val distanceMetres: Double,
    val crossTrackMetres: Double,
) {
    /// `FULL` when all four hold, `VISUAL` when only directionMatch fails, null otherwise.
    val level: Level?
        get() {
            if (!(ahead && closing && inRange)) return null
            return if (directionMatch) Level.FULL else Level.VISUAL
        }
}

object ApproachEvaluator {
    /// `previousDistances` are the distances to this gate on earlier fixes, oldest first, since the gate entered the
    /// candidate band: the first one decides `late`, the last two decide `closing`.
    fun evaluate(
        gate: Coordinate,
        bearing: Double?,
        bidirectional: Boolean,
        fix: Fix,
        courseDegrees: Double,
        previousDistances: List<Double>,
        warnDistance: Double,
    ): Approach {
        val distance = Geo.distance(fix.coordinate, gate)
        val toGate = Geo.bearing(fix.coordinate, gate)
        val ahead = isAhead(Geo.angleDiff(courseDegrees, toGate))

        var closing = false
        val n = previousDistances.size
        if (n >= Thresholds.closingFixes) {
            closing = true
            var later = distance
            for (i in n - 1 downTo n - Thresholds.closingFixes) {
                val earlier = previousDistances[i]
                if (earlier - later < Thresholds.closingMinM) {
                    closing = false
                    break
                }
                later = earlier
            }
        }

        val inRange = distance <= warnDistance
        val directionMatch = if (bearing != null && !bidirectional) {
            matchesDirection(Geo.angleDiff(courseDegrees, bearing))
        } else {
            true
        }
        val firstSeen = previousDistances.firstOrNull() ?: distance
        val late = firstSeen < warnDistance - Thresholds.lateBandM
        val crossTrack = Geo.crossTrack(gate, fix.coordinate, courseDegrees)
        return Approach(ahead, closing, inRange, directionMatch, late, distance, crossTrack)
    }

    /// The cone of design 2.3 is inclusive: exactly aheadDeg off is still ahead.
    fun isAhead(angleOff: Double): Boolean = angleOff <= Thresholds.aheadDeg

    /// The half-plane of design 2.4 is inclusive: exactly bearingToleranceDeg off still matches.
    fun matchesDirection(angleOff: Double): Boolean = angleOff <= Thresholds.bearingToleranceDeg
}
