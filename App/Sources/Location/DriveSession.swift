// Lane: location
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The liveUpdates(.automotiveNavigation) loop the probe and the drive share: CLLocationUpdate -> Fix ->
// AlertEngine.ingest -> AlertDispatcher.handle. Persists the drive state on every change, persists the ledger on
// warn, pass and drive end, rejoins a CLBackgroundActivitySession in While-Using mode and never invalidates one
// from a launch path.

import CoreLocation
import RadaresCore

/// What survives a relaunch mid-drive (UserDefaults).
public struct PersistedDrive: Sendable, Codable, Hashable {
    public var startedAt: Date
    public var reason: DriveReason
    public var lastFix: Fix?
    public var backgroundActivitySessionOutstanding: Bool

    public init(startedAt: Date, reason: DriveReason, lastFix: Fix? = nil, backgroundActivitySessionOutstanding: Bool = false) {
        self.startedAt = startedAt
        self.reason = reason
        self.lastFix = lastFix
        self.backgroundActivitySessionOutstanding = backgroundActivitySessionOutstanding
    }
}

public actor DriveSession {
    public init() {}

    /// Iterate the stream until cancelled.
    public func run() async {
        fatalError("lane: location")
    }
}
