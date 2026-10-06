// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The intents in Atajos and Siri without setup (design 4.2). App target only.

import AppIntents

public struct RadaresShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDriveIntent(),
            phrases: ["Iniciar aviso de radares en \(.applicationName)"],
            shortTitle: "Iniciar aviso de radares",
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: StopDriveIntent(),
            phrases: ["Parar aviso de radares en \(.applicationName)"],
            shortTitle: "Parar aviso de radares",
            systemImageName: "car"
        )
    }
}
