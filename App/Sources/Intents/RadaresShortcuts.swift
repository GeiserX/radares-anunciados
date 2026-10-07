// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The intents in Atajos and Siri without setup (design 4.2). App target only. The phrases here are Spanish (the
// development language); AppShortcuts.xcstrings beside this file carries the English ones. Every phrase names the
// app, as Siri requires.

import AppIntents

public struct RadaresShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDriveIntent(),
            phrases: [
                "Iniciar aviso de radares en \(.applicationName)",
                "Avísame de los radares con \(.applicationName)",
                "Conducir con \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Iniciar aviso de radares", table: "Surfaces"),
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: StopDriveIntent(),
            phrases: [
                "Parar aviso de radares en \(.applicationName)",
                "Deja de avisar de radares con \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Parar aviso de radares", table: "Surfaces"),
            systemImageName: "stop.circle"
        )
    }

    public static let shortcutTileColor: ShortcutTileColor = .red
}
