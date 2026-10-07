// Lane: location
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The one owner of location state (design 3): idle, probing, driving, paused(since:). Holds the Always
// CLServiceSession, re-taken in `init` so that touching `shared` as the first statement of didFinishLaunching
// re-takes it within the first second of every launch; the wake-ups; the motion gate; the drive session.
// `bootstrap(state:)` runs from didFinishLaunching: a persisted drive resumes its loop, a background launch while
// idle starts the stream first and then probes, a foreground launch waits for the user or an intent.
//
// What the app and surfaces lanes call: `startDrive(reason:)` (the intent, the UI, "Probar aviso"), `stopDrive()`,
// `setWarningsEnabled(_:)` (onboarding after the Always grant, and the "Avisos" switch), `requestAuthorization()`
// (onboarding screen 1), `noteSceneConnected()` (the launch reason when a scene is the first arrival),
// `healthSnapshot()` (the Estado inputs this lane owns) and `stateChanges` (the UI's view of the state).

import CoreLocation
import Foundation
import RadaresCore
import UIKit
import os

public enum DriveState: Sendable, Hashable {
    case idle
    case probing
    case driving
    case paused(since: Date)

    public var isDriveOn: Bool {
        switch self {
        case .driving, .paused: true
        case .idle, .probing: false
        }
    }
}

/// The Estado inputs this lane owns (design 6, rows Ubicación, Sesión Siempre, Valla, Cambio significativo, Movimiento).
public struct LocationHealth: Sendable, Hashable {
    public var authorization: HealthInputs.LocationAuthorization
    public var preciseLocation: Bool
    public var sessionDiagnostics: HealthInputs.SessionDiagnostics
    public var sessionTaken: Bool
    public var parkedFenceFlags: [String]
    public var parkedFenceIdentifierPresent: Bool
    public var slcStarted: Bool
    public var lastSlcDelivery: Date?
    public var motionAuthorization: HealthInputs.MotionAuthorization
    public var state: DriveState
    public var launchReason: LaunchReason
}

