// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the screens show, in one observable place: the loaded feed, the Estado rows, the recent alerts, and the
// foreground hooks (refresh on open, the test drive launch argument, the Live Activity when a drive is running).

import CoreLocation
import Observation
import RadaresCore
import SwiftUI
import os

/// Launch arguments for the simulator scripts (`scripts/sim-drive.sh`): `-StartDriveForTest 1` starts a test drive
/// in the foreground so the Live Activity exists, `-NoLiveActivity 1` keeps the Live Activity off so the Time
/// Sensitive notification is the visible surface.
enum LaunchFlags {
    static var startDriveForTest: Bool { UserDefaults.standard.bool(forKey: "StartDriveForTest") }
    static var noLiveActivity: Bool { UserDefaults.standard.bool(forKey: "NoLiveActivity") }
}

/// UserDefaults keys the app lane owns.
enum SettingsKey {
    static let onboardingDone = "onboardingDone"
    static let voiceEnabled = "voiceEnabled"
    static let warningsEnabled = "warningsEnabled"
    /// Seconds since 1970 until which the driver paused warnings ("Pausar hoy"); 0 when not paused.
    static let pausedUntil = "pausedUntil"
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
    var showOnboarding = !UserDefaults.standard.bool(forKey: SettingsKey.onboardingDone)
    var showRecipe = false
    var selectedTab = Tab.estado

    enum Tab: Hashable { case estado, mapa, ajustes }

    private var startedTestDrive = false
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
        report = healthReport(await HealthMonitor().collect())
        lastBackgroundLaunch = await HealthMonitor.lastBackgroundLaunch()
        let since = Date().addingTimeInterval(-Thresholds.alertHistoryHours * 3600)
        recentAlerts = await AppLog.shared.recent(Thresholds.logMaxLines).filter { entry in
            guard entry.t >= since, case .alert = entry.event else { return false }
            return true
        }.reversed()
    }

    /// "Actualizar ahora".
    func refreshFeed() async {
        refreshing = true
        await FeedRefresher.shared.refreshNow()
        refreshing = false
        await reload()
    }

    /// Every time the scene becomes active: the foreground refresh (design 5.2), the test drive argument once, and
    /// the Live Activity for a drive that is already running (design 4.2, way 2).
    func didBecomeActive() async {
        if !startedTestDrive, LaunchFlags.startDriveForTest {
            startedTestDrive = true
            logger.info("starting a test drive (-StartDriveForTest)")
            await LocationCoordinator.shared.startDrive(reason: .test)
        }
        await ensureActivityIfDriving()
        await reload()
        await FeedRefresher.shared.refreshIfNeeded(trigger: .foreground)
        await reload()
    }

    func ensureActivityIfDriving() async {
        guard !LaunchFlags.noLiveActivity, DriveActivityController.shared.current == nil else { return }
        switch await LocationCoordinator.shared.state {
        case .driving, .paused:
            do {
                try DriveActivityController.shared.start(content: .watching(at: Date()))
            } catch {
                logger.error("Live Activity: \(error.localizedDescription, privacy: .public)")
            }
        case .idle, .probing:
            break
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
        case .showAutomationRecipe:
            showRecipe = true
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
        case .trailer: "Radar en remolque"
        case .reported: "Sin confirmar"
        }
    }

    var symbol: String {
        switch self {
        case .fixed: "camera.fill"
        case .section, .stretch: "road.lanes"
        case .mobileAnnounced: "car.side.fill"
        case .trailer: "truck.box.fill"
        case .reported: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .fixed: .red
        case .section, .stretch: .orange
        case .mobileAnnounced: .blue
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
