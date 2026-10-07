// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// SwiftUI App with the UIKit delegate adaptor: background launches (fence exit, significant change, BG task)
// go through AppDelegate before any scene exists (design 3.3).

import RadaresCore
import SwiftUI

@main
struct RadaresApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppModel.shared)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Design 5.2: on every foreground, refresh if the feed is older than Thresholds.refreshForegroundHours;
            // design 4.2: the Live Activity for a drive already running; the -StartDriveForTest argument.
            Task { await AppModel.shared.didBecomeActive() }
        }
    }
}