public actor LocationCoordinator {
    public static let shared = LocationCoordinator()

    /// UserDefaults: the user granted Always and wants warnings; the session is re-taken at every launch while set.
    public static let wantsAlwaysKey = "wantsAlways"
    /// UserDefaults: "Pausar hoy" (design 3.5): until this date no wake-up starts a probe. The control and the
    /// shortcut still start a drive, the user asked for those.
    public static let pausedUntilKey = "pausedUntil"
    private static let fenceCenterKey = "fence.center"
    /// While paused and not stationary, the walking check runs at most this often.
    private static let pausedMotionCheckSeconds: Double = 30

    public private(set) var state: DriveState = .idle
    public private(set) var wantsAlways: Bool
    public private(set) var sessionTaken = false
    public private(set) var sessionDiagnostics = HealthInputs.SessionDiagnostics()
    public private(set) var launchReason: LaunchReason = .unknown
    public private(set) var launchedInBackground = false
    public private(set) var lastWakeSource: WakeSource?
    /// The flags of the last live update that changed them (design 3.2).
    public private(set) var updateFlags: [String] = []

    /// Every state change, for the UI. The latest value is `state`.
    public nonisolated let stateChanges: AsyncStream<DriveState>
    private nonisolated let stateContinuation: AsyncStream<DriveState>.Continuation

    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "location")
    private let defaults = UserDefaults.standard
    private let motionGate = MotionGate()
    private let driveSession: DriveSession
    private var wakeUps: WakeUps?
    private var alwaysSession: CLServiceSession?
    private var diagnosticsTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var probe: Probe?
    private var launchState: LaunchState = .active
    private var launchedAt = Date()
    private var bootstrapped = false
    private var lastFix: Fix?
    private var slowSince: Date?
    private var lastPausedMotionCheck: Date?

    private struct Probe {
        var startedAt: Date
        var wake: WakeSource?
        var wakeAt: Date?
        var fastFixes = 0
        var maxSpeed: Double?
        var motion: Bool?
        var timeoutTask: Task<Void, Never>?
        var motionTask: Task<Void, Never>?
    }

    private init() {
        (stateChanges, stateContinuation) = AsyncStream.makeStream(of: DriveState.self, bufferingPolicy: .bufferingNewest(1))
        driveSession = DriveSession()
        wantsAlways = defaults.bool(forKey: Self.wantsAlwaysKey)
        if wantsAlways {
            // Design 3.2: the first statement of every launch. Nothing here waits for a scene, a view or the network.
            alwaysSession = CLServiceSession(authorization: .always)
            sessionTaken = true
            AppLog.shared.post(.sessionTaken)
            logger.info("Always session re-taken at launch")
        } else {
            logger.info("no Always session: wantsAlways is off")
        }
    }

    // MARK: Launch (design 3.3, step 1)

    /// `launchedInBackground` is the app delegate's verdict from the location launch key (the one rule for a
    /// background wake; `applicationState` at launch is `.background` on every launch and decides nothing).
    public func bootstrap(launchedInBackground: Bool) async {
        guard !bootstrapped else { return }
        bootstrapped = true
        launchedAt = Date()
        launchState = launchedInBackground ? .background : .inactive
        self.launchedInBackground = launchedInBackground
        if let alwaysSession {
            watchDiagnostics(alwaysSession)
        }
        // The persisted drive decides the state before anything can arrive: significant change delivers its
        // first position as soon as it starts, and a wake-up that found `.idle` here would start a probe over a
        // drive that is still on.
        let saved = PersistedDrive.load(from: defaults)
        if let saved {
            lastFix = saved.lastFix
            setState(saved.pausedSince.map { .paused(since: $0) } ?? .driving)
        }
        let wakeUps = await MainActor.run {
            WakeUps(
                onMonitorEvent: { [weak self] event in await self?.monitorEvent(event) },
                onSignificantChange: { [weak self] fix in await self?.significantChange(fix) },
                onAuthorizationChange: { [weak self] status in await self?.authorizationChanged(status) }
            )
        }
        self.wakeUps = wakeUps
        if wantsAlways {
            await wakeUps.start(fenceCenter: loadFenceCenter())
        }
        logger.info("bootstrap: launch state \(self.launchState.rawValue, privacy: .public), wantsAlways \(self.wantsAlways, privacy: .public)")

        if let saved {
            // A relaunch mid-drive: the loop continues, same drive, same ledger (design 3.1, 3.4).
            await driveSession.resume(saved)
            startStream()
            logger.info("persisted drive resumed")
        } else if launchedInBackground, !pausedToday {
            // Launched in the background for a location event while idle: probe, stream first (design 3.1, 3.3).
            // (A Live Activity left by the previous process was ended at launch step 5: no drive, no card.)
            await beginProbe(wake: nil, at: launchedAt)
        }
        // `-StartDriveForTest 1` (scripts/sim-drive.sh) is the app lane's: it starts the drive when the scene
        // becomes active, where the Live Activity can be requested too.
    }

    /// The app lane calls this when a scene connects, so a user launch gets its reason (design 3.3, step 6).
    public func noteSceneConnected() {
        noteLaunchReason(.scene)
    }

    // MARK: Public controls

    /// The intent, the UI or "Probar aviso" start a drive now; a probe in progress becomes the drive.
    public func startDrive(reason: DriveReason) async {
        switch reason {
        case .intent: noteLaunchReason(.intent)
        case .foreground, .test: noteLaunchReason(.scene)
        case .wakeup: break
        }
        switch state {
        case .driving:
            return
        case .paused(let since):
            await resumeDrive(since: since, at: Date())
        case .probing:
            let wakeAt = probe?.wakeAt
            endProbe(result: .driving)
            await becomeDriving(reason: reason, wakeAt: wakeAt)
        case .idle:
            await becomeDriving(reason: reason, wakeAt: nil)
        }
    }

    /// `StopDriveIntent` and the UI: drive end, fence re-armed at the last fix, stream cancelled.
    public func stopDrive() async {
        switch state {
        case .idle:
            return
        case .probing:
            endProbe(result: .idle)
            await goIdle(rearmAt: lastFix?.coordinate)
        case .driving, .paused:
            await endDrive()
            await goIdle(rearmAt: lastFix?.coordinate)
        }
    }

    /// The "Avisos" switch (design 7): on takes the Always session (foreground) and arms the wake-ups; off
    /// invalidates the session, stops significant change, removes the fence and ends a drive in progress.
    public func setWarningsEnabled(_ on: Bool) async {
        wantsAlways = on
        defaults.set(on, forKey: Self.wantsAlwaysKey)
        if on {
            if alwaysSession == nil {
                let session = CLServiceSession(authorization: .always)
                alwaysSession = session
                sessionTaken = true
                AppLog.shared.post(.sessionTaken)
                watchDiagnostics(session)
                logger.info("Always session taken")
            }
            await wakeUps?.start(fenceCenter: loadFenceCenter())
        } else {
            switch state {
            case .idle: break
            case .probing: endProbe(result: .idle)
            case .driving, .paused: await endDrive()
            }
            setState(.idle)
            stopStream()
            diagnosticsTask?.cancel()
            diagnosticsTask = nil
            alwaysSession?.invalidate()
            alwaysSession = nil
            sessionTaken = false
            sessionDiagnostics = HealthInputs.SessionDiagnostics()
            await wakeUps?.stop()
            logger.info("warnings off: session invalidated, wake-ups stopped")
        }
    }

    /// "Pausar hoy" is on: wake-ups are ignored until the stored date (the end of the day it was switched on).
    public var pausedToday: Bool {
        guard let until = defaults.object(forKey: Self.pausedUntilKey) as? Date else { return false }
        return until > Date()
    }

    /// "Pausar hoy" (design 3.5, the one-line answer to a bus commuter's GPS bill): on ends whatever runs and
    /// ignores wake-ups until midnight; off lets the next wake-up probe again.
    public func setPausedToday(_ on: Bool) async {
        if on {
            let calendar = Calendar.autoupdatingCurrent
            let midnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date())
            defaults.set(midnight, forKey: Self.pausedUntilKey)
            await stopDrive()
            logger.info("paused until \(midnight, privacy: .public)")
        } else {
            defaults.removeObject(forKey: Self.pausedUntilKey)
            logger.info("pause lifted")
        }
    }

    /// Onboarding screen 1: When In Use, then Always (design 7).
    public func requestAuthorization() async {
        await wakeUps?.requestAuthorization()
    }

    /// Onboarding screen 2: the Core Motion prompt, foreground only.
    public func requestMotionAccess() async -> HealthInputs.MotionAuthorization {
        await motionGate.requestAccess()
    }

    public func healthSnapshot() async -> LocationHealth {
        let wakeUps = wakeUps
        let authorization: HealthInputs.LocationAuthorization
        let precise: Bool
        let parkedFlags: [String]
        let parkedPresent: Bool
        let slcStarted: Bool
        let lastSlc: Date?
        if let wakeUps {
            (authorization, precise, parkedFlags, parkedPresent, slcStarted, lastSlc) = await MainActor.run {
                (
                    Self.map(wakeUps.authorizationStatus),
                    wakeUps.accuracyAuthorization == .fullAccuracy,
                    wakeUps.lastParkedFlags,
                    wakeUps.parkedConditionPresent,
                    wakeUps.slcStarted,
                    wakeUps.lastSlcDelivery
                )
            }
        } else {
            authorization = .notDetermined
            precise = true
            parkedFlags = []
            parkedPresent = false
            slcStarted = false
            lastSlc = nil
        }
        return LocationHealth(
            authorization: authorization,
            preciseLocation: precise,
            sessionDiagnostics: sessionDiagnostics,
            sessionTaken: sessionTaken,
            parkedFenceFlags: parkedFlags,
            parkedFenceIdentifierPresent: parkedPresent,
            slcStarted: slcStarted,
            lastSlcDelivery: lastSlc,
            motionAuthorization: MotionGate.authorization,
            state: state,
            launchReason: launchReason
        )
    }

    public var snapshot: DriveSnapshot? {
        get async { await driveSession.snapshot }
    }

    // MARK: Wake-ups (design 3.1, idle)

    private func monitorEvent(_ event: WakeUps.MonitorEvent) async {
        noteLaunchReason(.monitorEvent)
        AppLog.shared.post(.monitorEvent(identifier: event.identifier, state: event.state, flags: event.flags))
        guard event.identifier == WakeUps.parkedIdentifier, event.state == "unsatisfied" else { return }
        await wake(source: .monitor, flags: event.flags, at: event.date)
    }

    private func significantChange(_ fix: Fix) async {
        noteLaunchReason(.slc)
        await wakeUps?.noteSlcDelivery(at: fix.timestamp)
        if lastFix == nil { lastFix = fix }
        await wake(source: .slc, flags: [], at: fix.timestamp)
    }

    private func wake(source: WakeSource, flags: [String], at date: Date) async {
        lastWakeSource = source
        switch state {
        case .idle:
            if pausedToday {
                AppLog.shared.post(.wakeup(source: source, flags: flags + ["pausedToday"]))
                return
            }
            AppLog.shared.post(.wakeup(source: source, flags: flags))
            await beginProbe(wake: source, at: date)
        case .probing:
            if probe?.wake == nil {
                probe?.wake = source
                probe?.wakeAt = date
            }
            AppLog.shared.post(.wakeup(source: source, flags: flags + ["whileProbing"]))
        case .driving, .paused:
            AppLog.shared.post(.wakeup(source: source, flags: flags + ["whileDriving"]))
        }
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        logger.info("authorization now \(status.rawValue, privacy: .public)")
    }

    // MARK: Probe (design 3.1, probing)

    private func beginProbe(wake: WakeSource?, at date: Date) async {
        guard case .idle = state else { return }
        setState(.probing)
        var probe = Probe(startedAt: Date(), wake: wake, wakeAt: date)
        // The stream first: it is what keeps a woken process alive. The gate runs beside it and only shortens.
        startStream()
        probe.motionTask = Task { [weak self] in
            let result = await MotionGate().recentAutomotive(window: Thresholds.motionWindowSeconds)
            guard !Task.isCancelled else { return }
            await self?.motionResult(result)
        }
        probe.timeoutTask = Task { [weak self] in
            // A cancelled sleep throws; swallowing it would run the timeout on a probe that already ended.
            do {
                try await Task.sleep(for: .seconds(Thresholds.probeSeconds))
            } catch {
                return
            }
            await self?.probeTimedOut()
        }
        self.probe = probe
        logger.info("probe started, wake \(String(describing: wake), privacy: .public)")
    }

    private func motionResult(_ automotive: Bool?) async {
        guard case .probing = state, probe != nil else { return }
        probe?.motion = automotive
        logger.info("motion gate: \(String(describing: automotive), privacy: .public)")
        guard automotive == true else { return }
        let wakeAt = probe?.wakeAt
        let reason = DriveReason.wakeup(probe?.wake ?? lastWakeSource ?? .slc)
        endProbe(result: .driving)
        await becomeDriving(reason: reason, wakeAt: wakeAt)
    }

    private func probeTimedOut() async {
        guard case .probing = state else { return }
        endProbe(result: .timeout)
        await goIdle(rearmAt: lastFix?.coordinate)
    }

    private func probeFix(_ fix: Fix) async {
        guard var current = probe else { return }
        if let speed = fix.speed {
            current.maxSpeed = max(current.maxSpeed ?? 0, speed)
            current.fastFixes = speed >= Thresholds.driveSpeedMps ? current.fastFixes + 1 : 0
        }
        probe = current
        if fix.isStationary {
            endProbe(result: .idle)
            await goIdle(rearmAt: fix.coordinate)
            return
        }
        guard current.fastFixes >= Thresholds.driveFixes else { return }
        let reason = DriveReason.wakeup(current.wake ?? lastWakeSource ?? .slc)
        endProbe(result: .driving)
        await becomeDriving(reason: reason, wakeAt: current.wakeAt)
        await driveSession.ingest(fix, paused: false)
    }

    /// Logs the probe row and clears the probe; the caller moves the state.
    private func endProbe(result: ProbeResult) {
        guard let current = probe else { return }
        current.timeoutTask?.cancel()
        current.motionTask?.cancel()
        probe = nil
        AppLog.shared.post(.probe(
            result: result,
            motion: current.motion,
            maxSpeedMps: current.maxSpeed,
            seconds: Date().timeIntervalSince(current.startedAt)
        ))
        logger.info("probe ended: \(result.rawValue, privacy: .public)")
    }

    // MARK: Driving and paused (design 3.1)

    private func becomeDriving(reason: DriveReason, wakeAt: Date?) async {
        // The state moves before the first suspension, so nothing that runs in between sees a stale probe.
        slowSince = nil
        setState(.driving)
        startStream()
        var whenInUseOnly = false
        if let wakeUps {
            whenInUseOnly = await MainActor.run { wakeUps.authorizationStatus == .authorizedWhenInUse }
        }
        await driveSession.begin(reason: reason, wakeAt: wakeAt, backgroundActivity: whenInUseOnly)
        AppLog.shared.post(.driveStarted(reason: reason))
        // Design 5.2: at every drive start, refresh if the feed is older than a day; never on the alert path.
        Task { await FeedRefresher.shared.refreshIfNeeded(trigger: .driveStart) }
    }

    private func drivingFix(_ fix: Fix) async {
        await driveSession.ingest(fix, paused: false)
        if fix.isStationary {
            await pause(at: fix)
            return
        }
        if let speed = fix.speed, speed < Thresholds.pauseSlowSpeedMps {
            let since = slowSince ?? fix.timestamp
            slowSince = since
            if fix.timestamp.timeIntervalSince(since) >= Thresholds.pauseSlowSeconds {
                await pause(at: fix)
            }
        } else {
            slowSince = nil
        }
    }

    private func pause(at fix: Fix) async {
        slowSince = nil
        lastPausedMotionCheck = nil
        setState(.paused(since: fix.timestamp))
        await driveSession.setPaused(since: fix.timestamp)
        // A termination while suspended still gets a wake-up: the fence sits at the stationary position.
        await rearmFence(at: fix.coordinate)
        await driveSession.showPaused()
        AppLog.shared.post(.drivePaused)
    }

    private func pausedFix(_ fix: Fix, since: Date) async {
        let pausedFor = fix.timestamp.timeIntervalSince(since)
        if pausedFor >= Thresholds.pauseEndMinutes * 60 {
            // Over the limit: the drive is over; re-probe, motion gate first, so a car that parked twelve minutes
            // and left again is driving on its first fixes.
            await endDrive()
            setState(.idle)
            await beginProbe(wake: nil, at: fix.timestamp)
            await probeFix(fix)
            return
        }
        if let speed = fix.speed, speed >= Thresholds.resumeSpeedMps {
            await resumeDrive(since: since, at: fix.timestamp)
            await driveSession.ingest(fix, paused: false)
            return
        }
        await driveSession.ingest(fix, paused: true)
        guard !fix.isStationary else { return }
        let now = Date()
        if let last = lastPausedMotionCheck, now.timeIntervalSince(last) < Self.pausedMotionCheckSeconds { return }
        lastPausedMotionCheck = now
        // Off the fix loop: a slow Core Motion query must not hold up the next update.
        let gate = motionGate
        Task { [weak self] in
            let motion = await gate.recentActivity(window: Thresholds.motionWindowSeconds)
            await self?.walkingResult(motion, at: fix.coordinate, pausedSince: since)
        }
    }

    private func walkingResult(_ motion: MotionSummary?, at coordinate: Coordinate, pausedSince since: Date) async {
        guard case .paused(let current) = state, current == since else { return }
        guard let motion, motion.walking, !motion.automotive else { return }
        logger.info("walking while paused, no automotive: drive end")
        await endDrive()
        await goIdle(rearmAt: coordinate)
    }

    private func resumeDrive(since: Date, at date: Date) async {
        setState(.driving)
        slowSince = nil
        await driveSession.setPaused(since: nil)
        AppLog.shared.post(.driveResumed(pausedSeconds: date.timeIntervalSince(since)))
    }

    private func endDrive() async {
        let row = await driveSession.end()
        AppLog.shared.post(row)
    }

    private func goIdle(rearmAt center: Coordinate?) async {
        setState(.idle)
        stopStream()
        if let center {
            await rearmFence(at: center)
        }
    }

    // MARK: The stream

    private func startStream() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            guard let self else { return }
            await DriveSession.stream { update in
                await self.handle(update)
            }
        }
    }

    private func stopStream() {
        streamTask?.cancel()
        streamTask = nil
    }

    private func handle(_ update: StreamUpdate) async {
        if update.flags != updateFlags {
            updateFlags = update.flags
            // No LogEvent row exists for live-update flags yet (frozen-file request in the lane PR); until it does
            // they ride on monitorEvent under their own identifier, which the fence rule never reads.
            AppLog.shared.post(.monitorEvent(identifier: "liveUpdates", state: "flags", flags: update.flags))
            logger.info("live update flags \(update.flags, privacy: .public)")
        }
        if launchedInBackground {
            noteLaunchReason(.liveUpdate)
        }
        guard let fix = update.fix else { return }
        lastFix = fix
        switch state {
        case .idle:
            // The stream is being cancelled; a late update changes nothing.
            return
        case .probing:
            await probeFix(fix)
        case .driving:
            await drivingFix(fix)
        case .paused(let since):
            await pausedFix(fix, since: since)
        }
    }

    // MARK: Session diagnostics (design 3.2)

    private func watchDiagnostics(_ session: CLServiceSession) {
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self] in
            do {
                for try await diagnostic in session.diagnostics {
                    var mapped = HealthInputs.SessionDiagnostics()
                    mapped.alwaysAuthorizationDenied = diagnostic.alwaysAuthorizationDenied
                    mapped.authorizationDenied = diagnostic.authorizationDenied
                    mapped.authorizationDeniedGlobally = diagnostic.authorizationDeniedGlobally
                    mapped.authorizationRestricted = diagnostic.authorizationRestricted
                    mapped.fullAccuracyDenied = diagnostic.fullAccuracyDenied
                    mapped.insufficientlyInUse = diagnostic.insufficientlyInUse
                    mapped.authorizationRequestInProgress = diagnostic.authorizationRequestInProgress
                    mapped.serviceSessionRequired = diagnostic.serviceSessionRequired
                    await self?.sessionDiagnostic(mapped)
                }
            } catch {
                Logger(subsystem: "io.github.geiserx.radares", category: "location")
                    .error("session diagnostics ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func sessionDiagnostic(_ diagnostics: HealthInputs.SessionDiagnostics) {
        sessionDiagnostics = diagnostics
        var flags: [String] = []
        if diagnostics.alwaysAuthorizationDenied { flags.append("alwaysAuthorizationDenied") }
        if diagnostics.authorizationDenied { flags.append("authorizationDenied") }
        if diagnostics.authorizationDeniedGlobally { flags.append("authorizationDeniedGlobally") }
        if diagnostics.authorizationRestricted { flags.append("authorizationRestricted") }
        if diagnostics.fullAccuracyDenied { flags.append("fullAccuracyDenied") }
        if diagnostics.insufficientlyInUse { flags.append("insufficientlyInUse") }
        if diagnostics.authorizationRequestInProgress { flags.append("authorizationRequestInProgress") }
        if diagnostics.serviceSessionRequired { flags.append("serviceSessionRequired") }
        // Same workaround as the live-update flags: a row of its own is a frozen-file request.
        AppLog.shared.post(.monitorEvent(identifier: "session", state: "diagnostics", flags: flags))
        logger.info("session diagnostics \(flags, privacy: .public)")
    }

    // MARK: Helpers

    private func setState(_ new: DriveState) {
        guard new != state else { return }
        logger.notice("state \(String(describing: self.state), privacy: .public) -> \(String(describing: new), privacy: .public)")
        state = new
        stateContinuation.yield(new)
    }

    /// The first thing that arrives after launch names the launch (design 3.3, step 6). The app delegate logged
    /// `unknown` at launch; this appends the row with the reason, once per process.
    private func noteLaunchReason(_ reason: LaunchReason) {
        guard launchReason == .unknown else { return }
        launchReason = reason
        AppLog.shared.post(.launch(reason: reason, state: launchState))
        logger.info("launch reason \(reason.rawValue, privacy: .public)")
    }

    private func rearmFence(at center: Coordinate) async {
        await wakeUps?.rearmFence(at: center)
        defaults.set([center.latitude, center.longitude], forKey: Self.fenceCenterKey)
    }

    private func loadFenceCenter() -> Coordinate? {
        guard let pair = defaults.array(forKey: Self.fenceCenterKey) as? [Double], pair.count == 2 else { return nil }
        return Coordinate(latitude: pair[0], longitude: pair[1])
    }

    private static func map(_ status: CLAuthorizationStatus) -> HealthInputs.LocationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorizedWhenInUse: .whenInUse
        case .authorizedAlways: .always
        @unknown default: .notDetermined
        }
    }
}
