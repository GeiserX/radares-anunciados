// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Two gates plus an inside state per stretch: entry, remaining, average speed, the four exits (design 2.5).

import Foundation

public struct StretchTracker: Sendable {
    public private(set) var inside: DriveSnapshot.StretchState?

    public init() {}

    /// Nil when nothing changed; otherwise the event to emit.
    public mutating func ingest(_ fix: Fix, courseDegrees: Double?, candidates: [Radar], now: Date) -> AlertEvent.Kind? {
        fatalError("lane: core")
    }
}
