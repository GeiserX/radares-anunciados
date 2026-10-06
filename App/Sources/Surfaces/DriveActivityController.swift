// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// start / update / alert / end / reattach of the one Live Activity (design 4.2): milestone cadence, content read
// back after every update (activityUpdated(dropped:)), staleDate 120 s (15 min paused), end .after(5 min).

import ActivityKit
import RadaresCore
import os

@MainActor
public final class DriveActivityController {
    public static let shared = DriveActivityController()

    public private(set) var current: Activity<DriveAttributes>?

    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "activity")

    private init() {}

    /// Foreground or LiveActivityIntent only: Activity.request refuses the background.
    public func start(content: DriveContent) throws {
        fatalError("lane: surfaces")
    }

    public func update(_ content: DriveContent, alert: Phrase?) async {
        fatalError("lane: surfaces")
    }

    public func end() async {
        fatalError("lane: surfaces")
    }

    /// Stub: logs and returns so the skeleton launches in the simulator.
    public func reattach() {
        logger.warning("lane: surfaces: reattach not implemented")
    }
}
