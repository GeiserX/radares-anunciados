// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// passes.json: what fired when and how far the car has been since, so a relaunch cannot repeat the voice (design 2.6).

import Foundation

public struct PassLedger: Codable, Sendable, Hashable {
    public struct Entry: Codable, Sendable, Hashable {
        public var id: String
        public var firedAt: Date
        /// The level it fired at; a radar demoted to visual stays visual for the pass.
        public var level: Level
        /// Farthest the car has been from the radar since firing, metres.
        public var farthestMetres: Double
        public var passedAt: Date?

        public init(id: String, firedAt: Date, level: Level = .full, farthestMetres: Double = 0, passedAt: Date? = nil) {
            self.id = id
            self.firedAt = firedAt
            self.level = level
            self.farthestMetres = farthestMetres
            self.passedAt = passedAt
        }

        /// Both cooldown conditions hold: the minutes have gone by and the car has been far enough away.
        public func cooldownOver(now: Date) -> Bool {
            now.timeIntervalSince(firedAt) >= Thresholds.cooldownMinutes * 60 && farthestMetres >= Thresholds.cooldownM
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public func entry(for id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    public mutating func upsert(_ entry: Entry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
    }

    public mutating func remove(id: String) {
        entries.removeAll { $0.id == id }
    }

    /// Drops entries older than Thresholds.ledgerPruneHours and keeps at most Thresholds.ledgerMaxEntries (the newest).
    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Thresholds.ledgerPruneHours * 3600)
        entries.removeAll { $0.firedAt < cutoff }
        if entries.count > Thresholds.ledgerMaxEntries {
            entries.sort { $0.firedAt > $1.firedAt }
            entries.removeLast(entries.count - Thresholds.ledgerMaxEntries)
        }
    }
}
