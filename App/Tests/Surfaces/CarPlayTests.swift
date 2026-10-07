// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The pure parts of the CarPlay surface (design 4.5): what the information template shows for a snapshot, the
// idle strings, the 10 s refresh throttle, and the two notification facts iOS needs before it mirrors a warning
// on the car screen: the `.carPlay` authorization option and the radar category with `allowInCarPlay`.

import RadaresCore
import UserNotifications
import XCTest
@testable import RadaresAnunciados

final class CarPlayTests: XCTestCase {
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

    private func snapshot(next: Radar?, distance: Double?, opposite: Bool = false, stretch: DriveSnapshot.StretchState? = nil) -> DriveSnapshot {
        DriveSnapshot(
            next: next, distanceMetres: distance, stretch: stretch,
            content: DriveContent(phase: next == nil ? .watching : .approaching, kindSymbol: "camera.fill", title: "", subtitle: "", opposite: opposite, updatedAt: t0)
        )
    }

    private let allGreen = [HealthItem(status: .ok, title: HealthTitles.location, detail: "")]

    /// The next radar as the card shows it: kind and road, the distance rounded as the voice rounds it (812 m is
    /// said as 800), the limit when the feed publishes one. Never the exact metres: the template is no countdown.
    func testTheNextRadarRowsFollowTheVoiceRounding() {
        let content = CarPlayContent.make(snapshot: snapshot(next: radar, distance: 812), report: allGreen, locale: es)
        XCTAssertEqual(content.rows, [
            .init(label: "Radar fijo", detail: "A-2 km 202,3"),
            .init(label: "Distancia", detail: "800 m"),
            .init(label: "Límite", detail: "90 km/h"),
        ])
        XCTAssertEqual(CarPlayContent.title, "Radares Anunciados")

        let english = CarPlayContent.make(snapshot: snapshot(next: radar, distance: 812), report: allGreen, locale: en)
        XCTAssertEqual(english.rows.map(\.label), ["Fixed speed camera", "Distance", "Limit"])
        XCTAssertEqual(english.rows[0].detail, "A-2 km 202.3")
    }

    /// A radar for the other carriageway says so in the kind line, like its silent notification does.
    func testAnOppositeRadarIsLabelledSentidoContrario() {
        let content = CarPlayContent.make(snapshot: snapshot(next: radar, distance: 812, opposite: true), report: allGreen, locale: es)
        XCTAssertEqual(content.rows.first?.label, "Radar fijo, sentido contrario")
    }

    /// Inside a stretch the row is the remaining length, marked approximate, instead of a distance to a gate.
    func testInsideAStretchTheRowIsTheRemainingLength() {
        let section = Radar(
            id: "n232", kind: .section, role: .averageSpeedSection, start: Coordinate(latitude: 40.51793, longitude: 0.13277),
            end: Coordinate(latitude: 40.51235, longitude: 0.24688), name: "N-232", road: "N-232", kmFrom: 60, maxspeed: 90,
            source: "dgt", attribution: ""
        )
        let stretch = DriveSnapshot.StretchState(radar: section, enteredAt: t0, entryGate: section.start, remainingMetres: 3_480)
        let content = CarPlayContent.make(snapshot: snapshot(next: section, distance: 3_480, stretch: stretch), report: allGreen, locale: es)
        XCTAssertEqual(content.rows[1], .init(label: "Quedan", detail: "aprox. 3 kilómetros"))
    }

    /// No drive: the screen says it is waiting. A drive with nothing ahead: "Sin radares cerca". Neither carries a
    /// distance or a limit row.
    func testTheIdleStrings() {
        XCTAssertEqual(CarPlayContent.make(snapshot: nil, report: allGreen, locale: es).rows, [.init(label: "Esperando a que arranque el viaje", detail: nil)])
        XCTAssertEqual(CarPlayContent.make(snapshot: nil, report: allGreen, locale: en).rows, [.init(label: "Waiting for the drive to start", detail: nil)])
        XCTAssertEqual(CarPlayContent.make(snapshot: snapshot(next: nil, distance: nil), report: allGreen, locale: es).rows, [.init(label: "Sin radares cerca", detail: nil)])
        XCTAssertEqual(CarPlayContent.make(snapshot: snapshot(next: nil, distance: nil), report: allGreen, locale: en).rows, [.init(label: "No radars nearby", detail: nil)])
    }

