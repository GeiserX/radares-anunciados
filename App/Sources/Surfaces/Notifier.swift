// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Time Sensitive local notifications, the visual surface of every warning (design 4.3): one on the Lock Screen at
// a time, drawn by iOS on the phone and, on iOS 18.4 or later with the app's icon on the CarPlay Home Screen, on
// the car screen (design 4.5). Also the daily red-health notice and the UNUserNotificationCenterDelegate the app
// delegate installs at launch.
//
// Authorization is asked with `authorizationOptions` (`[.alert, .sound, .carPlay]`; the `.timeSensitive` option is
// deprecated, the level comes from the entitlement). Every radar notification carries the `radar` category,
// registered with `allowInCarPlay`: the two things iOS requires before it mirrors a notification on the car
// screen. A driver with Driving Focus may not see these: speech is the surface that always arrives.
//
// A permission granted before 0.1.2, when the request had no `.carPlay`, reads `carPlaySetting == .notSupported`.
// `addCarPlayToGrantedAuthorization()` asks again at every launch and when the car connects: "Subsequent calls to
// this method don't prompt the person again", so the call should be silent and should record the missing option;
// Apple does not say it does, so VERIFY C10 confirms it on a real phone. If it does not, delete and reinstall the app.

import RadaresCore
import UIKit
import UserNotifications
import os

