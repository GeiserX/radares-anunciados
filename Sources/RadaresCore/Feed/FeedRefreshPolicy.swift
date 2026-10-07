// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// When to ask for the feed (design 5.2): foreground 6 h, background 6 h, drive start 24 h, manual always.
// Staleness never disables alerts; this only decides whether to spend a request.

import Foundation

public struct FeedRefreshPolicy: Sendable {
    public enum Trigger: String, Sendable, Codable, Hashable {
        case foreground
        case background
        case driveStart
        case manual
    }

    public init() {}

    /// Hours the feed may be old before `trigger` asks for it again; nil means always.
    public static func maxAgeHours(for trigger: Trigger) -> Double? {
        switch trigger {
        case .foreground: Thresholds.refreshForegroundHours
        case .background: Thresholds.refreshBackgroundHours
        case .driveStart: Thresholds.refreshDriveStartHours
        case .manual: nil
        }
    }

    public func shouldRefresh(meta: FeedMeta, now: Date, trigger: Trigger) -> Bool {
        guard let hours = Self.maxAgeHours(for: trigger) else { return true }
        guard let fetchedAt = meta.fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= hours * 3600
    }
}
