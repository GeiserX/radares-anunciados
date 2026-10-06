// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The "Conducir" control for Control Center, the Lock Screen and the Action button (design 4.2): one tap runs
// StartDriveIntent, which starts the drive and the Live Activity from the app process.

import AppIntents
import SwiftUI
import WidgetKit

struct DriveControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.github.geiserx.radares.drive") {
            ControlWidgetButton(action: StartDriveIntent()) {
                Label("Conducir", systemImage: "car.fill")
            }
        }
        .displayName("Conducir")
        .description("Empieza a avisar de los radares anunciados.")
    }
}
