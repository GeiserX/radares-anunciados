// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RadaresCore

final class PhrasingTests: XCTestCase {
    func event(_ radar: Radar, kind: AlertEvent.Kind = .warn(.full), distance: Double? = 800) -> AlertEvent {
        AlertEvent(kind: kind, radar: radar, distance: distance, content: .watching(at: t0))
    }

    func testFixedWithLimitAndWithDirection() {
        let limited = makeRadar(road: "A-2", kmFrom: 202.3, maxspeed: 90)
        let p = Phrasing.make(event(limited), locale: Fixtures.es)
        XCTAssertEqual(p.spoken, "Radar fijo a 800 metros. Límite 90.")
        XCTAssertEqual(p.title, "Radar fijo a 800 m")
        XCTAssertEqual(p.body, "A-2 km 202,3 · límite 90 km/h")

        let named = makeRadar(directionText: "ZARAGOZA")
        let q = Phrasing.make(event(named, distance: 650), locale: Fixtures.es)
        XCTAssertEqual(q.spoken, "Radar fijo a 650 metros, sentido Zaragoza.")
        XCTAssertEqual(q.body, "Radar fijo A-2 km 202.3 · sentido Zaragoza")

        let both = makeRadar(maxspeed: 90, directionText: "DONOSTIA / SAN SEBASTIÁN")
        XCTAssertEqual(Phrasing.make(event(both), locale: Fixtures.es).spoken, "Radar fijo a 800 metros, sentido Donostia / San Sebastián. Límite 90.")
    }

    func testEveryPointKind() {
        XCTAssertEqual(Phrasing.make(event(makeRadar(kind: .section), distance: 600), locale: Fixtures.es).spoken, "Radar de tramo a 600 metros.")
        XCTAssertEqual(Phrasing.make(event(makeRadar(kind: .mobileAnnounced, maxspeed: 50), distance: 347), locale: Fixtures.es).spoken, "Radar móvil anunciado a 350 metros. Límite 50.")
        XCTAssertEqual(Phrasing.make(event(makeRadar(kind: .trailer), distance: 800), locale: Fixtures.es).spoken, "Radar en remolque a 800 metros.")
        XCTAssertEqual(Phrasing.make(event(makeRadar(kind: .mobileRecurring, maxspeed: 50), distance: 347), locale: Fixtures.es).spoken, "Radar móvil habitual a 350 metros. Límite 50.")
        XCTAssertEqual(Phrasing.make(event(makeRadar(kind: .mobileRecurring), distance: 800), locale: Fixtures.en).spoken, "Usual mobile radar 800 metres ahead.")
    }

    func testStretchEntriesAndExit() {
        let corridor = makeRadar(kind: .stretch, role: .mobileCorridor, end: .at(41.3, -1.8), road: "N-232", kmFrom: 20.81, kmTo: 30.91, bidirectional: true, source: "dgt_invive")
        XCTAssertEqual(Phrasing.make(event(corridor, kind: .stretchEntered, distance: 610), locale: Fixtures.es).spoken, "Tramo de radar móvil, N-232, 10 kilómetros.")
        let noRoad = makeRadar(kind: .stretch, role: .mobileCorridor, end: .at(41.3, -1.8), kmFrom: 1, kmTo: 2.2, bidirectional: true, source: "dgt_invive")
        XCTAssertEqual(Phrasing.make(event(noRoad, kind: .stretchEntered, distance: 610), locale: Fixtures.es).spoken, "Tramo de radar móvil, 1 kilómetro.")

        let section = makeRadar(kind: .stretch, role: .averageSpeedSection, end: .at(41.3, -1.8), road: "Z-40", kmFrom: 26.6, kmTo: 29.7, maxspeed: 100, directionText: "MADRID")
        let p = Phrasing.make(event(section, kind: .stretchEntered, distance: 600), locale: Fixtures.es)
        XCTAssertEqual(p.spoken, "Radar de tramo a 600 metros, 3 kilómetros, sentido Madrid. Límite 100.")
        XCTAssertEqual(p.title, "Radar de tramo · 3 kilómetros")
        XCTAssertEqual(p.body, "Z-40 km 26,6 · límite 100 km/h · sentido Madrid")

        let exit = Phrasing.make(event(section, kind: .stretchExited(.farGate), distance: nil), locale: Fixtures.es)
        XCTAssertEqual(exit.spoken, "Fin de tramo.")
        XCTAssertEqual(exit.title, "Fin de tramo")
        XCTAssertEqual(Phrasing.make(event(section, kind: .passed, distance: nil), locale: Fixtures.es).spoken, "")
    }

