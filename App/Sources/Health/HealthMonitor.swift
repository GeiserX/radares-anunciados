// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Collects HealthInputs from Core Location, the session diagnostics, UserNotifications, ActivityKit, Core Motion,
// BGTaskScheduler, feed.meta.json and the log (design 6). The rules themselves are healthReport(_:) in the core.

import RadaresCore

@MainActor
public final class HealthMonitor {
    public init() {}

    public func collect() async -> HealthInputs {
        fatalError("lane: app")
    }
}
