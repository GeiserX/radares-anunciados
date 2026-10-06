// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// ingest(_:) -> [AlertEvent]: candidates, course, warn distance, approach, pass state, stretches, pacing (design 2).
// Pure given the store: no I/O, no clock but `now`. Owned by the location lane's drive loop, which persists `ledger`.

import Foundation

public final class AlertEngine {
    private let store: RadarStore
    private let now: @Sendable () -> Date
    public private(set) var ledger: PassLedger

    public init(store: RadarStore, ledger: PassLedger, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.ledger = ledger
        self.now = now
    }

    public func ingest(_ fix: Fix) -> [AlertEvent] {
        fatalError("lane: core")
    }

    public func endDrive() -> [AlertEvent] {
        fatalError("lane: core")
    }

    public var snapshot: DriveSnapshot {
        fatalError("lane: core")
    }
}
