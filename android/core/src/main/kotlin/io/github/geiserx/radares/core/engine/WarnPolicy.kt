// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Engine/WarnPolicy.swift.
// warnDistance(speed) = clamp(speed x warnLeadSeconds, warnFloorM, warnCapM); speed = median of the last valid speeds.

package io.github.geiserx.radares.core.engine

import io.github.geiserx.radares.core.Thresholds
import kotlin.math.max
import kotlin.math.min

object WarnPolicy {
    /// Metres of warning for a speed in m/s: 50 km/h 347, 90 625, 120 833, 144 and above 1,000; never under 300.
    fun warnDistance(speed: Double): Double {
        val raw = max(0.0, speed) * Thresholds.warnLeadSeconds
        return min(Thresholds.warnCapM, max(Thresholds.warnFloorM, raw))
    }

    /// Median of the last `Thresholds.speedMedianFixes` valid speeds (oldest first); null when there is none.
    /// With two values the median is their mean.
    fun medianSpeed(speeds: List<Double>): Double? {
        val window = speeds.takeLast(Thresholds.speedMedianFixes).sorted()
        if (window.isEmpty()) return null
        if (window.size % 2 == 1) return window[window.size / 2]
        return (window[window.size / 2 - 1] + window[window.size / 2]) / 2
    }
}
