// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Time Sensitive local notifications, the visual surface of every warning (design 4.3): one on the Lock Screen at
// a time, drawn by iOS on the phone and, once the CarPlay entitlement exists, on the car screen. Also the daily
// red-health notice and the UNUserNotificationCenterDelegate the app delegate installs at launch.
//
// Authorization is asked by onboarding with `[.alert, .sound]` (the `.timeSensitive` option is deprecated; the
// level comes from the entitlement). A driver with Driving Focus may not see these: speech is the surface that
// always arrives.

import RadaresCore
import UIKit
import UserNotifications
import os

@MainActor
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = Notifier()

    /// Every radar notification shares this thread, so removing "the previous one" survives a relaunch.
    public static let radarThread = "radar"
    public static let healthThread = "health"
    /// The sound of the radar notification beside the voice: a 150 ms tick, so it does not stack with the sentence.
    public nonisolated static let alertSoundName = "radar-tick.caf"
    private static let healthNoticeKey = "surfaces.healthNoticePostedAt"

    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "notifications")

    private override init() {
        super.init()
    }

    /// Posts `phrase` as `<radarId>#<passSeq>` and removes the previous radar's delivered notification. Nil on success.
    /// Never silent for a radar ahead: the 150 ms tick when the voice is on (speech can fail on a cold background
    /// launch or during a call, and a lit screen with no sound is a missed warning), the default sound when the
    /// driver turned the voice off. `silent` is the opposite-carriageway row: shown, never sounded.
    public func post(_ phrase: Phrase, id: String, silent: Bool = false) async -> (any Error)? {
        let center = UNUserNotificationCenter.current()
        let error: (any Error)?
        let status = await center.notificationSettings().authorizationStatus
        if status == .denied || status == .notDetermined {
            error = NotifierError.notAuthorized(status.rawValue)
        } else {
            let content = UNMutableNotificationContent()
            content.title = phrase.title
            content.body = phrase.body
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1
            content.threadIdentifier = Self.radarThread
            content.sound = Self.sound(voiceEnabled: AlertDispatcher.shared.voiceEnabled, silent: silent)
            await removeRadarNotifications(except: id)
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                error = nil
            } catch let failure {
                error = failure
            }
        }
        AppLog.shared.post(.notificationPosted(id: id, error: error.map { String(describing: $0) }))
        if let error {
            logger.error("notification \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        } else {
            logger.notice("notification \(id, privacy: .public) posted")
        }
        return error
    }

    /// The radar notification's sound: the tick beside the voice, the default sound without it; nil only for a
    /// silent (opposite direction) row.
    nonisolated static func sound(voiceEnabled: Bool, silent: Bool = false) -> UNNotificationSound? {
        if silent { return nil }
        return voiceEnabled ? UNNotificationSound(named: UNNotificationSoundName(alertSoundName)) : .default
    }

    /// Removes delivered radar notifications: every one but `keep` before the next radar is posted, or only those of
    /// `radarID` when that radar is passed (a later radar's notification stays).
    public func removeRadarNotifications(except keep: String? = nil, radarID: String? = nil) async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.deliveredNotifications()
            .map(\.request)
            .filter { $0.content.threadIdentifier == Self.radarThread && $0.identifier != keep }
            .filter { request in radarID.map { request.identifier.hasPrefix("\($0)#") } ?? true }
            .map(\.identifier)
        if !ids.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Plain (.active) notice, at most once per Thresholds.healthNoticeHours while the app is closed and red.
    /// The caller decides it is red (a wake-up or a BG refresh run); this enforces "closed" and "once a day".
    public func postHealthNotice(_ text: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let defaults = UserDefaults.standard
        let now = Date()
        if let last = defaults.object(forKey: Self.healthNoticeKey) as? Date,
           now.timeIntervalSince(last) < Thresholds.healthNoticeHours * 3600 {
            return
        }
        defaults.set(now, forKey: Self.healthNoticeKey)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Radares Anunciados", table: "Surfaces")
        content.body = text
        content.interruptionLevel = .active
        content.threadIdentifier = Self.healthThread
        content.sound = .default
        let id = "health"
        Task {
            var failure: String?
            do {
                try await UNUserNotificationCenter.current()
                    .add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            } catch {
                failure = String(describing: error)
            }
            AppLog.shared.post(.notificationPosted(id: id, error: failure))
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// In the foreground a radar notification still shows as a banner: the self-test and a driver with the app open see it.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {}
}

public enum NotifierError: Error, CustomStringConvertible {
    /// `UNAuthorizationStatus` raw value: 0 not determined, 1 denied.
    case notAuthorized(Int)

    public var description: String {
        switch self {
        case .notAuthorized(let status): "notifications not authorized (status \(status))"
        }
    }
}
