// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The six launch steps of design 3.3, in didFinishLaunching, before any window. No branch on the deprecated
// location launch option: the reason is derived from the first event that arrives (logged by whoever receives it).

import RadaresCore
import UIKit
import UserNotifications
import os

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "launch")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let launchState: LaunchState = switch application.applicationState {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .background
        }

        // 1. Re-take the Always session (created in the coordinator's init, so touching `shared` is the first
        //    statement), start the wake-ups, and in the background start the stream first, then probe.
        let coordinator = LocationCoordinator.shared
        Task { await coordinator.bootstrap(state: application.applicationState) }

        // The folder every lane writes to, with its protection class, before anything is written into it.
        FileStore.shared.prepareFolder()

        // 2. Must be registered before launch finishes.
        FeedRefresher.shared.registerBackgroundTask()

        // 3.
        UNUserNotificationCenter.current().delegate = Notifier.shared

        // 4. The store loads off the main thread; the bundled snapshot is copied in when no feed exists yet.
        Task.detached(priority: .utility) {
            await CurrentFeed.shared.loadIfNeeded()
        }

        // The one setting the surfaces read (design 1): voice on unless the driver turned it off.
        AlertDispatcher.shared.voiceEnabled = UserDefaults.standard.object(forKey: SettingsKey.voiceEnabled) as? Bool ?? true

        // 5. Adopt a Live Activity that survived a relaunch, end anything older.
        DriveActivityController.shared.reattach()

        // 6. The reason stays `unknown` until the first event tells it.
        AppLog.shared.post(.launch(reason: .unknown, state: launchState))
        logger.info("launched, state \(launchState.rawValue, privacy: .public)")
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // The process is being ended while running (a swipe in the switcher, or the system ending a running
        // background app): Estado turns red until the next launch (design 6, "Arranques solos").
        AppLog.shared.post(.willTerminate)
    }
}
