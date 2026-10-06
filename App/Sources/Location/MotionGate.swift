// Lane: location
// SPDX-License-Identifier: GPL-3.0-or-later
//
// queryActivityStarting over the last Thresholds.motionWindowSeconds, positive-only: true means automotive with
// at least medium confidence; false means nothing automotive; nil means unavailable or denied. Never suppresses the probe.

import CoreMotion
import Foundation

public struct MotionGate: Sendable {
    public init() {}

    public func recentAutomotive(window: TimeInterval) async -> Bool? {
        fatalError("lane: location")
    }
}
