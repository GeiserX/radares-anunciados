// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per radar id: idle -> armed -> fired(level) -> passed -> cooldown -> idle, with the 10 min AND 2 km rule (design 2.6).
// `armed` is transient (this process only); everything from `fired` on lives in the ledger, which the owner persists.

import Foundation

public struct PassTracker: Sendable {
    public enum State: Sendable, Hashable {
        case idle
        case armed
        case fired(Level)
        case passed
        case cooldown
    }

    public private(set) var ledger: PassLedger
    private var armed: Set<String> = []

    public init(ledger: PassLedger) {
        self.ledger = ledger
    }

    public func state(of id: String, now: Date) -> State {
        if let entry = ledger.entry(for: id) {
            if entry.cooldownOver(now: now) { return .idle }
            guard let passedAt = entry.passedAt else { return .fired(entry.level) }
            return now.timeIntervalSince(passedAt) < Thresholds.passedCardSeconds ? .passed : .cooldown
        }
        return armed.contains(id) ? .armed : .idle
    }

    /// True when the radar may fire now: idle or armed, never fired, passed or cooling down.
    public func canFire(_ id: String, now: Date) -> Bool {
        switch state(of: id, now: now) {
        case .idle, .armed: true
        default: false
        }
    }

    public mutating func arm(_ id: String) {
        armed.insert(id)
    }

    public mutating func disarm(_ id: String) {
        armed.remove(id)
    }

    /// `held`: a `.visual` fire for a car off the radar's road, upgradable once. `hidden`: the opposite flow of a
    /// high-confidence bearing, nothing shown. Both are written only when true, so the ledger stays 0.1.3's shape.
    public mutating func fire(_ id: String, level: Level, held: Bool = false, hidden: Bool = false, now: Date) {
        armed.remove(id)
        ledger.upsert(PassLedger.Entry(id: id, firedAt: now, level: level, held: held ? true : nil, hidden: hidden ? true : nil))
    }

    /// True when a held `.visual` fire may still become `.full`: held, not passed. False after the one upgrade.
    public func canUpgrade(_ id: String) -> Bool {
        guard let entry = ledger.entry(for: id) else { return false }
        return entry.level == .visual && entry.held == true && entry.passedAt == nil
    }

    /// The one upgrade of a held fire: `.full`, no longer held. The fire time (and so the cooldown) is unchanged.
    public mutating func upgrade(_ id: String) {
        guard var entry = ledger.entry(for: id), canUpgrade(id) else { return }
        entry.level = .full
        entry.held = nil
        ledger.upsert(entry)
    }

    /// True when the radar fired hidden on this pass.
    public func isHidden(_ id: String) -> Bool {
        ledger.entry(for: id)?.hidden == true
    }

    public mutating func markPassed(_ id: String, now: Date) {
        guard var entry = ledger.entry(for: id), entry.passedAt == nil else { return }
        entry.passedAt = now
        ledger.upsert(entry)
    }

    /// Records how far the car is from a fired radar, for the 2 km half of the cooldown. Cheap: only entries still short of it.
    public mutating func observe(_ id: String, distance: Double) {
        guard var entry = ledger.entry(for: id), entry.farthestMetres < Thresholds.cooldownM, distance > entry.farthestMetres else { return }
        entry.farthestMetres = distance
        ledger.upsert(entry)
    }

    /// Entries whose cooldown is over are dropped, old ones pruned. Called at drive end, never per fix.
    public mutating func prune(now: Date) {
        ledger.entries.removeAll { $0.cooldownOver(now: now) }
        ledger.prune(now: now)
    }

    /// Ids fired and not yet passed, for the pass detection.
    public var firedIds: [String] {
        ledger.entries.filter { $0.passedAt == nil }.map(\.id)
    }
}
