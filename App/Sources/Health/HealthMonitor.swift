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

        // Ubicación, Sesión Siempre, Valla, Cambio significativo, Movimiento: what the location lane owns, from the
        // coordinator. The session diagnostics arrive on a stream, so until the first one lands the status-derived
        // flags stand in; a flag set on either side is red.
        let location = await LocationCoordinator.shared.healthSnapshot()
        inputs.locationAuthorization = location.authorization
        inputs.preciseLocation = location.preciseLocation
        inputs.sessionDiagnostics = Self.merge(
            location.sessionDiagnostics,
            authorization: location.authorization,
            precise: location.preciseLocation,
            servicesEnabled: await Task.detached { CLLocationManager.locationServicesEnabled() }.value
        )
        inputs.sessionTaken = location.sessionTaken
        inputs.parkedFenceIdentifierPresent = location.parkedFenceIdentifierPresent
        inputs.parkedFenceFlags = location.parkedFenceFlags
        inputs.slcStarted = location.slcStarted
        inputs.lastSlcDelivery = location.lastSlcDelivery
        inputs.motionAuthorization = location.motionAuthorization

        let window = now.addingTimeInterval(-Thresholds.healthWindowDays * 86_400)
        // This process's rows: from the delegate's launch row (reason `unknown`; a derived reason comes as a later
        // row), with a few seconds of slack because the lanes post from concurrent tasks and the order is not fixed.
        let launchRow = log.last { if case .launch(.unknown, _) = $0.event { true } else { false } }
        let processStart = launchRow.map { $0.t.addingTimeInterval(-Self.launchSlackSeconds) } ?? .distantPast

        // Arranques solos. A launch row whose reason was derived later is logged again by whoever saw the first event.
        for entry in log where entry.t >= window {
            switch entry.event {
            case let .launch(reason, _):
                if reason.isBackgroundLaunch { inputs.backgroundLaunches += 1 }
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

        // The log carries what earlier processes saw: the last parked-fence event's flags and the last
        // significant-change delivery, which the 14-day rule needs across launches.
        for entry in log {
            switch entry.event {
            case let .monitorEvent(identifier, _, flags) where identifier == "parked":
                inputs.parkedFenceFlags = flags
            case .wakeup(source: .slc, _):
                if inputs.lastSlcDelivery.map({ entry.t > $0 }) ?? true { inputs.lastSlcDelivery = entry.t }
            case let .driveEnded(_, maxGap, _, _, _):
                inputs.lastDriveEnded = entry.t
                inputs.lastDriveMaxGapSeconds = maxGap
            case .driveStarted:
                inputs.lastDriveStarted = entry.t
                inputs.lastDriveHadLateAlert = false
            case let .alert(_, _, _, _, late, _, _, _, _, _) where late:
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

        // Pantalla del coche, Voz.
        inputs.activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        inputs.spanishVoiceAvailable = AVSpeechSynthesisVoice(language: "es-ES") != nil

        // Archivos: the logged read-back, else a read-back now.
        if inputs.protectionVerified == nil, FileManager.default.fileExists(atPath: AppPaths.feed.path) {
            inputs.protectionVerified = FileStore.shared.verifyProtection()
        }
        return inputs
    }

    /// The session's own diagnostics, with the flags the authorization status already proves: a goal of Always
    /// with only When In Use granted is `alwaysAuthorizationDenied` whether or not the stream has said so yet.
    nonisolated static func merge(
        _ reported: HealthInputs.SessionDiagnostics,
        authorization: HealthInputs.LocationAuthorization,
        precise: Bool,
        servicesEnabled: Bool
    ) -> HealthInputs.SessionDiagnostics {
        var d = reported
        d.alwaysAuthorizationDenied = d.alwaysAuthorizationDenied || authorization == .whenInUse
        d.authorizationDenied = d.authorizationDenied || authorization == .denied
        d.authorizationRestricted = d.authorizationRestricted || authorization == .restricted
        d.fullAccuracyDenied = d.fullAccuracyDenied || !precise
        d.authorizationDeniedGlobally = d.authorizationDeniedGlobally || !servicesEnabled
        return d
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
