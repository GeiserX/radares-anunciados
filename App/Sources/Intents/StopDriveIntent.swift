// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Parar aviso de radares": ends the drive (design 3.1, drive end). Compiled into the app and the widget extension.
// A LiveActivityIntent (it ends the Live Activity), so it runs in the app process like StartDriveIntent.

import AppIntents

public struct StopDriveIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = LocalizedStringResource("Parar aviso de radares", table: "Surfaces")
    public static let description = IntentDescription(
        LocalizedStringResource("Termina el viaje: deja de avisar hasta el próximo y quita la tarjeta.", table: "Surfaces")
    )

    public init() {}

    public func perform() async throws -> some IntentResult {
        await DriveIntentBridge.stopDrive()
        return .result()
    }
}
