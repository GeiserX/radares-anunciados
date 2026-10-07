// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// passes.json: what fired when and how far the car has been since, so a relaunch cannot repeat the voice (design 2.6).

import Foundation

public struct PassLedger: Codable, Sendable, Hashable {
    public struct Entry: Codable, Sendable, Hashable {
        public var id: String
        public var firedAt: Date
        /// Farthest the car has been from the radar since firing, metres.
        public var farthestMetres: Double
        public var passedAt: Date?

        public init(id: String, firedAt: Date, farthestMetres: Double = 0, passedAt: Date? = nil) {
            self.id = id
            self.firedAt = firedAt
            self.farthestMetres = farthestMetres
            self.passedAt = passedAt
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// Drops entries older than Thresholds.ledgerPruneHours and keeps at most Thresholds.ledgerMaxEntries.
    public mutating func prune(now: Date) {
        fatalError("lane: core")
    }
}
