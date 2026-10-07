// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the screens show, in one observable place: the loaded feed, the Estado rows, the recent alerts, and the
// foreground hooks (refresh on open, the test drive launch argument, the Live Activity when a drive is running).

import CoreLocation
import Observation
import RadaresCore
import SwiftUI
import UserNotifications
import os

/// Launch arguments for the simulator scripts (`scripts/sim-drive.sh`): `-StartDriveForTest 1` starts a test drive
/// in the foreground so the Live Activity exists, `-NoLiveActivity 1` keeps the Live Activity off so the Time
/// Sensitive notification is the visible surface, `-ProvisionalNotifications 1` takes provisional notification
/// authorization (no prompt; the Simulator cannot grant notifications any other way) so that surface can post.
/// `-InitialTab mapa` (or `ajustes`) opens on that tab, so a script can screenshot every tab without tapping, and
/// `-RunSelfTest 1` presses "Probar aviso" once.
enum LaunchFlags {
    static var initialTab: String? { UserDefaults.standard.string(forKey: "InitialTab") }
    /// `-RunSelfTest 1` runs "Probar aviso" on the first foreground, as the button would.
    static var runSelfTest: Bool { UserDefaults.standard.bool(forKey: "RunSelfTest") }
    static var startDriveForTest: Bool { UserDefaults.standard.bool(forKey: "StartDriveForTest") }
    static var noLiveActivity: Bool { UserDefaults.standard.bool(forKey: "NoLiveActivity") }
    static var provisionalNotifications: Bool { UserDefaults.standard.bool(forKey: "ProvisionalNotifications") }
}

/// UserDefaults keys the app lane owns.
enum SettingsKey {
    static let onboardingDone = "onboardingDone"
    static let warningsEnabled = "warningsEnabled"
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var store: RadarStore?
    private(set) var report: [HealthItem] = []
    private(set) var meta = FeedMeta()
    private(set) var lastBackgroundLaunch: Date?
    private(set) var recentAlerts: [LogEntry] = []
    private(set) var refreshing = false
    private(set) var selfTest: SelfTest.Outcome?
    private(set) var selfTestRunning = false
    /// The engine's view while a drive is on (design 4.4: the next-radar card reads it); nil when idle.
    private(set) var driveSnapshot: DriveSnapshot?
    var showOnboarding = !UserDefaults.standard.bool(forKey: SettingsKey.onboardingDone)
    var selectedTab = LaunchFlags.initialTab.flatMap(Tab.init(rawValue:)) ?? .estado

    enum Tab: String, Hashable { case estado, mapa, ajustes }

    /// One retained manager for reading the last known position (map, nearest radar, self-test); it never
    /// starts a location service.
    static let locationManager = CLLocationManager()

    static var lastKnown: Coordinate? {
        locationManager.location.map { Coordinate($0.coordinate) }
    }