    /// An Estado line appears only when a row is red, naming the first failing row in the phone's language; amber
    /// rows stay off the car screen.
    func testEstadoShowsTheFirstRedRowOnly() {
        let report = [
            HealthItem(status: .warn, title: HealthTitles.motion, detail: ""),
            HealthItem(status: .fail, title: HealthTitles.session, detail: ""),
            HealthItem(status: .fail, title: HealthTitles.feed, detail: ""),
        ]
        XCTAssertEqual(CarPlayContent.make(snapshot: nil, report: report, locale: es).rows.last, .init(label: "Estado", detail: "Sesión Siempre"))
        XCTAssertEqual(CarPlayContent.make(snapshot: nil, report: report, locale: en).rows.last, .init(label: "Status", detail: "Always session"))
        let amber = [HealthItem(status: .warn, title: HealthTitles.motion, detail: "")]
        XCTAssertEqual(CarPlayContent.make(snapshot: nil, report: amber, locale: es).rows.count, 1, "an amber row adds no Estado line")
    }

    /// Driving-task guideline 4: the data items refresh at most once every 10 seconds. The first call passes, a
    /// call inside the window is refused without moving the window, the call at 10 s passes.
    func testTheRefreshThrottleAllowsOnceEveryTenSeconds() {
        var throttle = CarPlayRefreshThrottle()
        XCTAssertEqual(CarPlayRefreshThrottle.minimumSeconds, 10)
        XCTAssertTrue(throttle.allows(now: t0))
        XCTAssertFalse(throttle.allows(now: t0.addingTimeInterval(1)))
        XCTAssertFalse(throttle.allows(now: t0.addingTimeInterval(9.9)))
        XCTAssertEqual(throttle.lastRefreshAt, t0, "a refused call does not move the window")
        XCTAssertTrue(throttle.allows(now: t0.addingTimeInterval(10)))
        XCTAssertFalse(throttle.allows(now: t0.addingTimeInterval(15)))
    }

    /// The two notification facts the car screen needs: the request asks for `.carPlay`, and the radar category is
    /// registered with `allowInCarPlay` under the identifier every radar notification carries.
    func testTheRadarNotificationIsAllowedInCarPlay() {
        XCTAssertTrue(Notifier.authorizationOptions.contains(.carPlay))
        XCTAssertTrue(Notifier.authorizationOptions.contains(.alert))
        XCTAssertTrue(Notifier.authorizationOptions.contains(.sound))

        let category = Notifier.radarNotificationCategory()
        XCTAssertEqual(category.identifier, Notifier.radarCategory)
        XCTAssertTrue(category.options.contains(.allowInCarPlay))

        let phrase = Phrase(spoken: "Radar fijo a 800 metros.", title: "Radar fijo a 800 m", body: "A-2 km 202,3 · límite 90 km/h")
        let content = Notifier.radarContent(phrase, voiceEnabled: true, silent: false)
        XCTAssertEqual(content.categoryIdentifier, Notifier.radarCategory, "every radar notification is in the CarPlay category")
        XCTAssertEqual(content.threadIdentifier, Notifier.radarThread)
        XCTAssertEqual(content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(content.title, phrase.title)
        XCTAssertEqual(content.body, phrase.body)
        XCTAssertEqual(content.sound, Notifier.sound(voiceEnabled: true), "the sound stays as the voice setting decides")
        XCTAssertNil(Notifier.radarContent(phrase, voiceEnabled: true, silent: true).sound)
    }
}
