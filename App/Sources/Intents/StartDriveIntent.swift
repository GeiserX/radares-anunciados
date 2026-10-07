// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Iniciar aviso de radares": a LiveActivityIntent, so the system launches the app process without opening the
// app and the Live Activity may start from it (design 4.2). Exposed by the "Conducir" control, Atajos, Siri and
// the CarPlay automation. Compiled into the app AND the widget extension (a control's action must exist in the
// extension), so this file references no app-only type: the work is `DriveIntentBridge.startDrive()`, which the
// app target defines in Intents/DriveIntentBridge.swift and the widget target in Widgets/DriveIntentBridge.swift.

import AppIntents

public struct StartDriveIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = LocalizedStringResource("Iniciar aviso de radares", table: "Surfaces")
    public static let description = IntentDescription(
        LocalizedStringResource("Empieza a avisar de los radares anunciados y muestra la tarjeta en la pantalla bloqueada y en CarPlay.", table: "Surfaces")
    )

    public init() {}

    public func perform() async throws -> some IntentResult {
        await DriveIntentBridge.startDrive()
        return .result()
    }
}
