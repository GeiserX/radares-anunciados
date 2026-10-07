// Lane: location
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The liveUpdates(.automotiveNavigation) loop the probe and the drive share (`DriveSession.stream`), and the drive
// itself: CLLocationUpdate -> Fix -> AlertEngine.ingest -> AlertDispatcher.handle(_:at:) on a serial queue off the
// fix loop (an audio session activation never holds the next fix), the card handed to the
// Live Activity after every fix (the controller's cadence decides what reaches the system), the passed, stretch
// and driveEnded log rows, the drive counters that end up in the driveEnded row, the pass ledger persisted on
// warn, pass and drive end (never per fix), the drive state persisted in UserDefaults on every change so a relaunch
// resumes the loop, and the CLBackgroundActivitySession of the degraded While-Using mode, rejoined at launch and
// never invalidated from a launch path (design 3.1, 3.2, 3.4).
//
// The state machine (idle, probing, driving, paused) is the coordinator's; this actor only knows "a drive is on".

import CoreLocation
import Foundation
import RadaresCore
import os

/// What survives a relaunch mid-drive (UserDefaults). `pausedSince` non-nil means the drive was paused.
public struct PersistedDrive: Sendable, Codable, Hashable {
    public var startedAt: Date
    public var reason: DriveReason
    public var lastFix: Fix?
    /// A `CLBackgroundActivitySession` was outstanding (While-Using mode): rejoin it at launch, never invalidate it there.
    public var backgroundActivitySessionOutstanding: Bool
    public var pausedSince: Date?
    /// The wake-up that led to this drive, for `firstFixAfterWakeS` and `firstWarnAfterWakeM`.
    public var wakeAt: Date?
    public var firstFixAt: Date?

    public init(
        startedAt: Date,
        reason: DriveReason,
        lastFix: Fix? = nil,
        backgroundActivitySessionOutstanding: Bool = false,
        pausedSince: Date? = nil,
        wakeAt: Date? = nil,
        firstFixAt: Date? = nil
    ) {
        self.startedAt = startedAt
        self.reason = reason
        self.lastFix = lastFix
        self.backgroundActivitySessionOutstanding = backgroundActivitySessionOutstanding
        self.pausedSince = pausedSince
        self.wakeAt = wakeAt
        self.firstFixAt = firstFixAt
    }

    static let defaultsKey = "drive.persisted"

    public static func load(from defaults: UserDefaults = .standard) -> PersistedDrive? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(PersistedDrive.self, from: data)
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    public static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// One `CLLocationUpdate` reduced to values. `fix` is nil when the update carried no location (a flags-only update).
public struct StreamUpdate: Sendable, Hashable {
    public var fix: Fix?
    public var isStationary: Bool
    /// Every `CLLocationUpdate` flag that is set, by name (design 3.2).
    public var flags: [String]
    public var receivedAt: Date
}

/// Work for the surfaces, run in order, off the caller: each job starts after the previous one ends, and `drain`
/// waits for the last one. `AVAudioSession.setActive` can take seconds on a route change; the fix loop must not.
public actor SerialTaskQueue {
    private var last: Task<Void, Never>?

    public init() {}

    /// Returns at once; `job` runs after every job enqueued before it.
    public func enqueue(_ job: @escaping @Sendable () async -> Void) {
        let previous = last
        last = Task {
            await previous?.value
            await job()
        }
    }

    public func drain() async {
        await last?.value
    }
}

public actor DriveSession {
    /// Launch argument `-StateMachineOnlyForTest 1`, or the same key in the app defaults (a system relaunch carries
    /// no arguments): the stream and the state machine run, but no fix reaches the
    /// alert engine and no surface is called. Exists so `scripts/sim-drive.sh` can assert the states while the core
    /// and surfaces lanes are stubs; a production launch never sets it.
    public static let stateMachineOnlyArgument = "StateMachineOnlyForTest"

    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "drive")
    private let engineEnabled: Bool
    private let defaults: UserDefaults

    public private(set) var persisted: PersistedDrive?
    private var engine: AlertEngine?
    private var engineLoad: Task<Void, Never>?
    private var backgroundSession: CLBackgroundActivitySession?
    /// The surfaces were told the drive started, once per process (a relaunch mid-drive tells them again).
    private var surfacesStarted = false
    /// Every surface call of the drive, in fix order, off the fix loop.
    private let surfaces = SerialTaskQueue()

    // Counters for the driveEnded row (design 6).
    private var fixes = 0
    private var alerts = 0
    private var maxGapSeconds: Double = 0
    private var lastMovingFixAt: Date?
    private var lastFixLoggedAt: Date?
    private var metresSinceFirstFix: Double = 0
    private var firstWarnAfterWakeM: Double?

