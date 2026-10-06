// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// BGAppRefreshTask "io.github.geiserx.radares.refresh" (submit, handle, resubmit), the foreground and drive-start
// triggers through FeedRefreshPolicy, manual "Actualizar ahora" (design 5.1, 5.2).

import BackgroundTasks
import RadaresCore
import os

@MainActor
public final class FeedRefresher {
    public static let shared = FeedRefresher()

    public static let taskIdentifier = "io.github.geiserx.radares.refresh"

    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "feed")

    private init() {}

    /// Stub: logs and returns so the skeleton launches in the simulator.
    public func registerBackgroundTask() {
        logger.warning("lane: app: registerBackgroundTask not implemented")
    }

    /// Stub: logs and returns; runs on every foreground, which the simulator launch includes.
    public func refreshIfNeeded(trigger: FeedRefreshPolicy.Trigger) async {
        logger.warning("lane: app: refreshIfNeeded(\(trigger.rawValue, privacy: .public)) not implemented")
    }

    public func refreshNow() async {
        fatalError("lane: app")
    }
}