    private var startedTestDrive = false
    private var ranLaunchSelfTest = false
    private var stateWatcher: Task<Void, Never>?
    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "ui")

    private init() {}

    /// The worst row of Estado, for the strip above the map.
    var overall: HealthItem.Status {
        if report.contains(where: { $0.status == .fail }) { return .fail }
        if report.contains(where: { $0.status == .warn }) { return .warn }
        return .ok
    }

    /// Re-reads the feed, the health inputs and the log.
    func reload() async {
        store = await CurrentFeed.shared.loadIfNeeded()
        if let current = CurrentFeed.shared.store { store = current }
        meta = FileStore.shared.readMeta()
        report = healthReport(await HealthMonitor().collect(), locale: .autoupdatingCurrent)
        lastBackgroundLaunch = await HealthMonitor.lastBackgroundLaunch()
        await refreshDriveSnapshot()
        let since = Date().addingTimeInterval(-Thresholds.alertHistoryHours * 3600)
        recentAlerts = await AppLog.shared.recent(Thresholds.logMaxLines).filter { entry in
            guard entry.t >= since, case .alert = entry.event else { return false }
            return true
        }.reversed()
    }

    /// The engine's snapshot, cheap enough for the map to poll while it is on screen.
    func refreshDriveSnapshot() async {
        driveSnapshot = await LocationCoordinator.shared.snapshot
    }

    /// "Actualizar ahora".
    func refreshFeed() async {
        refreshing = true
        await FeedRefresher.shared.refreshNow()
        refreshing = false
        await reload()
    }

    /// Every time the scene becomes active: the foreground refresh (design 5.2), the test drive argument once, the
    /// drive itself under While Using only (design 3.4: the foreground is the one start iOS allows there), and the
    /// Live Activity for a drive that is already running (design 4.2, way 2).
    func didBecomeActive() async {
        // A scene is up: this launch was the user's (design 3.3, step 6), unless an event already named it.
        await LocationCoordinator.shared.noteSceneConnected()
        watchDriveState()
        await LocationCoordinator.shared.startForegroundDriveIfWanted()
        if LaunchFlags.provisionalNotifications,
           await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional])
        }
        if !startedTestDrive, LaunchFlags.startDriveForTest {
            startedTestDrive = true
            logger.info("starting a test drive (-StartDriveForTest)")
            await LocationCoordinator.shared.startDrive(reason: .test)
        }
        await ensureActivityIfDriving()
        await reload()
        if !ranLaunchSelfTest, LaunchFlags.runSelfTest {
            ranLaunchSelfTest = true
            await runSelfTest()
        }
        await FeedRefresher.shared.refreshIfNeeded(trigger: .foreground)
        await reload()
    }

    /// A drive that begins while the app is open (a wake-up's probe that was already running when the user opened
    /// the app) gets its Live Activity from the foreground (design 4.2). The
    /// coordinator's stream has one consumer: this one.
    private func watchDriveState() {
        guard stateWatcher == nil else { return }
        stateWatcher = Task { [weak self] in
            for await state in LocationCoordinator.shared.stateChanges {
                guard state.isDriveOn, UIApplication.shared.applicationState == .active else { continue }
                await self?.ensureActivityIfDriving()
            }
        }
    }

    func ensureActivityIfDriving() async {
        guard !LaunchFlags.noLiveActivity, DriveActivityController.shared.current == nil else { return }
        let state = await LocationCoordinator.shared.state
        guard let content = Self.activityStartContent(for: state, paused: { await LocationCoordinator.shared.pausedContent }) else { return }
        do {
            try DriveActivityController.shared.start(content: await content())
        } catch {
            logger.error("Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The first card of a Live Activity started from the foreground: the idle card while driving, the paused card
    /// (phase `.paused`, 15 min stale, "En pausa") while paused, since nothing updates the card until the car moves.
    nonisolated static func activityStartContent(for state: DriveState, paused: @escaping @Sendable () async -> DriveContent) -> (@Sendable () async -> DriveContent)? {
        switch state {
        case .driving: { .watching(at: Date()) }
        case .paused: paused
        case .idle, .probing: nil
        }
    }

    /// "Probar aviso".
    func runSelfTest() async {
        selfTestRunning = true
        selfTest = await SelfTest.run()
        selfTestRunning = false
        await reload()
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: SettingsKey.onboardingDone)
        showOnboarding = false
    }

    func perform(_ action: HealthItem.Action) {
        switch action {
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .refreshFeed:
            Task { await refreshFeed() }
        case .openOnboarding:
            showOnboarding = true
        }
    }
}

extension HealthItem.Status {
    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .fail: .red
        }
    }

    var label: Text {
        switch self {
        case .ok: Text("Bien")
        case .warn: Text("Revisar")
        case .fail: Text("Falla")
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        }
    }
}

extension Kind {
    /// The name shown on the map and in the lists.
    var label: LocalizedStringKey {
        switch self {
        case .fixed: "Radar fijo"
        case .section: "Radar de tramo"
        case .stretch: "Tramo"
        case .mobileAnnounced: "Radar móvil anunciado"
        case .mobileRecurring: "Radar móvil habitual"
        case .trailer: "Radar en remolque"
        case .reported: "Sin confirmar"
        }
    }

    var symbol: String {
        switch self {
        case .fixed: "camera.fill"
        case .section, .stretch: "road.lanes"
        case .mobileAnnounced: "car.side.fill"
        case .mobileRecurring: "car.side"
        case .trailer: "truck.box.fill"
        case .reported: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .fixed: .red
        case .section, .stretch: .orange
        case .mobileAnnounced, .mobileRecurring: .blue
        case .trailer: .purple
        case .reported: .gray
        }
    }
}

extension Coordinate {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    init(_ c: CLLocationCoordinate2D) {
        self.init(latitude: c.latitude, longitude: c.longitude)
    }
}