    func testCombinedSentenceForTwoRadarsOnOneFix() {
        let p = Phrasing.make(event(makeRadar(), distance: 600), locale: Fixtures.es, alsoAt: 800)
        XCTAssertEqual(p.spoken, "Radar fijo a 600 metros, y otro a 800.")
        let q = Phrasing.make(event(makeRadar(maxspeed: 90, directionText: "ZARAGOZA"), distance: 600), locale: Fixtures.es, alsoAt: 790)
        XCTAssertEqual(q.spoken, "Radar fijo a 600 metros, y otro a 800, sentido Zaragoza. Límite 90.")
    }

    func testEnglish() {
        XCTAssertEqual(Phrasing.make(event(makeRadar(maxspeed: 90), distance: 800), locale: Fixtures.en).spoken, "Fixed speed camera 800 metres ahead. Limit 90.")
        XCTAssertEqual(Phrasing.make(event(makeRadar(directionText: "ZARAGOZA"), distance: 650), locale: Fixtures.en).spoken, "Fixed speed camera 650 metres ahead, towards Zaragoza.")
        XCTAssertEqual(Phrasing.make(event(makeRadar(kind: .mobileAnnounced, maxspeed: 50), distance: 350), locale: Fixtures.en).spoken, "Announced mobile speed camera 350 metres ahead. Limit 50.")
        let corridor = makeRadar(kind: .stretch, role: .mobileCorridor, end: .at(41.3, -1.8), road: "N-232", kmFrom: 20.81, kmTo: 30.91, bidirectional: true, source: "dgt_invive")
        XCTAssertEqual(Phrasing.make(event(corridor, kind: .stretchEntered, distance: 610), locale: Fixtures.en).spoken, "Mobile radar stretch, N-232, 10 kilometres.")
        XCTAssertEqual(Phrasing.make(event(corridor, kind: .stretchExited(.farGate), distance: nil), locale: Fixtures.en).spoken, "End of section.")
        XCTAssertEqual(Phrasing.make(event(makeRadar(), distance: 600), locale: Fixtures.en, alsoAt: 800).spoken, "Fixed speed camera 600 metres ahead, and another at 800.")
        XCTAssertEqual(Phrasing.make(event(makeRadar(road: "A-2", kmFrom: 202.3, maxspeed: 90)), locale: Fixtures.en).body, "A-2 km 202.3 · limit 90 km/h")
        XCTAssertTrue(Phrasing.isEnglish(Locale(identifier: "en_US")))
        XCTAssertFalse(Phrasing.isEnglish(Locale(identifier: "es_ES")))
        XCTAssertFalse(Phrasing.isEnglish(Locale(identifier: "ca_ES")), "anything but English speaks Spanish")
    }

    func testDistanceRoundingToFiftyMetres() {
        XCTAssertEqual(Phrasing.roundedDistance(833), 850)
        XCTAssertEqual(Phrasing.roundedDistance(824), 800)
        XCTAssertEqual(Phrasing.roundedDistance(347), 350)
        XCTAssertEqual(Phrasing.roundedDistance(12), 50, "never under one step")
        XCTAssertEqual(Phrasing.roundedDistance(1000), 1000)
    }

    func testLengthText() {
        XCTAssertEqual(Phrasing.lengthText(10_100, locale: Fixtures.es), "10 kilómetros")
        XCTAssertEqual(Phrasing.lengthText(3_100, locale: Fixtures.es), "3 kilómetros")
        XCTAssertEqual(Phrasing.lengthText(1_400, locale: Fixtures.es), "1 kilómetro")
        XCTAssertEqual(Phrasing.lengthText(940, locale: Fixtures.es), "950 metros")
        XCTAssertEqual(Phrasing.lengthText(86_700, locale: Fixtures.en), "87 kilometres")
    }

    func testTitlesAndSubtitlesForTheCard() {
        XCTAssertEqual(Phrasing.kindTitle(makeRadar(kind: .stretch, role: .mobileCorridor), locale: Fixtures.es), "Tramo de radar móvil")
        XCTAssertEqual(Phrasing.kindTitle(makeRadar(kind: .stretch, role: .averageSpeedSection), locale: Fixtures.es), "Radar de tramo")
        XCTAssertEqual(Phrasing.kindTitle(makeRadar(kind: .reported), locale: Fixtures.es), "Radar sin confirmar")
        XCTAssertEqual(Phrasing.subtitle(makeRadar(road: "N-232", kmFrom: 20.81), locale: Fixtures.es), "N-232 km 20,8")
        XCTAssertEqual(Phrasing.subtitle(makeRadar(road: "N-232"), locale: Fixtures.es), "N-232")
        XCTAssertEqual(Phrasing.subtitle(makeRadar(name: "Radar anunciado Avenida de Los Antibióticos"), locale: Fixtures.es), "Radar anunciado Avenida de Los Antibióticos")
    }
}
