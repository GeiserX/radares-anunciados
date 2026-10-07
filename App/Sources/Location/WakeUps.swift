// Lane: location
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The two system-persisted wake-ups (design 3.1): CLMonitor "RadaresWake" with the parked condition, added
// `assuming: .satisfied` so the first `.unsatisfied` event is the exit, and the significant-change manager with its
// delegate. Co-equal: whichever arrives first starts the probe. Both are recreated at every launch; the monitor is
// recreated by name and the parked condition re-added when `identifiers` lost it (the system keeps the condition
// across relaunches, but not across every reinstall or reboot before first unlock).
//
// Significant change delivers the cached position right after `startMonitoringSignificantLocationChanges()` on
// every launch ("the first event to be delivered is usually the most recently cached location event"). On a launch
// the user made that delivery is not movement: it is handed over as the initial fix (for the fence), never as a
// wake-up. On a launch iOS made for a location event it is the event and wakes as usual.
//
// A main-actor class, not an actor: CLLocationManager delivers its delegate callbacks on the thread that created
// it, and that thread needs a run loop, so the manager lives on the main thread. CLMonitor is an actor of its own.

import CoreLocation
import Foundation
import RadaresCore
import os

@MainActor
public final class WakeUps {
    /// The design names it "radares.wake"; Core Location asserts on a non-alphanumeric monitor name, so no dot.
    public nonisolated static let monitorName = "RadaresWake"
    public nonisolated static let parkedIdentifier = "parked"

