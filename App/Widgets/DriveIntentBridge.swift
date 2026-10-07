// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The widget target's side of DriveIntentBridge. StartDriveIntent and StopDriveIntent compile into the widget so
// the "Conducir" control can name its action, but as LiveActivityIntents they run in the app process, where
// Intents/DriveIntentBridge.swift does the work. Reaching this copy means the system ran the intent in the
// extension: it logs that and does nothing.

import os

enum DriveIntentBridge {
    private static let logger = Logger(subsystem: "io.github.geiserx.radares.activity", category: "intents")

    static func startDrive() async {
        logger.error("StartDriveIntent ran in the widget extension; the app process should run it")
    }

    static func stopDrive() async {
        logger.error("StopDriveIntent ran in the widget extension; the app process should run it")
    }
}
