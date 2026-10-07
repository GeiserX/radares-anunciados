// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Every AlertEvent goes through here to speech and the notification (design 4). Nothing has to be started or
// left on screen: the app wakes itself, warns by voice and posts a Time Sensitive notification, like a
// notification app. A missing surface changes nothing upstream; the sink outcomes go to the log on every alert.
//
// What each event does:
//   .warn(.full), .stretchEntered   speech + the Time Sensitive notification; one `alert` log row with the sink outcomes
//   .warn(.visual)                  the notification without the voice (sentido contrario, pacing gap); an `alert` row
//   .passed                         that radar's notification is removed
//   .stretchExited                  "Fin de tramo" when the core phrased it (dropped if anything is speaking)
//   .driveEnded                     the once-per-drive audio session is released
// This lane writes the `alert`, `speech` and `notificationPosted` rows. `passed`, `stretchEntered`,
// `stretchExited` and `driveEnded` rows are the location lane's, which has the fix and the exit reason.

import Foundation
import RadaresCore
import UserNotifications
import os

@MainActor
public final class AlertDispatcher {
    public static let shared = AlertDispatcher()

    private static let voiceKey = "surfaces.voiceEnabled"
    private static let passSeqKey = "surfaces.passSeq"

    /// The one setting: voice on/off. Kept across launches.
    public var voiceEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.voiceKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.voiceKey) }
    }

    private let speech = SpeechAnnouncer.shared
    private let notifier = Notifier.shared
    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "dispatch")

    private init() {}

    /// `fix` is the fix the event was decided on: its position and speed go into the `alert` row. Without it the
    /// row carries the radar's gate and the content's speed.
    public func handle(_ event: AlertEvent, at fix: Fix? = nil) async {
        switch event.kind {
        case .warn(let level):
            await alert(event, level: level, fix: fix)
        case .stretchEntered:
            // The level the core meant: a paced entry carries no sentence and is a visual row, like a paced point.
            await alert(event, level: event.phrase == nil ? .visual : .full, fix: fix)
        case .passed:
            if let id = event.radar?.id {
                await notifier.removeRadarNotifications(radarID: id)
            }
        case .stretchExited:
            if voiceEnabled, let phrase = event.phrase {
                _ = await speech.speak(phrase, as: .exit)
            }
        case .driveEnded:
            await speech.endDrive()
        }
    }

    /// Called by the location lane at the first fix of a drive: the once-per-drive audio fallback takes its session here.
    public func driveDidStart() async {
        await speech.beginDrive()
    }

    private func alert(_ event: AlertEvent, level: Level, fix: Fix?) async {
        let phrase = level == .full ? event.phrase : nil
        let text = Self.notificationPhrase(for: event, level: level, locale: .autoupdatingCurrent)
        // The two sinks run side by side: a slow audio session never holds back the banner.
        async let spoken = speakIfWanted(phrase)
        async let posted = post(text, for: event)
        let sinks = [await spoken, await posted].compactMap { $0 }

        let radar = event.radar
        let speed = fix?.speed ?? event.content.speedKmh.map { Double($0) / 3.6 }
        AppLog.shared.post(.alert(
            id: radar?.id ?? "",
            level: level,
            distance: event.distance ?? Double(event.content.distanceMetres ?? 0),
            speedMps: speed,
            late: event.late,
            crossTrackMetres: event.crossTrackMetres,
            suppressedByDirection: level == .visual && event.content.opposite,
            coordinate: fix?.coordinate ?? radar?.start ?? Coordinate(latitude: 0, longitude: 0),
            sinks: sinks,
            // The sentence only when the voice took it: with the voice off the row must not claim the driver heard it.
            spoken: sinks.contains { $0.sink == .speech && $0.ok } ? phrase?.spoken : nil
        ))
        let summary = sinks.map { "\($0.sink.rawValue)=\($0.ok)" }.joined(separator: " ")
        logger.notice("alert \(radar?.id ?? "-", privacy: .public) \(level.rawValue, privacy: .public) \(summary, privacy: .public)")
    }

    private func speakIfWanted(_ phrase: Phrase?) async -> SinkOutcome? {
        guard let phrase, voiceEnabled else { return nil }
        return await speech.speak(phrase).sink
    }

    /// The Time Sensitive notification, unconditional: every warning posts one, silent for a radar of the opposite flow.
    private func post(_ phrase: Phrase?, for event: AlertEvent) async -> SinkOutcome? {
        guard let phrase else { return nil }
        let error = await notifier.post(phrase, id: notificationID(for: event), silent: event.content.opposite)
        return SinkOutcome(sink: .notification, ok: error == nil, detail: error.map { String(describing: $0) })
    }

    /// The notification's text. A `.full` warning carries the core's phrase. A `.visual` one has no sentence (the
    /// engine phrases only what is spoken), so its title and body come from the same `Phrasing` rules, with
    /// "sentido contrario" in the title when the radar is for the other carriageway; the `spoken` field stays empty.
    /// Nil when nothing can be said about the event (no radar).
    nonisolated static func notificationPhrase(for event: AlertEvent, level: Level, locale: Locale) -> Phrase? {
        if level == .full, let phrase = event.phrase { return phrase }
        guard event.radar != nil else { return nil }
        let made = Phrasing.make(event, locale: locale)
        guard !made.title.isEmpty else { return nil }
        let opposite = event.content.opposite
        let suffix = Phrasing.isEnglish(locale) ? ", opposite direction" : ", sentido contrario"
        return Phrase(spoken: "", title: opposite ? made.title + suffix : made.title, body: made.body)
    }

    /// `<radarId>#<passSeq>`: unique per pass, so a later pass of the same radar is a new notification.
    private func notificationID(for event: AlertEvent) -> String {
        let defaults = UserDefaults.standard
        let seq = defaults.integer(forKey: Self.passSeqKey) + 1
        defaults.set(seq, forKey: Self.passSeqKey)
        return "\(event.radar?.id ?? "radar")#\(seq)"
    }
}

