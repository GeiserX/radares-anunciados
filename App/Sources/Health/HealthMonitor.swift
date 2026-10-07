// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Collects HealthInputs from Core Location, the session diagnostics, UserNotifications, ActivityKit, Core Motion,
// BGTaskScheduler, feed.meta.json and the log (design 6). The rules themselves are healthReport(_:) in the core.

import ActivityKit
import AVFAudio
@preconcurrency import BackgroundTasks
import CoreLocation
import CoreMotion
import Foundation
import RadaresCore
import UIKit
import UserNotifications

@MainActor
public final class HealthMonitor {
    /// Rows logged this long before the launch row still belong to this process.
    static let launchSlackSeconds: TimeInterval = 5

    public init() {}

    public func collect() async -> HealthInputs {
        let now = Date()
        let log = await AppLog.shared.recent(Thresholds.logMaxLines)
        var inputs = HealthInputs(now: now)

        // Ubicación and Sesión Siempre. The diagnostics are derived from the authorization the session would report:
        // the session object itself belongs to the location lane and is never touched from here.
        let manager = CLLocationManager()
        inputs.locationAuthorization = Self.map(manager.authorizationStatus)
        inputs.preciseLocation = manager.accuracyAuthorization == .fullAccuracy
        var diagnostics = HealthInputs.SessionDiagnostics()
        diagnostics.alwaysAuthorizationDenied = inputs.locationAuthorization == .whenInUse
        diagnostics.authorizationDenied = inputs.locationAuthorization == .denied
        diagnostics.authorizationRestricted = inputs.locationAuthorization == .restricted
        diagnostics.fullAccuracyDenied = !inputs.preciseLocation
        diagnostics.authorizationDeniedGlobally = await Task.detached { !CLLocationManager.locationServicesEnabled() }.value
        inputs.sessionDiagnostics = diagnostics

        let window = now.addingTimeInterval(-Thresholds.healthWindowDays * 86_400)
        // This process's rows: from the delegate's launch row (reason `unknown`; a derived reason comes as a later
        // row), with a few seconds of slack because the lanes post from concurrent tasks and the order is not fixed.
        let launchRow = log.last { if case .launch(.unknown, _) = $0.event { true } else { false } }
        let processStart = launchRow.map { $0.t.addingTimeInterval(-Self.launchSlackSeconds) } ?? .distantPast
        inputs.sessionTaken = log.contains { $0.t >= processStart && $0.event == .sessionTaken }

        // Arranques solos. A launch row whose reason was derived later is logged again by whoever saw the first event.
        for entry in log where entry.t >= window {
            switch entry.event {
            case let .launch(reason, _):
                if reason.isBackgroundLaunch { inputs.backgroundLaunches += 1 }
                if reason == .intent { inputs.intentLaunches += 1 }
            case .driveStarted:
                inputs.drives += 1
            default:
                break
            }
        }
        // The previous process's last row: it was ended while running.
        if launchRow != nil {
            inputs.lastEventWasWillTerminate = log.last { $0.t < processStart }?.event == .willTerminate
        }

        // Valla de aparcamiento and Cambio significativo, from what the location lane logged.
        for entry in log {
            switch entry.event {
            case let .monitorEvent(identifier, _, flags) where identifier == "parked":
                inputs.parkedFenceFlags = flags
                inputs.parkedFenceIdentifierPresent = true
            case .wakeup(source: .slc, _):
                inputs.lastSlcDelivery = entry.t
            case let .driveEnded(_, maxGap, _, _, _):
                inputs.lastDriveEnded = entry.t
                inputs.lastDriveMaxGapSeconds = maxGap
            case let .driveStarted(reason):
                inputs.lastDriveStarted = entry.t
                if reason == .intent { inputs.intentStartedDriveLogged = true }
                inputs.lastDriveHadLateAlert = false
            case let .alert(_, _, _, _, late, _, _, _, _) where late:
                inputs.lastDriveHadLateAlert = true
            case .bgTaskRan:
                inputs.lastBgTaskRan = entry.t
            case .activityStarted:
                inputs.lastActivityStarted = entry.t
            case let .speech(_, setActiveError, _, _):
                inputs.lastSpeechSetActiveError = setActiveError
            case let .protectionVerified(ok):
                inputs.protectionVerified = ok
            default:
                break
            }
        }
        let authorized = inputs.locationAuthorization == .always || inputs.locationAuthorization == .whenInUse
        inputs.slcStarted = authorized && CLLocationManager.significantLocationChangeMonitoringAvailable()

        // Datos.
        let meta = FileStore.shared.readMeta()
        inputs.feedFetchedAt = meta.fetchedAt
        inputs.feedFeatureCount = meta.featureCount
        inputs.feedConsecutiveFailures = meta.consecutiveFailures

        // Actualización en segundo plano.
        inputs.backgroundRefresh = switch UIApplication.shared.backgroundRefreshStatus {
        case .available: .available
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
        inputs.pendingRefreshRequests = await BGTaskScheduler.shared.pendingTaskRequests()
            .filter { $0.identifier == FeedRefresher.taskIdentifier }.count
        inputs.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        // Notificaciones.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        inputs.notificationAuthorization = Self.map(settings.authorizationStatus)
        inputs.timeSensitiveSetting = switch settings.timeSensitiveSetting {
        case .notSupported: .notSupported
        case .disabled: .disabled
        case .enabled: .enabled
        @unknown default: .disabled
        }

        // Pantalla del coche, Movimiento, Voz.
        inputs.activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        inputs.motionAuthorization = Self.map(CMMotionActivityManager.authorizationStatus())
        inputs.spanishVoiceAvailable = AVSpeechSynthesisVoice(language: "es-ES") != nil

        // Archivos: the logged read-back, else a read-back now.
        if inputs.protectionVerified == nil, FileManager.default.fileExists(atPath: AppPaths.feed.path) {
            inputs.protectionVerified = FileStore.shared.verifyProtection()
        }
        return inputs
    }

    static func map(_ status: CLAuthorizationStatus) -> HealthInputs.LocationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorizedWhenInUse: .whenInUse
        case .authorizedAlways: .always
        @unknown default: .denied
        }
    }

    static func map(_ status: CMAuthorizationStatus) -> HealthInputs.MotionAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .denied
        }
    }

    static func map(_ status: UNAuthorizationStatus) -> HealthInputs.NotificationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .denied
        }
    }

    /// The newest background launch in the log, for "último arranque en segundo plano" (design 3.4).
    public static func lastBackgroundLaunch() async -> Date? {
        await AppLog.shared.recent(Thresholds.logMaxLines).last { entry in
            if case let .launch(reason, _) = entry.event { reason.isBackgroundLaunch } else { false }
        }?.t
    }
}