    /// `suiteName` is for tests; the app uses the standard defaults.
    public init(suiteName: String? = nil) {
        defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        engineEnabled = !defaults.bool(forKey: Self.stateMachineOnlyArgument)
    }

    public var isActive: Bool { persisted != nil }
    public var snapshot: DriveSnapshot? { engine?.snapshot }

    // MARK: The stream

    /// Iterate `liveUpdates(.automotiveNavigation)` until cancelled, handing every update to `handler` in order.
    /// Started once per process by the coordinator; the probe and the drive share it (design 3.1: the stream is
    /// what keeps a woken process alive, so it starts before anything is decided).
    public static func stream(_ handler: @Sendable (StreamUpdate) async -> Void) async {
        let logger = Logger(subsystem: "io.github.geiserx.radares", category: "stream")
        logger.info("liveUpdates(.automotiveNavigation) started")
        do {
            for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                if Task.isCancelled { break }
                if let l = update.location {
                    // One row per update, info level: the raw validity signals, so a drive log shows why a speed or
                    // a course came out nil (a negative accuracy is the platform's only validity flag).
                    logger.info("update speed \(l.speed, format: .fixed(precision: 1), privacy: .public)±\(l.speedAccuracy, format: .fixed(precision: 1), privacy: .public) course \(l.course, format: .fixed(precision: 0), privacy: .public)±\(l.courseAccuracy, format: .fixed(precision: 0), privacy: .public) hacc \(l.horizontalAccuracy, format: .fixed(precision: 0), privacy: .public) stationary \(update.isStationary, privacy: .public)")
                }
                let reduced = StreamUpdate(
                    fix: update.location.map { fix(from: $0, isStationary: update.isStationary) },
                    isStationary: update.isStationary,
                    flags: flags(of: update),
                    receivedAt: Date()
                )
                await handler(reduced)
            }
        } catch {
            logger.error("liveUpdates ended: \(error.localizedDescription, privacy: .public)")
        }
        logger.info("liveUpdates loop left")
    }

    /// `CLLocation` to the platform-neutral `Fix` (design 2.1): a negative speed or speed accuracy makes the speed
    /// nil, a negative course or course accuracy makes the course nil. Apple's only validity signal for both.
    /// The Simulator is the one exception: `simctl location` reports a valid speed and course with both accuracies
    /// at -1 (measured: `speed 33.3±-1.0 course 90±-1`), so there the accuracy is not read, or no simulated drive
    /// could ever reach `.driving`. A device build keeps the rule as written.
    public static func fix(from location: CLLocation, isStationary: Bool) -> Fix {
        #if targetEnvironment(simulator)
        let speedValid = location.speed >= 0
        let courseValid = location.course >= 0
        #else
        let speedValid = location.speed >= 0 && location.speedAccuracy >= 0
        let courseValid = location.course >= 0 && location.courseAccuracy >= 0
        #endif
        return Fix(
            coordinate: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
            timestamp: location.timestamp,
            speed: speedValid ? location.speed : nil,
            course: courseValid ? location.course : nil,
            horizontalAccuracy: location.horizontalAccuracy,
            isStationary: isStationary
        )
    }

    private static func flags(of update: CLLocationUpdate) -> [String] {
        var flags: [String] = []
        if update.authorizationDenied { flags.append("authorizationDenied") }
        if update.authorizationDeniedGlobally { flags.append("authorizationDeniedGlobally") }
        if update.authorizationRestricted { flags.append("authorizationRestricted") }
        if update.authorizationRequestInProgress { flags.append("authorizationRequestInProgress") }
        if update.accuracyLimited { flags.append("accuracyLimited") }
        if update.insufficientlyInUse { flags.append("insufficientlyInUse") }
        if update.locationUnavailable { flags.append("locationUnavailable") }
        if update.serviceSessionRequired { flags.append("serviceSessionRequired") }
        return flags
    }

    // MARK: Drive lifecycle

    /// A new drive. `backgroundActivity` is the degraded While-Using mode: the session (the blue pill) is created
    /// here, from a foreground start, and is what lets Core Location unsuspend and relaunch the app for this drive.
    public func begin(reason: DriveReason, wakeAt: Date?, backgroundActivity: Bool, now: Date = Date()) {
        resetCounters()
        surfacesStarted = false
        if backgroundActivity, backgroundSession == nil {
            backgroundSession = CLBackgroundActivitySession()
            logger.info("background activity session created (While-Using mode)")
        }
        persisted = PersistedDrive(
            startedAt: now,
            reason: reason,
            backgroundActivitySessionOutstanding: backgroundSession != nil,
            wakeAt: wakeAt
        )
        persisted?.save(to: defaults)
        loadEngine(resuming: false)
        logger.info("drive begun, reason \(String(describing: reason), privacy: .public)")
    }

    /// A relaunch mid-drive: continue the persisted drive, same ledger. Rejoins the background activity session
    /// when one was outstanding (DTS 770063: rejoin from every launch path, never invalidate there).
    public func resume(_ saved: PersistedDrive) {
        resetCounters()
        surfacesStarted = false
        persisted = saved
        if saved.backgroundActivitySessionOutstanding, backgroundSession == nil {
            backgroundSession = CLBackgroundActivitySession()
            logger.info("background activity session rejoined at launch")
        }
        loadEngine(resuming: true)
        logger.info("drive resumed from persisted state, paused \(saved.pausedSince != nil, privacy: .public)")
    }

    public func setPaused(since: Date?) {
        guard persisted != nil else { return }
        persisted?.pausedSince = since
        persisted?.save(to: defaults)
    }

    /// One fix of the drive: engine, dispatcher, the card to the Live Activity, ledger, counters, the fix row every
    /// `Thresholds.fixLogSeconds`. Returns the engine's events (empty while paused or before the engine is ready).
    @discardableResult
    public func ingest(_ fix: Fix, paused: Bool, now: Date = Date()) async -> [AlertEvent] {
        guard persisted != nil else { return [] }
        fixes += 1
        if let previous = persisted?.lastFix {
            metresSinceFirstFix += Self.metres(previous.coordinate, fix.coordinate)
        }
        if persisted?.firstFixAt == nil {
            persisted?.firstFixAt = fix.timestamp
            persisted?.save(to: defaults)
        }
        persisted?.lastFix = fix
        if let speed = fix.speed, speed >= Thresholds.pauseSlowSpeedMps, !paused {
            if let lastMovingFixAt {
                maxGapSeconds = max(maxGapSeconds, fix.timestamp.timeIntervalSince(lastMovingFixAt))
            }
            lastMovingFixAt = fix.timestamp
        }
        if lastFixLoggedAt == nil || now.timeIntervalSince(lastFixLoggedAt!) >= Thresholds.fixLogSeconds {
            lastFixLoggedAt = now
            AppLog.shared.post(.fix(speedMps: fix.speed, horizontalAccuracy: fix.horizontalAccuracy, isStationary: fix.isStationary))
        }
        guard !paused, let engine else { return [] }
        if engineEnabled, !surfacesStarted {
            // The first fix of the drive in this process: the once-per-drive audio fallback takes its session here.
            surfacesStarted = true
            await surfaces.enqueue { await AlertDispatcher.shared.driveDidStart() }
        }
        let events = engine.ingest(fix)
        if !events.isEmpty {
            await dispatch(events, ledger: engine.ledger, at: fix)
        } else if engineEnabled {
            // Every quiet fix: the controller's milestone cadence decides whether the system hears about it (design
            // 4.2). A fix with events already put the event's card on the activity through the dispatcher. Queued
            // behind the events so a quiet fix never overwrites the card of an event still being delivered.
            let content = engine.snapshot.content
            await surfaces.enqueue { await DriveActivityController.shared.update(content, alert: nil) }
        }
        return events
    }

    /// Drive end: engine.endDrive, flush the ledger, end the Live Activity, forget the persisted drive. Returns the
    /// driveEnded row. The background activity session is invalidated here and only here: the drive is over, and
    /// the user started it from the foreground, so nothing is lost that a launch path could have kept.
    public func end(now: Date = Date()) async -> LogEvent {
        engineLoad?.cancel()
        engineLoad = nil
        if let engine {
            let events = engine.endDrive()
            await dispatch(events, ledger: engine.ledger, at: nil, force: true)
        }
        // The drive end waits for the surfaces: the activity must end after the last card, not before it.
        await surfaces.drain()
        if engineEnabled {
            await DriveActivityController.shared.end()
        }
        let saved = persisted
        let firstFixAfterWakeS: Double? = if let wakeAt = saved?.wakeAt, let firstFixAt = saved?.firstFixAt {
            firstFixAt.timeIntervalSince(wakeAt)
        } else {
            nil
        }
        let row = LogEvent.driveEnded(
            fixes: fixes,
            maxGapSeconds: maxGapSeconds,
            alerts: alerts,
            firstFixAfterWakeS: firstFixAfterWakeS,
            firstWarnAfterWakeM: saved?.wakeAt != nil ? firstWarnAfterWakeM : nil
        )
        backgroundSession?.invalidate()
        backgroundSession = nil
        engine = nil
        persisted = nil
        PersistedDrive.clear(from: defaults)
        resetCounters()
        logger.info("drive ended: \(self.fixes, privacy: .public) fixes")
        return row
    }

    /// The card while paused: the engine's content with the phase changed, or the idle card.
    public func pausedContent(now: Date = Date()) -> DriveContent {
        var content = engine?.snapshot.content ?? .watching(at: now)
        content.phase = .paused
        content.updatedAt = now
        return content
    }

    /// Hands the paused card to the Live Activity (staleDate is the controller's: 15 min while paused, design 3.1).
    public func showPaused(now: Date = Date()) async {
        guard engineEnabled else { return }
        let content = pausedContent(now: now)
        await surfaces.enqueue { await DriveActivityController.shared.update(content, alert: nil) }
    }

    // MARK: Private

    private func loadEngine(resuming: Bool) {
        guard engineEnabled, engine == nil else { return }
        engineLoad = Task.detached(priority: .utility) { [weak self] in
            let built = await Self.buildEngine(resuming: resuming)
            await self?.install(engine: built)
        }
    }

    private func install(engine built: AlertEngine?) {
        guard persisted != nil else { return }
        engine = built
        engineLoad = nil
        logger.info("alert engine ready: \(built != nil, privacy: .public)")
    }

    /// The one decoded feed of the process (`CurrentFeed`, loaded at launch step 4; the app lane copies the bundled
    /// snapshot in on first launch) and the ledger from `AppPaths.passes`, pruned. Off the fix path. A feed swapped
    /// mid-drive is used from the next drive. The stretch the ledger carries belongs to the drive that was killed
    /// inside it: a resumed drive restores it, a new drive never does.
    private nonisolated static func buildEngine(resuming: Bool) async -> AlertEngine? {
        let logger = Logger(subsystem: "io.github.geiserx.radares", category: "drive")
        guard let store = await CurrentFeed.shared.loadIfNeeded() else {
            logger.error("no feed loaded: no engine this drive")
            return nil
        }
        var ledger = PassLedger()
        if let saved = try? Data(contentsOf: AppPaths.passes), let decoded = try? JSONDecoder().decode(PassLedger.self, from: saved) {
            ledger = decoded
        }
        ledger.prune(now: Date())
        return AlertEngine(store: store, ledger: ledgerForEngine(ledger, resuming: resuming))
    }

    /// The persisted ledger as the engine gets it: the passes always, the stretch only when the drive is the one
    /// that was inside it.
    static func ledgerForEngine(_ ledger: PassLedger, resuming: Bool) -> PassLedger {
        var l = ledger
        if !resuming { l.stretch = nil }
        return l
    }

    /// Hands the events to the surfaces with the fix they were decided on (queued, in order, off the fix loop),
    /// writes this lane's rows (`passed`, `stretchEntered`, `stretchExited`; `driveEnded` is the coordinator's),
    /// persists the ledger on warn, pass, stretch entry and exit.
    private func dispatch(_ events: [AlertEvent], ledger: PassLedger, at fix: Fix?, force: Bool = false) async {
        for event in events {
            switch event.kind {
            case .warn(let level):
                if level == .full {
                    alerts += 1
                    if firstWarnAfterWakeM == nil { firstWarnAfterWakeM = metresSinceFirstFix }
                }
            case .passed:
                AppLog.shared.post(.passed(id: event.radar?.id ?? ""))
            case .stretchEntered:
                alerts += 1
                if firstWarnAfterWakeM == nil { firstWarnAfterWakeM = metresSinceFirstFix }
                AppLog.shared.post(.stretchEntered(id: event.radar?.id ?? ""))
            case .stretchExited(let reason):
                AppLog.shared.post(.stretchExited(id: event.radar?.id ?? "", reason: reason))
            case .driveEnded:
                break
            }
            await surfaces.enqueue { await AlertDispatcher.shared.handle(event, at: fix) }
        }
        if Self.persistsLedger(after: events.map(\.kind), force: force) {
            Self.persist(ledger)
        }
    }

    /// Design 2.6: the ledger is written on fire, on pass, on a stretch entry or exit, and at drive end (`force`),
    /// never on a quiet fix. A kill between the warning and the pass must find the entry on disk, or the voice repeats.
    static func persistsLedger(after kinds: [AlertEvent.Kind], force: Bool) -> Bool {
        if force { return true }
        return kinds.contains { kind in
            switch kind {
            case .warn, .passed, .stretchEntered, .stretchExited: true
            case .driveEnded: false
            }
        }
    }

    private nonisolated static func persist(_ ledger: PassLedger) {
        do {
            let data = try JSONEncoder().encode(ledger)
            try data.write(to: AppPaths.passes, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Logger(subsystem: "io.github.geiserx.radares", category: "drive")
                .error("ledger not persisted: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resetCounters() {
        fixes = 0
        alerts = 0
        maxGapSeconds = 0
        lastMovingFixAt = nil
        lastFixLoggedAt = nil
        metresSinceFirstFix = 0
        firstWarnAfterWakeM = nil
    }

    /// Haversine, metres, for the drive counters only. `Geo.distance` in the core is the one the engine uses; this
    /// copy exists so the counters run while the core is a stub, and goes once `Geo.distance` is implemented.
    static func metres(_ a: Coordinate, _ b: Coordinate) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
