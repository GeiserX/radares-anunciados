// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// When a Live Activity update is worth sending (design 2.7 and 4.2). Local updates are budgeted by the system and
// a refused one fails silently, so the card moves at milestones, never per fix: every phase change, a different
// radar, the distance crossing 1,000 / 750 / 500 / 250 / 100 m, the stretch remainder crossing a 500 m step, and
// otherwise at most every 60 s. Pure, so the rules can be checked without ActivityKit.

import Foundation
import RadaresCore

struct ActivityCadence: Sendable {
    enum Reason: String, Sendable {
        case first
        case alert
        case phase
        case target
        case note
        case milestone
        case stretchStep
        case idle
    }

    private(set) var lastSent: DriveContent?
    private(set) var lastSentAt: Date?

    /// The content as the card shows it: the distance snapped to the milestone just crossed (833 m shows 1,0 km,
    /// 700 m shows 750 m), the stretch remainder rounded up to its 500 m step. Updates then carry only what the
    /// card would show anyway, and two fixes inside one milestone produce equal content.
    static func display(_ content: DriveContent) -> DriveContent {
        var shown = content
        if let metres = content.distanceMetres {
            shown.distanceMetres = snappedDistance(metres)
        }
        if let remaining = content.stretchRemainingMetres {
            shown.stretchRemainingMetres = snappedRemaining(remaining)
        }
        return shown
    }

    /// The smallest milestone at or above `metres`; beyond the first milestone, rounded to 100 m.
    static func snappedDistance(_ metres: Int) -> Int {
        let milestones = Thresholds.cardMilestonesM.map { Int($0) }
        if let milestone = milestones.filter({ $0 >= metres }).min() {
            return milestone
        }
        return Int((Double(metres) / 100).rounded()) * 100
    }

    /// Rounded up to the next `Thresholds.stretchCardStepM`, so "8,5 km restantes" holds until 8,0 km is reached.
    static func snappedRemaining(_ metres: Int) -> Int {
        let step = Thresholds.stretchCardStepM
        return Int((Double(max(metres, 0)) / step).rounded(.up) * step)
    }

    /// Why `content` should be sent now, or nil when it should not. `content` is already `display(_:)`-ed.
    func reason(for content: DriveContent, alert: Bool, now: Date) -> Reason? {
        if alert { return .alert }
        guard let last = lastSent, let sentAt = lastSentAt else { return .first }
        if content.phase != last.phase { return .phase }
        if content.title != last.title || content.subtitle != last.subtitle || content.opposite != last.opposite
            || content.kindSymbol != last.kindSymbol || content.limit != last.limit {
            return .target
        }
        if content.note != last.note { return .note }
        if content.distanceMetres != last.distanceMetres { return .milestone }
        if content.stretchRemainingMetres != last.stretchRemainingMetres { return .stretchStep }
        if now.timeIntervalSince(sentAt) >= Thresholds.cardIdleSeconds { return .idle }
        return nil
    }

    mutating func record(_ content: DriveContent, at date: Date) {
        lastSent = content
        lastSentAt = date
    }

    /// Stale after 120 s, so a dead app shows as stale on the Lock Screen; 15 min while paused, a jam is not a dead app.
    static func staleDate(for content: DriveContent, now: Date) -> Date {
        content.phase == .paused
            ? now.addingTimeInterval(Thresholds.activityPausedStaleMinutes * 60)
            : now.addingTimeInterval(Thresholds.activityStaleSeconds)
    }
}
