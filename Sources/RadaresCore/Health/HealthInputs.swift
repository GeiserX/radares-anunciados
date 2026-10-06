// Lane: frozen (orchestrator)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One row of the Estado screen. `healthReport(_:)` in the core builds them from `HealthInputs`.
public struct HealthItem: Sendable, Codable, Hashable, Identifiable {
    public enum Status: String, Sendable, Codable, Hashable {
        case ok
        case warn
        case fail
    }

    /// What the row's button does, if it has one.
    public enum Action: String, Sendable, Codable, Hashable {
        case openSettings
        case refreshFeed
        case showAutomationRecipe
        case openOnboarding
    }

    public var status: Status
    public var title: String
    public var detail: String
    public var action: Action?

    public var id: String { title }

    public init(status: Status, title: String, detail: String, action: Action? = nil) {
        self.status = status
        self.title = title
        self.detail = detail
        self.action = action
    }
}

/// Everything the Estado rules need, collected by the app lane's `HealthMonitor` from the system APIs and the
/// log, and consumed by the pure `healthReport(_:)` in the core. Every field has a default so a test sets only
/// what its rule reads. Enum mirrors of system types keep the core free of UIKit, Core Location and friends.
public struct HealthInputs: Sendable, Codable, Hashable {
    public enum LocationAuthorization: String, Sendable, Codable, Hashable {
        case notDetermined, restricted, denied, whenInUse, always
    }

    public enum MotionAuthorization: String, Sendable, Codable, Hashable {
        case notDetermined, restricted, denied, authorized
    }

    public enum NotificationAuthorization: String, Sendable, Codable, Hashable {
        case notDetermined, denied, authorized, provisional, ephemeral
    }

    /// `UNNotificationSetting`.
    public enum NotificationSetting: String, Sendable, Codable, Hashable {
        case notSupported, disabled, enabled
    }

    /// `UIBackgroundRefreshStatus`.
    public enum BackgroundRefreshStatus: String, Sendable, Codable, Hashable {
        case available, denied, restricted
    }

    /// The eight `CLServiceSession.Diagnostic` flags (design 3.2).
    public struct SessionDiagnostics: Sendable, Codable, Hashable {
        public var alwaysAuthorizationDenied = false
        public var authorizationDenied = false
        public var authorizationDeniedGlobally = false
        public var authorizationRestricted = false
        public var fullAccuracyDenied = false
        public var insufficientlyInUse = false
        public var authorizationRequestInProgress = false
        public var serviceSessionRequired = false

        public init() {}
    }

    public var now: Date

    // Ubicación
    public var locationAuthorization: LocationAuthorization
    public var preciseLocation: Bool

    // Sesión Siempre
    public var sessionDiagnostics: SessionDiagnostics
    /// False until `sessionTaken` has been logged in this process.
    public var sessionTaken: Bool

    // Arranques solos (last `Thresholds.healthWindowDays`)
    public var backgroundLaunches: Int
    public var intentLaunches: Int
    public var drives: Int
    public var lastEventWasUserTerminated: Bool

    // Valla de aparcamiento
    public var parkedFenceFlags: [String]
    public var parkedFenceIdentifierPresent: Bool

    // Cambio significativo
    public var slcStarted: Bool
    public var lastSlcDelivery: Date?
    public var lastDriveEnded: Date?

    // Datos
    public var feedFetchedAt: Date?
    public var feedFeatureCount: Int
    public var feedConsecutiveFailures: Int

    // Actualización en segundo plano
    public var backgroundRefresh: BackgroundRefreshStatus
    public var pendingRefreshRequests: Int
    public var lastBgTaskRan: Date?
    public var lowPowerMode: Bool

    // Notificaciones
    public var notificationAuthorization: NotificationAuthorization
    public var timeSensitiveSetting: NotificationSetting

    // Pantalla del coche
    public var activitiesEnabled: Bool
    public var lastActivityStarted: Date?
    public var lastDriveStarted: Date?
    /// A drive started by `StartDriveIntent` has been logged at least once (the automation is proven).
    public var intentStartedDriveLogged: Bool

