// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The pure rules of the surfaces: the notification's sound, and the text a warning without a sentence (a `.visual`
// row) posts, since the notification is the visual surface of every warning and nothing has to be on screen.

import RadaresCore
import UserNotifications
import XCTest
@testable import RadaresAnunciados

final class SurfacesRulesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let es = Locale(identifier: "es_ES")
    private let en = Locale(identifier: "en_GB")

    private var radar: Radar {
        Radar(
            id: "a2", kind: .fixed, role: .point, start: Coordinate(latitude: 41.30326, longitude: -1.94488),
            name: "A-2 km 202,3", road: "A-2", kmFrom: 202.3, maxspeed: 90, directionText: "ZARAGOZA",
            source: "dgt", attribution: ""
        )
    }

    private func event(_ level: Level, opposite: Bool, phrase: Phrase? = nil) -> AlertEvent {
        AlertEvent(
            kind: .warn(level), radar: radar, distance: 812, crossTrackMetres: 3, phrase: phrase,
            content: DriveContent(phase: .alert, kindSymbol: "camera.fill", title: "Radar fijo", subtitle: "A-2 km 202,3", distanceMetres: 812, limit: 90, opposite: opposite, updatedAt: t0)
        )
    }

    /// The notification is never silent for a radar ahead: with the voice on it carries the tick, so a failed speech
    /// on a cold background launch still makes a sound; the default sound with the voice off. A radar of the
    /// opposite flow is shown without a sound.
    func testTheRadarNotificationAlwaysHasASoundForARadarAhead() {
        XCTAssertEqual(Notifier.sound(voiceEnabled: true), UNNotificationSound(named: UNNotificationSoundName(Notifier.alertSoundName)))
        XCTAssertEqual(Notifier.sound(voiceEnabled: false), .default)
        XCTAssertNil(Notifier.sound(voiceEnabled: true, silent: true), "sentido contrario: shown, never sounded")
        XCTAssertNil(Notifier.sound(voiceEnabled: false, silent: true))
        XCTAssertNotNil(Bundle.main.url(forResource: "radar-tick", withExtension: "caf"), "the tick ships in the app bundle")
    }

    /// A `.full` warning posts the core's phrase as it is: the same title and body the route vectors assert.
    func testAFullWarningPostsTheCorePhrase() {
        let phrase = Phrase(spoken: "Radar fijo a 800 metros, sentido Zaragoza. Límite 90.", title: "Radar fijo a 800 m", body: "A-2 km 202,3 · límite 90 km/h · sentido Zaragoza")
        XCTAssertEqual(AlertDispatcher.notificationPhrase(for: event(.full, opposite: false, phrase: phrase), level: .full, locale: es), phrase)
    }

    /// A `.visual` warning has no sentence from the engine, yet it posts: the title and body follow the same
    /// phrasing rules, "sentido contrario" is added for the other carriageway, and nothing is marked as spoken.
    func testAVisualWarningPostsANotificationWithoutAVoice() throws {
        let opposite = try XCTUnwrap(AlertDispatcher.notificationPhrase(for: event(.visual, opposite: true), level: .visual, locale: es))
        XCTAssertEqual(opposite.title, "Radar fijo a 800 m, sentido contrario")
        XCTAssertEqual(opposite.body, "A-2 km 202,3 · límite 90 km/h · sentido Zaragoza")
        XCTAssertEqual(opposite.spoken, "", "nothing is said for a visual row")

        let paced = try XCTUnwrap(AlertDispatcher.notificationPhrase(for: event(.visual, opposite: false), level: .visual, locale: es))
        XCTAssertEqual(paced.title, "Radar fijo a 800 m", "a radar ahead demoted by pacing is a plain title")

        let english = try XCTUnwrap(AlertDispatcher.notificationPhrase(for: event(.visual, opposite: true), level: .visual, locale: en))
        XCTAssertEqual(english.title, "Fixed speed camera in 800 m, opposite direction")

        let noRadar = AlertEvent(kind: .driveEnded, content: .watching(at: t0))
        XCTAssertNil(AlertDispatcher.notificationPhrase(for: noRadar, level: .visual, locale: es), "nothing to post without a radar")
    }

    /// Twin cameras: the full warning for the radar ahead is on screen, then the opposite carriageway's camera 30 m
    /// beyond posts its silent row on the next fix. The silent row removes nothing, so the ticked warning stays on the
    /// Lock Screen and the car screen. Positive control: a sounded post for B does clear A, as before.
    func testASilentPostNeverRemovesTheWarningAlreadyOnScreen() {
        let delivered: [(id: String, thread: String)] = [("osm-a#1", Notifier.radarThread), ("health", Notifier.healthThread)]
        XCTAssertEqual(Notifier.removedBeforePosting("osm-b#1", silent: true, delivered: delivered), [], "the silent row leaves A's warning delivered")
        XCTAssertEqual(Notifier.removedBeforePosting("osm-b#1", silent: false, delivered: delivered), ["osm-a#1"], "a sounded post still clears the previous radar")
        XCTAssertEqual(Notifier.removedBeforePosting("osm-a#1", silent: false, delivered: delivered), [], "a radar's own row and the health notice stay")
    }

    /// The passed path removes only that radar's rows, silent or not; another radar's warning stays.
    func testPassingARadarRemovesOnlyItsOwnRows() {
        let delivered: [(id: String, thread: String)] = [("osm-a#1", Notifier.radarThread), ("osm-b#2", Notifier.radarThread), ("osm-ab#1", Notifier.radarThread)]
        XCTAssertEqual(Notifier.radarNotificationsToRemove(delivered: delivered, radarID: "osm-b"), ["osm-b#2"])
    }
}
