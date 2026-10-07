// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Parar aviso de radares": ends the drive (design 3.1, drive end). Compiled into the app and the widget extension.

import AppIntents
import os

public struct StopDriveIntent: AppIntent {
    public static let title: LocalizedStringResource = "Parar aviso de radares"

    public init() {}

    /// Stub: logs and returns. The shortcut is user-facing, so the stub must not crash the app.
    public func perform() async throws -> some IntentResult {
        Logger(subsystem: "io.github.geiserx.radares", category: "intents")
            .warning("lane: surfaces: StopDriveIntent not implemented")
        return .result()
    }
}
