// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The dispatcher's rules for the road warnings (design 2.3, 2.4, 4.3): a hidden warning writes its log row and
// nothing else; every `.visual` post, the held one included, is silent.

import RadaresCore
import XCTest
@testable import RadaresAnunciados

final class AlertDispatcherRoadsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(held: Bool = false, hidden: Bool = false, opposite: Bool = false) -> AlertEvent {
        let radar = Radar(id: "dgt-1", kind: .fixed, role: .point, start: Coordinate(latitude: 41, longitude: -1), name: "A-2", bearing: 0, directionConfidence: .high, source: "dgt", attribution: "")
        return AlertEvent(
            kind: .warn(.visual), radar: radar, distance: 640, crossTrackMetres: 25,
            content: DriveContent(phase: .alert, kindSymbol: "camera.fill", title: "Radar fijo", subtitle: "", distanceMetres: 640, opposite: opposite, updatedAt: t0, held: held, hidden: hidden)
        )
    }

    func testAHiddenWarningWritesOnlyItsLogRow() throws {
        let fix = Fix(coordinate: Coordinate(latitude: 40.99, longitude: -1), timestamp: t0, speed: 27, course: 180, horizontalAccuracy: 5)
        guard case let .alert(id, level, distance, speed, _, _, suppressed, coordinate, sinks, spoken) = AlertDispatcher.hiddenRow(for: event(hidden: true, opposite: true), fix: fix) else {
            return XCTFail("a hidden warning must write an alert row")
        }
        XCTAssertEqual(id, "dgt-1")
        XCTAssertEqual(level, .visual)
        XCTAssertEqual(distance, 640)
        XCTAssertEqual(speed, 27)
        XCTAssertTrue(suppressed, "findable in an exported log as a direction suppression")
        XCTAssertEqual(coordinate, fix.coordinate)
        XCTAssertEqual(sinks, [], "no notification, no voice")
        XCTAssertNil(spoken)
    }

    /// No `.visual` post can carry a sound: held, opposite or paced. A `.full` one always can.
    func testTheDispatcherNeverPostsANonSilentVisual() {
        XCTAssertTrue(AlertDispatcher.isSilent(level: .visual))
        XCTAssertFalse(AlertDispatcher.isSilent(level: .full), "positive control: the spoken warning keeps its sound")
        for e in [event(held: true), event(opposite: true), event()] {
            guard case .warn(let level) = e.kind else { return XCTFail() }
            XCTAssertTrue(AlertDispatcher.isSilent(level: level))
        }
    }

    /// A held warning posts the same text as any `.visual` row, without "sentido contrario" (it is the car's flow).
    func testAHeldWarningPostsAPlainTitle() throws {
        let phrase = try XCTUnwrap(AlertDispatcher.notificationPhrase(for: event(held: true), level: .visual, locale: Locale(identifier: "es_ES")))
        XCTAssertEqual(phrase.title, "Radar fijo a 650 m")
        XCTAssertEqual(phrase.spoken, "")
    }
}
