// Lane: frozen (orchestrator)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Which system-persisted wake-up brought the app back (design 3.1).
public enum WakeSource: String, Sendable, Codable, Hashable {
    /// The parked fence, `CLMonitor("radares.wake")`.
    case monitor
    /// Significant-change location.
    case slc
}

/// Why a drive started. Logged as-is; the location lane's `startDrive(reason:)` takes it.
/// Lives in the core (not the location lane, as section 9 lists it) because the log row carries it.
public enum DriveReason: Sendable, Codable, Hashable {
    /// The app opened at drive start (or a drive begun from the UI).
    case foreground
    /// "Probar aviso".
    case test
    /// A background wake-up followed by a positive probe.
    case wakeup(WakeSource)
}

/// How the launch reason is known: from the first thing that arrives after launch, never from a launch option (design 3.3).
public enum LaunchReason: String, Sendable, Codable, Hashable {
    case monitorEvent
    case slc
    case liveUpdate
    case bgTask
    case scene
    case unknown

    /// A launch iOS did on its own, without the user: counts as "Arranques solos".
    public var isBackgroundLaunch: Bool {
        switch self {
        case .monitorEvent, .slc, .liveUpdate, .bgTask: true
        case .scene, .unknown: false
        }
    }
}

/// `UIApplication.State` at launch, as a string so the core stays UIKit-free.
public enum LaunchState: String, Sendable, Codable, Hashable {
    case active
    case inactive
    case background
}

/// Whether the process that spoke was launched in the foreground or purely in the background (design 4.1).
public enum LaunchContext: String, Sendable, Codable, Hashable {
    case foreground
    case background
}

/// What the probe decided (design 3.1, `.probing`).
public enum ProbeResult: String, Sendable, Codable, Hashable {
    case driving
    case idle
    case timeout
}

/// Why a stretch was left (design 2.5).
public enum StretchExitReason: String, Sendable, Codable, Hashable {
    case farGate
    case distance
    case time
    case driveEnd
}

/// One delivery path and whether it took the alert.
public struct SinkOutcome: Sendable, Codable, Hashable {
    public enum Sink: String, Sendable, Codable, Hashable {
        case speech
        case notification
    }

    public var sink: Sink
    public var ok: Bool
    public var detail: String?

    public init(sink: Sink, ok: Bool, detail: String? = nil) {
        self.sink = sink
        self.ok = ok
        self.detail = detail
    }
}

/// Every kind of row in `events.jsonl` (design 6). Associated values are the row's data.
/// No user coordinates beyond the alert rows, which the user can wipe.
public enum LogEvent: Sendable, Codable, Hashable {
    case launch(reason: LaunchReason, state: LaunchState)
    case sessionTaken
    case wakeup(source: WakeSource, flags: [String])
    case probe(result: ProbeResult, motion: Bool?, maxSpeedMps: Double?, seconds: Double)
    case driveStarted(reason: DriveReason)
    /// One every `Thresholds.fixLogSeconds`, not every fix.
    case fix(speedMps: Double?, horizontalAccuracy: Double, isStationary: Bool)
    case alert(
        id: String,
        level: Level,
        distance: Double,
        speedMps: Double?,
        late: Bool,
        crossTrackMetres: Double?,
        suppressedByDirection: Bool,
        coordinate: Coordinate,
        sinks: [SinkOutcome],
        /// The sentence spoken for a `.full` alert, nil for `.visual`: the row is the evidence of what the driver heard.
        spoken: String? = nil
    )
    case passed(id: String)
    case stretchEntered(id: String)
    case stretchExited(id: String, reason: StretchExitReason)
    case drivePaused
    case driveResumed(pausedSeconds: Double)
    case driveEnded(fixes: Int, maxGapSeconds: Double, alerts: Int, firstFixAfterWakeS: Double?, firstWarnAfterWakeM: Double?)
    case feedChecked(etag: String?, notModified: Bool)
    case feedUpdated(count: Int, etag: String?)
    case feedFailed(error: String)
    case bgTaskRan(expired: Bool)
    case notificationPosted(id: String, error: String?)
    case speech(route: String, setActiveError: String?, finished: Bool, launchContext: LaunchContext)
    case monitorEvent(identifier: String, state: String, flags: [String])
    case protectionVerified(ok: Bool)
    /// From `applicationWillTerminate`: the process was ended while running, by the user swiping it away or by the
    /// system terminating a running background app. Either way the chain was cut, and no background launch is
    /// possible until something restarts the app; the health rule reads it as that, not as proof of a swipe.
    case willTerminate
}

/// One line of the log: the time and the event. `EventLog.recent` returns these, so health rules can reason about time.
public struct LogEntry: Sendable, Codable, Hashable {
    public var t: Date
    public var event: LogEvent

    public init(t: Date, event: LogEvent) {
        self.t = t
        self.event = event
    }
}
