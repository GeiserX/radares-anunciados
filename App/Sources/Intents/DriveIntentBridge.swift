// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// What StartDriveIntent and StopDriveIntent do, app target only. The widget target has its own
// DriveIntentBridge (Widgets/DriveIntentBridge.swift) because the intents compile there too and the widget has no
// LocationCoordinator. A LiveActivityIntent runs in the app process, so this is the one that acts.

import CoreLocation
import RadaresCore
import os

enum DriveIntentBridge {
    private static let logger = Logger(subsystem: "io.github.geiserx.radares", category: "intents")

    /// The Live Activity first, while the intent still holds the privilege to start one from the background, then
    /// the drive. Without Always the location cannot start from here (design 3.4): the card says "Abre la app".
    @MainActor
    static func startDrive() async {
        let always = CLLocationManager().authorizationStatus == .authorizedAlways
        var content = DriveContent.watching(at: Date())
        if !always {
            content.phase = .degraded
            content.note = String(localized: "Abre la app", table: "Surfaces")
        }
        do {
            try DriveActivityController.shared.start(content: content)
        } catch {
            logger.error("start intent: activity not started: \(String(describing: error), privacy: .public)")
        }
        await LocationCoordinator.shared.startDrive(reason: .intent)
        logger.notice("start intent: drive requested (always \(always))")
    }

    @MainActor
    static func stopDrive() async {
        await LocationCoordinator.shared.stopDrive()
        // The drive end normally ends the activity through AlertDispatcher; this covers a stop with no drive running.
        await DriveActivityController.shared.end()
        logger.notice("stop intent: drive stopped")
    }
}
