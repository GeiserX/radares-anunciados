// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// warnDistance(speed:) = clamp(speed x warnLeadSeconds, warnFloorM, warnCapM); speed = median of the last valid speeds (design 2.2).

import Foundation

public struct WarnPolicy: Sendable {
    /// Metres of warning for a speed in m/s: 50 km/h 347, 90 625, 120 833, 144 and above 1,000; never under 300.
    public static func warnDistance(speed: Double) -> Double {
        let raw = max(0, speed) * Thresholds.warnLeadSeconds
        return min(Thresholds.warnCapM, max(Thresholds.warnFloorM, raw))
    }

    /// Median of the last `Thresholds.speedMedianFixes` valid speeds (oldest first); nil when there is none.
    /// With two values the median is their mean, so one bad fix still cannot move the distance alone.
    public static func medianSpeed(_ speeds: [Double]) -> Double? {
        let window = Array(speeds.suffix(Thresholds.speedMedianFixes)).sorted()
        guard !window.isEmpty else { return nil }
        if window.count % 2 == 1 { return window[window.count / 2] }
        return (window[window.count / 2 - 1] + window[window.count / 2]) / 2
    }
}
