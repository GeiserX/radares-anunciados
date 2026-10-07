// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Iniciar aviso de radares": a LiveActivityIntent, so the system launches the app process without opening the
// app and the Live Activity may start from it (design 4.2). Exposed by the "Conducir" control, Atajos, Siri and
// the CarPlay automation. Compiled into the app AND the widget extension (a control's action must exist in the
// extension), so this file must not reference app-only types directly: hand the work to the app through a hook
// the app installs at launch, or an `#if` on the target.

import AppIntents
import os

public struct StartDriveIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Iniciar aviso de radares"

    public init() {}

    /// Stub: logs and returns. The control and the shortcut are user-facing, so the stub must not crash the app.
    public func perform() async throws -> some IntentResult {
        Logger(subsystem: "io.github.geiserx.radares", category: "intents")
            .warning("lane: surfaces: StartDriveIntent not implemented")
        return .result()
    }
}