@MainActor
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = Notifier()

    /// Every radar notification shares this thread, so removing "the previous one" survives a relaunch.
    public nonisolated static let radarThread = "radar"
    public nonisolated static let healthThread = "health"
    /// The category of every radar notification, registered with `allowInCarPlay` so iOS draws it on the car screen.
    public nonisolated static let radarCategory = "radar"
    /// What every authorization request asks for: `.carPlay` is what lets the warning reach the CarPlay screen.
    public nonisolated static let authorizationOptions: UNAuthorizationOptions = [.alert, .sound, .carPlay]
    /// The sound of the radar notification beside the voice: a 150 ms tick, so it does not stack with the sentence.
    public nonisolated static let alertSoundName = "radar-tick.caf"
    private static let healthNoticeKey = "surfaces.healthNoticePostedAt"
    /// When the phone was last seen on CarPlay (the scene connected, or the audio route was the car): Estado's CarPlay row.
    public nonisolated static let carPlaySeenKey = "surfaces.carPlaySeenAt"

    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "notifications")

    private override init() {
        super.init()
    }

    /// The radar category, with the one option that matters: "Apps must be approved for CarPlay overall and then
    /// you must enable CarPlay for the notification types you want displayed".
    public nonisolated static func radarNotificationCategory() -> UNNotificationCategory {
        UNNotificationCategory(identifier: radarCategory, actions: [], intentIdentifiers: [], options: [.allowInCarPlay])
    }

    /// True when the person already allowed notifications but iOS has no CarPlay setting for the app: the grant
    /// predates the `.carPlay` option. A `.disabled` setting is the driver's own choice in Settings and stays.
    public nonisolated static func shouldAddCarPlay(status: UNAuthorizationStatus, carPlay: UNNotificationSetting) -> Bool {
        status == .authorized && carPlay == .notSupported
    }

    /// Re-asks with `authorizationOptions` when `shouldAddCarPlay` says so. Apple says no prompt appears; iOS should
    /// record the added option, which VERIFY C10 confirms (fallback: delete and reinstall the app). Logs the CarPlay
    /// setting before and after.
    public func addCarPlayToGrantedAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let before = await center.notificationSettings()
        guard Self.shouldAddCarPlay(status: before.authorizationStatus, carPlay: before.carPlaySetting) else { return }
        let granted = (try? await center.requestAuthorization(options: Self.authorizationOptions)) ?? false
        let after = await center.notificationSettings().carPlaySetting
        logger.notice("carPlay setting \(before.carPlaySetting.rawValue) -> \(after.rawValue), granted \(granted)")
    }

    /// Records that the phone is on CarPlay now (Estado's CarPlay row reads it).
    public nonisolated static func noteCarPlaySeen(_ now: Date = Date()) {
        UserDefaults.standard.set(now, forKey: carPlaySeenKey)
    }

    /// Registered at launch, before any warning can post.
    public func registerCategories() {
        UNUserNotificationCenter.current().setNotificationCategories([Self.radarNotificationCategory()])
    }

    /// The content of a radar notification: Time Sensitive, on the radar thread, in the CarPlay-enabled category,
    /// with the sound `sound(voiceEnabled:silent:)` decides.
    public nonisolated static func radarContent(_ phrase: Phrase, voiceEnabled: Bool, silent: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = phrase.title
        content.body = phrase.body
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1
        content.threadIdentifier = radarThread
        content.categoryIdentifier = radarCategory
        content.sound = sound(voiceEnabled: voiceEnabled, silent: silent)
        return content
    }

    /// Posts `phrase` as `<radarId>#<passSeq>`. Nil on success. A sounded post removes the previous radar's
    /// delivered notification first; a silent one removes nothing (`removedBeforePosting`).
    /// Never silent for a radar ahead: the 150 ms tick when the voice is on (speech can fail on a cold background
    /// launch or during a call, and a lit screen with no sound is a missed warning), the default sound when the
    /// driver turned the voice off. `silent` is a row that must not displace the real warning (the opposite
    /// carriageway, a held visual): shown, never sounded.
    public func post(_ phrase: Phrase, id: String, silent: Bool = false) async -> (any Error)? {
        let center = UNUserNotificationCenter.current()
        let error: (any Error)?
        let status = await center.notificationSettings().authorizationStatus
        if status == .denied || status == .notDetermined {
            error = NotifierError.notAuthorized(status.rawValue)
        } else {
            let content = Self.radarContent(phrase, voiceEnabled: AlertDispatcher.shared.voiceEnabled, silent: silent)
            let delivered = await center.deliveredNotifications()
                .map { (id: $0.request.identifier, thread: $0.request.content.threadIdentifier) }
            let stale = Self.removedBeforePosting(id, silent: silent, delivered: delivered)
            if !stale.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: stale)
            }
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

    /// The identifiers `removeRadarNotifications(except:radarID:)` removes from `delivered` (identifier, thread):
    /// radar-thread ones other than `keep`, and with `radarID` only that radar's (`<radarID>#<passSeq>`).
    nonisolated static func radarNotificationsToRemove(
        delivered: [(id: String, thread: String)], except keep: String? = nil, radarID: String? = nil
    ) -> [String] {
        delivered
            .filter { $0.thread == radarThread && $0.id != keep }
            .filter { request in radarID.map { request.id.hasPrefix("\($0)#") } ?? true }
            .map(\.id)
    }

    /// What posting `id` removes from `delivered` before it is added: every other radar's notification for a sounded
    /// post, nothing for a silent one. Events go out in distance order, so at twin cameras the farther one (often the
    /// other carriageway's) fires on the same or the next fix; if its silent row cleared the others, "Radar fijo a
    /// 800 m, sentido contrario" would replace the ticked warning for the radar ahead on the Lock Screen and the car
    /// screen. A silent row stays until its own pass or the next sounded post clears it.
    nonisolated static func removedBeforePosting(_ id: String, silent: Bool, delivered: [(id: String, thread: String)]) -> [String] {
        guard !silent else { return [] }
        return radarNotificationsToRemove(delivered: delivered, except: id)
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
        let delivered = await center.deliveredNotifications()
            .map { (id: $0.request.identifier, thread: $0.request.content.threadIdentifier) }
        let ids = Self.radarNotificationsToRemove(delivered: delivered, except: keep, radarID: radarID)
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

    /// What a notification does while the app is in the foreground, on the phone or on the car screen: a banner,
    /// in the list, with its sound. Without `.banner` iOS would hold it back from both screens while the app is open.
    public nonisolated static let foregroundPresentation: UNNotificationPresentationOptions = [.banner, .list, .sound]

    /// In the foreground a radar notification still shows as a banner: the self-test and a driver with the app open see it.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.foregroundPresentation
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
