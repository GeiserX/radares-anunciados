// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per radar id: idle -> armed -> fired(level) -> passed -> cooldown -> idle, with the 10 min AND 2 km rule (design 2.6).

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

    public init(ledger: PassLedger) {
        self.ledger = ledger
    }

    public func state(of id: String, now: Date) -> State {
        fatalError("lane: core")
    }
}