    // Movimiento
    public var motionAuthorization: MotionAuthorization

    // Voz
    public var lastSpeechSetActiveError: String?
    public var spanishVoiceAvailable: Bool

    // Archivos
    public var protectionVerified: Bool?

    // Último viaje
    public var lastDriveMaxGapSeconds: Double?
    public var lastDriveHadLateAlert: Bool

    public init(
        now: Date = Date(),
        locationAuthorization: LocationAuthorization = .notDetermined,
        preciseLocation: Bool = true,
        sessionDiagnostics: SessionDiagnostics = SessionDiagnostics(),
        sessionTaken: Bool = false,
        backgroundLaunches: Int = 0,
        intentLaunches: Int = 0,
        drives: Int = 0,
        lastEventWasUserTerminated: Bool = false,
        parkedFenceFlags: [String] = [],
        parkedFenceIdentifierPresent: Bool = false,
        slcStarted: Bool = false,
        lastSlcDelivery: Date? = nil,
        lastDriveEnded: Date? = nil,
        feedFetchedAt: Date? = nil,
        feedFeatureCount: Int = 0,
        feedConsecutiveFailures: Int = 0,
        backgroundRefresh: BackgroundRefreshStatus = .available,
        pendingRefreshRequests: Int = 0,
        lastBgTaskRan: Date? = nil,
        lowPowerMode: Bool = false,
        notificationAuthorization: NotificationAuthorization = .notDetermined,
        timeSensitiveSetting: NotificationSetting = .notSupported,
        activitiesEnabled: Bool = false,
        lastActivityStarted: Date? = nil,
        lastDriveStarted: Date? = nil,
        intentStartedDriveLogged: Bool = false,
        motionAuthorization: MotionAuthorization = .notDetermined,
        lastSpeechSetActiveError: String? = nil,
        spanishVoiceAvailable: Bool = true,
        protectionVerified: Bool? = nil,
        lastDriveMaxGapSeconds: Double? = nil,
        lastDriveHadLateAlert: Bool = false
    ) {
        self.now = now
        self.locationAuthorization = locationAuthorization
        self.preciseLocation = preciseLocation
        self.sessionDiagnostics = sessionDiagnostics
        self.sessionTaken = sessionTaken
        self.backgroundLaunches = backgroundLaunches
        self.intentLaunches = intentLaunches
        self.drives = drives
        self.lastEventWasUserTerminated = lastEventWasUserTerminated
        self.parkedFenceFlags = parkedFenceFlags
        self.parkedFenceIdentifierPresent = parkedFenceIdentifierPresent
        self.slcStarted = slcStarted
        self.lastSlcDelivery = lastSlcDelivery
        self.lastDriveEnded = lastDriveEnded
        self.feedFetchedAt = feedFetchedAt
        self.feedFeatureCount = feedFeatureCount
        self.feedConsecutiveFailures = feedConsecutiveFailures
        self.backgroundRefresh = backgroundRefresh
        self.pendingRefreshRequests = pendingRefreshRequests
        self.lastBgTaskRan = lastBgTaskRan
        self.lowPowerMode = lowPowerMode
        self.notificationAuthorization = notificationAuthorization
        self.timeSensitiveSetting = timeSensitiveSetting
        self.activitiesEnabled = activitiesEnabled
        self.lastActivityStarted = lastActivityStarted
        self.lastDriveStarted = lastDriveStarted
        self.intentStartedDriveLogged = intentStartedDriveLogged
        self.motionAuthorization = motionAuthorization
        self.lastSpeechSetActiveError = lastSpeechSetActiveError
        self.spanishVoiceAvailable = spanishVoiceAvailable
        self.protectionVerified = protectionVerified
        self.lastDriveMaxGapSeconds = lastDriveMaxGapSeconds
        self.lastDriveHadLateAlert = lastDriveHadLateAlert
    }
}
