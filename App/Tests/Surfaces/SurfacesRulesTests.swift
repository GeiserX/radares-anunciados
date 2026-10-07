// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The pure rules of the surfaces: which update the read-back still waits for, when the notification takes over
// from the card, the notification's sound, and the first card of an activity started while paused.

import RadaresCore
import UserNotifications
import XCTest
@testable import RadaresAnunciados

final class SurfacesRulesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(_ title: String, seq: Int, at t: Date? = nil) -> DriveAttributes.ContentState {
        DriveAttributes.ContentState(phase: .alert, kindSymbol: "camera.fill", title: title, subtitle: "A-2", distanceMetres: 600, updatedAt: t ?? t0, seq: seq)
    }

    /// Two cards of one fix share a second: the read-back of the first must count the second as "superseded", not as
    /// the first one dropped; an older card still showing means the sent one has not arrived yet.
    func testReadBackStopsWaitingWhenTheSameOrALaterUpdateShows() {
        let sent = state("Radar fijo", seq: 5)
        XCTAssertFalse(DriveActivityController.stillWaiting(shown: sent, sent: sent))
        XCTAssertFalse(DriveActivityController.stillWaiting(shown: state("Radar superado", seq: 6), sent: sent), "a later update of the same second replaced it")
        XCTAssertTrue(DriveActivityController.stillWaiting(shown: state("Radar fijo", seq: 4), sent: sent), "the previous card is still up")
        XCTAssertTrue(DriveActivityController.stillWaiting(shown: state("Radar fijo", seq: 4, at: t0.addingTimeInterval(1)), sent: sent), "a timestamp never decides it")
    }

    /// No activity, or one that was gone when the update was sent: the Time Sensitive notification is the surface.
    func testTheNotificationTakesOverWhenTheCardDidNotShow() {
        XCTAssertTrue(AlertDispatcher.notificationTakesOver(activityShown: nil))
        XCTAssertTrue(AlertDispatcher.notificationTakesOver(activityShown: false))
        XCTAssertFalse(AlertDispatcher.notificationTakesOver(activityShown: true))
    }

    /// The notification is never silent: with the voice on it carries the tick the Live Activity alert uses, so a
    /// failed speech on a cold background launch still makes a sound.
    func testTheRadarNotificationAlwaysHasASound() {
        XCTAssertEqual(Notifier.sound(voiceEnabled: true), UNNotificationSound(named: UNNotificationSoundName(DriveActivityController.alertSoundName)))
        XCTAssertEqual(Notifier.sound(voiceEnabled: false), .default)
        XCTAssertNotNil(Bundle.main.url(forResource: "radar-tick", withExtension: "caf"), "the tick ships in the app bundle")
    }

    /// An activity started from the foreground while the drive is paused begins as the paused card (15 min stale,
    /// "En pausa"), not as "Sin radares cerca" that goes stale in two minutes with nothing to refresh it.
    func testTheFirstCardOfAnActivityStartedWhilePausedIsThePausedCard() async {
        let paused: DriveContent = {
            var c = DriveContent.watching(at: t0)
            c.phase = .paused
            return c
        }()
        let pausedCard: @Sendable () async -> DriveContent = { paused }
        let whilePaused = await AppModel.activityStartContent(for: .paused(since: t0), paused: pausedCard)?()
        XCTAssertEqual(whilePaused?.phase, .paused)
        XCTAssertEqual(whilePaused.map { ActivityCadence.staleDate(for: $0, now: t0) }, t0.addingTimeInterval(Thresholds.activityPausedStaleMinutes * 60))
        let whileDriving = await AppModel.activityStartContent(for: .driving, paused: pausedCard)?()
        XCTAssertEqual(whileDriving?.phase, .watching)
        XCTAssertNil(AppModel.activityStartContent(for: .idle, paused: pausedCard))
        XCTAssertNil(AppModel.activityStartContent(for: .probing, paused: pausedCard))
    }
}
