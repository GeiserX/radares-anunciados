// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Engine/DrivingDetector.swift.
// Pure driving-state rules (design 3.1): driveFixes at driveSpeedMps start, stationary or pauseSlowSeconds pause,
// a resume within pauseEndMinutes continues, later ends. Time comes from the fixes, never from a clock.

package io.github.geiserx.radares.core.engine

import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.model.Fix
import io.github.geiserx.radares.core.secondsSince
import java.time.Instant

enum class DriveSignal { NONE, STARTED, PAUSED, RESUMED, ENDED }

class DrivingDetector {
    sealed class Phase {
        data object Idle : Phase()
        data object Driving : Phase()
        data class Paused(val since: Instant) : Phase()
    }

    var phase: Phase = Phase.Idle
        private set
    private var fastFixes = 0
    private var slowSince: Instant? = null

    fun ingest(fix: Fix): DriveSignal {
        val speed = fix.speed ?: 0.0
        when (val p = phase) {
            Phase.Idle -> {
                if (fix.isStationary) {
                    fastFixes = 0
                    return DriveSignal.NONE
                }
                if (!(speed >= Thresholds.driveSpeedMps)) return DriveSignal.NONE
                fastFixes += 1
                if (fastFixes < Thresholds.driveFixes) return DriveSignal.NONE
                phase = Phase.Driving
                slowSince = null
                return DriveSignal.STARTED
            }
            Phase.Driving -> {
                if (fix.isStationary) return pause(fix.timestamp)
                if (speed < Thresholds.pauseSlowSpeedMps) {
                    val since = slowSince ?: fix.timestamp
                    slowSince = since
                    if (fix.timestamp.secondsSince(since) >= Thresholds.pauseSlowSeconds) return pause(fix.timestamp)
                } else {
                    slowSince = null
                }
                return DriveSignal.NONE
            }
            is Phase.Paused -> {
                if (fix.isStationary || !(speed >= Thresholds.resumeSpeedMps)) return DriveSignal.NONE
                if (fix.timestamp.secondsSince(p.since) < Thresholds.pauseEndMinutes * 60) {
                    phase = Phase.Driving
                    slowSince = null
                    return DriveSignal.RESUMED
                }
                phase = Phase.Idle
                fastFixes = if (speed >= Thresholds.driveSpeedMps) 1 else 0
                slowSince = null
                return DriveSignal.ENDED
            }
        }
    }

    private fun pause(at: Instant): DriveSignal {
        phase = Phase.Paused(at)
        slowSince = null
        fastFixes = 0
        return DriveSignal.PAUSED
    }
}
