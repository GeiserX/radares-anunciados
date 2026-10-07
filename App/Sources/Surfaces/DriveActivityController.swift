// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// start / update / alert / end / reattach of the one Live Activity (design 4.2): milestone cadence, content read
// back after every update (activityUpdated(dropped:)), staleDate 120 s (15 min paused), end .after(5 min).
//
// Callers: the location lane sends the engine's card after every fix through `update(_:alert:)` and this class
// decides what reaches the system (ActivityCadence); AlertDispatcher sends alerts and the drive end; the intents
// and the foreground start the activity. `Activity` is not Sendable, so it never leaves the static helpers below:
// this class keeps only the activity id.

import ActivityKit
import Foundation
import RadaresCore
import os

@MainActor
public final class DriveActivityController {
    public static let shared = DriveActivityController()

    /// The sound of a Live Activity alert: a 150 ms tick, so it does not stack with the voice.
    public static let alertSoundName = "radar-tick.caf"

    /// The id of the running activity, kept across launches so `reattach()` can adopt it.
    private static let activityIDKey = "surfaces.activityID"

    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "activity")
    private var currentID: String?
    private var cadence = ActivityCadence()

    private init() {}

    /// The running activity, nil when none runs or the user dismissed it (the notification takes over then).
    public var current: Activity<DriveAttributes>? {
        guard let id = currentID else { return nil }
        return Self.live(id: id)
    }

    /// Whether the system lets this app show Live Activities at all (Estado's "Pantalla del coche").
    public var activitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Foreground or LiveActivityIntent only: `Activity.request` refuses the background with `.visibility`.
    /// Does nothing when an activity already runs.
    public func start(content: DriveContent) throws {
        if current != nil { return }
        let now = Date()
        let shown = ActivityCadence.display(content)
        do {
            guard activitiesEnabled else { throw ActivityStartError.disabled }
            let activity = try Activity.request(
                attributes: DriveAttributes(startedAt: now),
                content: ActivityContent(
                    state: DriveAttributes.ContentState(shown),
                    staleDate: ActivityCadence.staleDate(for: shown, now: now)
                ),
                pushType: nil
            )
            currentID = activity.id
            UserDefaults.standard.set(activity.id, forKey: Self.activityIDKey)
            cadence = ActivityCadence()
            cadence.record(shown, at: now)
            AppLog.shared.post(.activityStarted)
            logger.notice("activity started \(activity.id, privacy: .public)")
        } catch {
            AppLog.shared.post(.activityFailed(error: String(describing: error)))
            logger.error("activity start failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Sends `content` when the cadence says it changes what the card shows, or always when `alert` is set: an
    /// alert lights the screen, expands the Dynamic Island and plays the tick. Returns false when no activity runs,
    /// true otherwise (including when the cadence decided nothing needed sending). Whether the system showed it is
    /// checked afterwards by reading the content back, logged as `activityUpdated(dropped:)`.
    @discardableResult
    public func update(_ content: DriveContent, alert: Phrase?) async -> Bool {
        guard let id = currentID, current != nil else { return false }
        let now = Date()
        let shown = ActivityCadence.display(content)
        guard let reason = cadence.reason(for: shown, alert: alert != nil, now: now) else { return true }
        cadence.record(shown, at: now)
        let alertConfiguration = alert.map {
            AlertConfiguration(
                title: LocalizedStringResource(stringLiteral: $0.title),
                body: LocalizedStringResource(stringLiteral: $0.body),
                sound: .named(Self.alertSoundName)
            )
        }
        let sent = await Self.send(
            id: id,
            state: DriveAttributes.ContentState(shown),
            staleDate: ActivityCadence.staleDate(for: shown, now: now),
            alert: alertConfiguration
        )
        logger.info("activity update \(reason.rawValue, privacy: .public) sent \(sent)")
        return sent
    }

    /// Ends the drive's activity with `content` (the last card when nil); it lingers on the Lock Screen for
    /// `Thresholds.activityDismissMinutes`, CarPlay and the Dynamic Island drop it at once.
    public func end(content: DriveContent? = nil) async {
        guard let id = currentID else { return }
        currentID = nil
        UserDefaults.standard.removeObject(forKey: Self.activityIDKey)
        let state = (content.map(ActivityCadence.display) ?? cadence.lastSent).map(DriveAttributes.ContentState.init)
        cadence = ActivityCadence()
        let dismissal = Date().addingTimeInterval(Thresholds.activityDismissMinutes * 60)
        await Self.finish(id: id, state: state, policy: .after(dismissal))
        logger.notice("activity ended \(id, privacy: .public)")
    }

    /// Launch step 5 (design 3.3): adopt the activity this app started if it is still alive and a drive is still on
    /// (`driveIsOn`: the location lane's persisted drive), end every other one. Decided synchronously at launch, before
    /// any scene or intent can ask for an activity, so nothing races with the end of a stale one.
    public func reattach(driveIsOn: Bool) {
        let savedID = UserDefaults.standard.string(forKey: Self.activityIDKey)
        currentID = nil
        for activity in Activity<DriveAttributes>.activities {
            if driveIsOn, activity.id == savedID, Self.isLive(activity.activityState) {
                currentID = activity.id
            } else {
                let id = activity.id
                Task { await Self.finish(id: id, state: nil, policy: .immediate) }
            }
        }
        if currentID == nil {
            UserDefaults.standard.removeObject(forKey: Self.activityIDKey)
        }
        cadence = ActivityCadence()
        logger.notice("reattach: \(self.currentID ?? "none", privacy: .public), drive on \(driveIsOn)")
    }

    // MARK: ActivityKit, kept off the main actor's state (Activity is not Sendable)

    private nonisolated static func isLive(_ state: ActivityState) -> Bool {
        state == .active || state == .stale
    }

    private nonisolated static func live(id: String) -> Activity<DriveAttributes>? {
        Activity<DriveAttributes>.activities.first { $0.id == id && isLive($0.activityState) }
    }

    /// How long the read-back waits for the system to show the content sent: the local copy of `activity.content`
    /// trails `update` by a moment (measured in the simulator: the read straight after the await is the previous
    /// content), so a single immediate read would call every update dropped.
    private nonisolated static let readBackWindow: Duration = .seconds(2)

    /// Sends the update; returns false when the activity is gone. The read-back runs detached and logs
    /// `activityUpdated(dropped:)`, so no caller waits for it.
    private nonisolated static func send(
        id: String,
        state: DriveAttributes.ContentState,
        staleDate: Date,
        alert: AlertConfiguration?
    ) async -> Bool {
        guard let activity = live(id: id) else { return false }
        await activity.update(ActivityContent(state: state, staleDate: staleDate), alertConfiguration: alert)
        Task.detached(priority: .utility) {
            let dropped = await readBackDropped(id: id, state: state)
            AppLog.shared.post(.activityUpdated(dropped: dropped))
            if dropped {
                Logger(subsystem: "io.github.geiserx.radares", category: "activity")
                    .error("activity update dropped: \(String(describing: state), privacy: .public)")
            }
        }
        return true
    }

    /// True when the activity's content has not become `state` within `readBackWindow`, or a newer update replaced it
    /// first (then this one may never have shown; the newer one is checked on its own).
    private nonisolated static func readBackDropped(id: String, state: DriveAttributes.ContentState) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: readBackWindow)
        while clock.now < deadline {
            guard let activity = live(id: id) else { return true }
            let shown = activity.content.state
            if shown == state { return false }
            if shown.updatedAt > state.updatedAt { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    private nonisolated static func finish(
        id: String,
        state: DriveAttributes.ContentState?,
        policy: ActivityUIDismissalPolicy
    ) async {
        guard let activity = Activity<DriveAttributes>.activities.first(where: { $0.id == id }) else { return }
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        await activity.end(content, dismissalPolicy: policy)
    }
}

public enum ActivityStartError: Error, CustomStringConvertible {
    /// Live Activities are off for this app in Settings.
    case disabled

    public var description: String {
        switch self {
        case .disabled: "Live Activities disabled"
        }
    }
}

extension DriveAttributes.ContentState {
    /// Field by field from the core's `DriveContent`; the phases share raw values.
    init(_ content: DriveContent) {
        let updatedAt = Date(timeIntervalSinceReferenceDate: content.updatedAt.timeIntervalSinceReferenceDate.rounded(.down))
        self.init(
            phase: DriveAttributes.Phase(rawValue: content.phase.rawValue) ?? .degraded,
            kindSymbol: content.kindSymbol,
            title: content.title,
            subtitle: content.subtitle,
            distanceMetres: content.distanceMetres,
            limit: content.limit,
            speedKmh: content.speedKmh,
            opposite: content.opposite,
            stretchRemainingMetres: content.stretchRemainingMetres,
            avgKmh: content.avgKmh,
            note: content.note,
            updatedAt: updatedAt
        )
    }
}
