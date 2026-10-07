// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// When to ask for the feed (design 5.2): foreground 6 h, background 6 h, drive start 24 h, manual always.

import Foundation

public struct FeedRefreshPolicy: Sendable {
    public enum Trigger: String, Sendable, Codable, Hashable {
        case foreground
        case background
        case driveStart
        case manual
    }

    public init() {}

    public func shouldRefresh(meta: FeedMeta, now: Date, trigger: Trigger) -> Bool {
        fatalError("lane: core")
    }
}