// MARK: Self-test

extension AlertDispatcher {
    /// Launch argument that runs the surfaces self-test: `-SurfacesSelfTest 1` posts a synthetic fixed-radar warning
    /// through `handle(_:)` (speech and the Time Sensitive notification), then the pass that removes it.
    public static let selfTestKey = "SurfacesSelfTest"

    /// Call once from `application(_:didFinishLaunchingWithOptions:)`. It creates the surfaces at launch, so the
    /// speech log can tell a foreground process from one launched purely in the background, and runs the
    /// self-test when the launch argument asks for it. The self-test uses no engine and no feed: a hand-built
    /// event goes through `handle(_:)`, the same path a real warning takes.
    public static func runSelfTestIfRequested() {
        let dispatcher = shared
        guard UserDefaults.standard.integer(forKey: selfTestKey) > 0 else { return }
        Task { await dispatcher.runSelfTest() }
    }

    private func runSelfTest() async {
        logger.notice("self-test: start")
        let center = UNUserNotificationCenter.current()
        // Onboarding asks for real; a self-test on a fresh install takes provisional authorization so it runs
        // unattended (no prompt to tap). Provisional notifications are delivered quietly to the Notification Center.
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: Notifier.authorizationOptions.union(.provisional))) ?? false
            logger.notice("self-test: provisional notification authorization \(granted)")
        }

        let radar = Radar(
            id: "self-test", kind: .fixed, role: .point,
            start: Coordinate(latitude: 41.30326, longitude: -1.94488),
            name: String(localized: "Radar de prueba", table: "Surfaces"),
            road: "A-2", kmFrom: 202.3, maxspeed: 90, directionText: "ZARAGOZA",
            source: "self-test", attribution: ""
        )
        let title = String(localized: "Radar fijo", table: "Surfaces")
        let subtitle = "A-2 km 202,3"
        func content(_ phase: DrivePhase, _ metres: Int?) -> DriveContent {
            DriveContent(
                phase: phase, kindSymbol: "camera.fill", title: title, subtitle: subtitle,
                distanceMetres: metres, limit: 90, speedKmh: 120, updatedAt: Date()
            )
        }

        let phrase = Phrase(
            spoken: String(localized: "Radar fijo a 600 metros, sentido Zaragoza. Límite 90.", table: "Surfaces"),
            title: String(localized: "Radar fijo a 600 m", table: "Surfaces"),
            body: String(localized: "A-2 km 202,3 · límite 90 km/h", table: "Surfaces")
        )
        await handle(AlertEvent(
            kind: .warn(.full), radar: radar, distance: 600, crossTrackMetres: 4, phrase: phrase,
            content: content(.alert, 600)
        ))

        let delivered = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == Notifier.radarThread }
        let timeSensitive = delivered.first?.request.content.interruptionLevel == .timeSensitive
        logger.notice("self-test: delivered radar notifications \(delivered.count), time sensitive \(timeSensitive)")

        // The pass removes this radar's notification and leaves any other radar's.
        try? await Task.sleep(for: .seconds(4))
        await handle(AlertEvent(kind: .passed, radar: radar, content: content(.passed, nil)))
        let left = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == Notifier.radarThread }
        logger.notice("self-test: radar notifications after pass \(left.count)")
        logger.notice("self-test: done")
    }
}
