// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// warnDistance(speed:) = clamp(speed x warnLeadSeconds, warnFloorM, warnCapM); speed = median of the last valid speeds (design 2.2).

import Foundation

public struct WarnPolicy: Sendable {
    public static func warnDistance(speed: Double) -> Double {
        fatalError("lane: core")
    }

    /// Median of the last `Thresholds.speedMedianFixes` valid speeds; nil when there is none.
    public static func medianSpeed(_ speeds: [Double]) -> Double? {
        fatalError("lane: core")
    }
}
