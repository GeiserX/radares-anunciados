// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Time Sensitive local notifications, one on the Lock Screen at a time (design 4.3), the daily red-health notice,
// and the UNUserNotificationCenterDelegate the app delegate installs at launch.

import RadaresCore
import UserNotifications

@MainActor
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = Notifier()

    private override init() {
        super.init()
    }

    /// Posts `phrase` as `<radarId>#<passSeq>` and removes the previous radar's delivered notification. Nil on success.
    public func post(_ phrase: Phrase, id: String) async -> (any Error)? {
        fatalError("lane: surfaces")
    }

    /// Plain (.active) notice, at most once per Thresholds.healthNoticeHours while the app is closed and red.
    public func postHealthNotice(_ text: String) {
        fatalError("lane: surfaces")
    }
}
