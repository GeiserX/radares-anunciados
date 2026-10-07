// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The five launch steps of design 3.3, in didFinishLaunching, before any window. No branch on the deprecated
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
        // The one rule for "is this a background wake", applied here and in the coordinator: `applicationState`
        // reads `.background` inside didFinishLaunching on every launch, a user's included, so it decides nothing.
        // A launch is a background wake when iOS passed the location launch key (a hint; the event itself arrives
        // through the monitor or the significant-change delegate), and the first thing that arrives afterwards
        // names the launch: a scene connecting (`noteSceneConnected`) marks a user launch.
        let launchedInBackground = Self.launchedForLocation(launchOptions)
        let launchState: LaunchState = launchedInBackground ? .background : .inactive

        // 1. Re-take the Always session (created in the coordinator's init, so touching `shared` is the first
        //    statement), start the wake-ups, and in the background start the stream first, then probe.
        let coordinator = LocationCoordinator.shared
        Task { await coordinator.bootstrap(launchedInBackground: launchedInBackground) }

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

        // The surfaces' own launch-argument self-test (-SurfacesSelfTest), a no-op on a normal launch.
        AlertDispatcher.runSelfTestIfRequested()

        // 5. The reason stays `unknown` until the first event tells it.
        AppLog.shared.post(.launch(reason: .unknown, state: launchState))
        logger.info("launched, state \(launchState.rawValue, privacy: .public)")
        return true
    }

    /// `UIApplicationLaunchOptionsLocationKey`, by its raw name: the typed key is deprecated as of iOS 26 and is
    /// read only as an informational hint (design 3.3), never as the event.
    nonisolated static func launchedForLocation(_ options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        options?[UIApplication.LaunchOptionsKey(rawValue: "UIApplicationLaunchOptionsLocationKey")] != nil
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // The process is being ended while running (a swipe in the switcher, or the system ending a running
        // background app): Estado turns red until the next launch (design 6, "Arranques solos").
        AppLog.shared.post(.willTerminate)
    }
}