    /// A `CLMonitor.Event` reduced to values, so it crosses into the coordinator and the log as-is.
    public struct MonitorEvent: Sendable, Hashable {
        public var identifier: String
        public var state: String
        public var flags: [String]
        public var date: Date
    }

    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "wakeups")
    private let onMonitorEvent: @Sendable (MonitorEvent) async -> Void
    private let onSignificantChange: @Sendable (Fix) async -> Void
    private let onInitialFix: @Sendable (Fix) async -> Void
    private let onAuthorizationChange: @Sendable (CLAuthorizationStatus) async -> Void

    private let slcManager = CLLocationManager()
    private let slcDelegate: SLCDelegate
    private var monitor: CLMonitor?
    private var monitorTask: Task<Void, Never>?
    /// The next significant-change delivery is the cached position of a user launch: an initial fix, not a wake.
    private var initialDeliveryPending = false
    private var slcStartedAt = Date()
    /// A cached delivery lands within a moment of the start; a delivery later than this on a device with nothing
    /// cached is real movement and wakes as usual.
    static let initialDeliveryWindowSeconds: TimeInterval = 5

    /// Health inputs (design 6, rows "Valla de aparcamiento" and "Cambio significativo").
    public private(set) var slcStarted = false
    public private(set) var parkedConditionPresent = false
    public private(set) var lastParkedFlags: [String] = []
    public private(set) var lastSlcDelivery: Date?
    public private(set) var fenceCenter: Coordinate?

    public init(
        onMonitorEvent: @escaping @Sendable (MonitorEvent) async -> Void,
        onSignificantChange: @escaping @Sendable (Fix) async -> Void,
        onInitialFix: @escaping @Sendable (Fix) async -> Void = { _ in },
        onAuthorizationChange: @escaping @Sendable (CLAuthorizationStatus) async -> Void
    ) {
        self.onMonitorEvent = onMonitorEvent
        self.onSignificantChange = onSignificantChange
        self.onInitialFix = onInitialFix
        self.onAuthorizationChange = onAuthorizationChange
        slcDelegate = SLCDelegate(onAuthorization: onAuthorizationChange)
        slcDelegate.onLocations = { [weak self] fix in await self?.significantChange(fix) }
        slcManager.delegate = slcDelegate
    }

    /// The next delivery is the cached position of a start on a user launch, not movement.
    func expectInitialDelivery(at now: Date = Date()) {
        initialDeliveryPending = true
        slcStartedAt = now
    }

    /// Every delivery of the significant-change manager. The first one after a start on a user launch is the
    /// cached position (`initialDeliveryPending`) when it is older than the start or lands within
    /// `initialDeliveryWindowSeconds` of it: kept as the initial fix, not logged or probed as a wake-up. A first
    /// delivery later than that (a device with nothing cached) is movement.
    func significantChange(_ fix: Fix, receivedAt now: Date = Date()) async {
        if initialDeliveryPending {
            initialDeliveryPending = false
            if fix.timestamp < slcStartedAt || now.timeIntervalSince(slcStartedAt) < Self.initialDeliveryWindowSeconds {
                logger.info("significant change: initial cached delivery, kept as the first fix, not a wake-up")
                await onInitialFix(fix)
                return
            }
            logger.info("significant change: first delivery is late and fresh, a wake")
        }
        lastSlcDelivery = fix.timestamp
        await onSignificantChange(fix)
    }

    // MARK: Authorization (design 7, screen 1)

    public var authorizationStatus: CLAuthorizationStatus { slcManager.authorizationStatus }
    public var accuracyAuthorization: CLAccuracyAuthorization { slcManager.accuracyAuthorization }

    /// When In Use first; once granted, Always. Apple prompts for Always at once when When In Use was just granted,
    /// so the chain lives in the delegate: a change to `.authorizedWhenInUse` while the goal is Always asks again.
    public func requestAuthorization() {
        switch slcManager.authorizationStatus {
        case .notDetermined:
            slcDelegate.chainToAlways = true
            slcManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            slcManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    // MARK: Start, re-arm, stop

    /// Every launch: recreate the monitor by name, iterate its events, re-add the parked condition if it was lost,
    /// start significant change. `fenceCenter` is the last persisted fence position (nil before the first fix).
    /// `expectCachedDelivery` is true on a launch the user made: the first delivery is then the cached position.
    public func start(fenceCenter: Coordinate?, expectCachedDelivery: Bool = false) async {
        self.fenceCenter = fenceCenter
        if !slcStarted {
            if expectCachedDelivery { expectInitialDelivery() }
            slcManager.startMonitoringSignificantLocationChanges()
            slcStarted = true
            logger.info("significant change started, initial delivery \(expectCachedDelivery ? "expected" : "is a wake", privacy: .public)")
        }
        guard monitor == nil else { return }
        let monitor = await CLMonitor(Self.monitorName)
        self.monitor = monitor
        let identifiers = await monitor.identifiers
        parkedConditionPresent = identifiers.contains(Self.parkedIdentifier)
        logger.info("monitor \(Self.monitorName, privacy: .public) identifiers \(identifiers, privacy: .public)")
        if !parkedConditionPresent, let fenceCenter {
            await add(center: fenceCenter)
            logger.info("parked condition re-added at launch")
        }
        monitorTask = Task { [weak self] in
            await self?.iterateEvents(monitor)
        }
    }

    /// Move the parked fence to `center` (remove + add). Called when a probe ends idle, on pause and at drive end.
    public func rearmFence(at center: Coordinate) async {
        guard let monitor else {
            fenceCenter = center
            return
        }
        if await monitor.identifiers.contains(Self.parkedIdentifier) {
            await monitor.remove(Self.parkedIdentifier)
        }
        await add(center: center)
    }

    /// The "Avisos" switch off: no fence, no significant change. The way out of every state the app adds.
    public func stop() async {
        slcManager.stopMonitoringSignificantLocationChanges()
        slcStarted = false
        initialDeliveryPending = false
        monitorTask?.cancel()
        monitorTask = nil
        if let monitor, await monitor.identifiers.contains(Self.parkedIdentifier) {
            await monitor.remove(Self.parkedIdentifier)
        }
        parkedConditionPresent = false
        monitor = nil
        logger.info("wake-ups stopped")
    }

    private func add(center: Coordinate) async {
        guard let monitor else { return }
        let condition = CLMonitor.CircularGeographicCondition(
            center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
            radius: Thresholds.fenceRadiusM
        )
        await monitor.add(condition, identifier: Self.parkedIdentifier, assuming: .satisfied)
        fenceCenter = center
        parkedConditionPresent = await monitor.identifiers.contains(Self.parkedIdentifier)
        logger.info("parked fence armed, radius \(Thresholds.fenceRadiusM, privacy: .public) m, present \(self.parkedConditionPresent, privacy: .public)")
    }

    private func iterateEvents(_ monitor: CLMonitor) async {
        do {
            let events = await monitor.events
            for try await event in events {
                if Task.isCancelled { return }
                let reduced = MonitorEvent(
                    identifier: event.identifier,
                    state: Self.describe(event.state),
                    flags: Self.flags(of: event),
                    date: event.date
                )
                if reduced.identifier == Self.parkedIdentifier {
                    lastParkedFlags = reduced.flags
                }
                logger.info("monitor event \(reduced.identifier, privacy: .public) \(reduced.state, privacy: .public) flags \(reduced.flags, privacy: .public)")
                await onMonitorEvent(reduced)
            }
        } catch {
            logger.error("monitor events ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func describe(_ state: CLMonitor.Event.State) -> String {
        switch state {
        case .unknown: "unknown"
        case .satisfied: "satisfied"
        case .unsatisfied: "unsatisfied"
        case .unmonitored: "unmonitored"
        @unknown default: "other"
        }
    }

    /// Every flag of design 3.2 that is set, by name.
    private static func flags(of event: CLMonitor.Event) -> [String] {
        var flags: [String] = []
        if event.conditionLimitExceeded { flags.append("conditionLimitExceeded") }
        if event.conditionUnsupported { flags.append("conditionUnsupported") }
        if event.persistenceUnavailable { flags.append("persistenceUnavailable") }
        if event.authorizationDenied { flags.append("authorizationDenied") }
        if event.authorizationDeniedGlobally { flags.append("authorizationDeniedGlobally") }
        if event.authorizationRestricted { flags.append("authorizationRestricted") }
        if event.authorizationRequestInProgress { flags.append("authorizationRequestInProgress") }
        if event.accuracyLimited { flags.append("accuracyLimited") }
        if event.insufficientlyInUse { flags.append("insufficientlyInUse") }
        if event.serviceSessionRequired { flags.append("serviceSessionRequired") }
        return flags
    }
}

/// The significant-change delegate. Not isolated: Core Location calls it on the main thread (the manager was
/// created there) and the callbacks hand values, never Core Location objects, to the coordinator.
private final class SLCDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    /// Set by `WakeUps` right after its init (it needs `self`); every delivery goes through it.
    var onLocations: @Sendable (Fix) async -> Void = { _ in }
    private let onAuthorization: @Sendable (CLAuthorizationStatus) async -> Void
    var chainToAlways = false

    init(onAuthorization: @escaping @Sendable (CLAuthorizationStatus) async -> Void) {
        self.onAuthorization = onAuthorization
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let fix = DriveSession.fix(from: last, isStationary: false)
        let handler = onLocations
        Task { await handler(fix) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse, chainToAlways {
            chainToAlways = false
            manager.requestAlwaysAuthorization()
        }
        let handler = onAuthorization
        Task { await handler(status) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Logger(subsystem: "io.github.geiserx.radares", category: "wakeups")
            .error("significant change failed: \(error.localizedDescription, privacy: .public)")
    }
}
