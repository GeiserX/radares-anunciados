// Lane: location
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Significant change delivers the cached position right after it starts on every launch. On a launch the user made
// that delivery is the initial fix, never a wake-up; on a launch iOS made for a location event it is the event.

import CoreLocation
import RadaresCore
import XCTest
@testable import RadaresAnunciados

final class WakeUpsTests: XCTestCase {
    private final class Seen: @unchecked Sendable {
        var wakes: [Fix] = []
        var initial: [Fix] = []
    }

    private func fix(_ seconds: TimeInterval) -> Fix {
        Fix(coordinate: Coordinate(latitude: 41.3, longitude: -1.9), timestamp: Date(timeIntervalSince1970: seconds), speed: 0, horizontalAccuracy: 50)
    }

    @MainActor
    private func wakeUps(_ seen: Seen) -> WakeUps {
        WakeUps(
            onMonitorEvent: { _ in },
            onSignificantChange: { seen.wakes.append($0) },
            onInitialFix: { seen.initial.append($0) },
            onAuthorizationChange: { _ in }
        )
    }

    @MainActor
    func testTheCachedDeliveryOfAUserLaunchIsTheInitialFixNotAWake() async {
        let seen = Seen()
        let w = wakeUps(seen)
        w.expectInitialDelivery()
        await w.significantChange(fix(10))
        XCTAssertEqual(seen.initial.map(\.timestamp), [Date(timeIntervalSince1970: 10)])
        XCTAssertTrue(seen.wakes.isEmpty, "the cached position is not movement")
        XCTAssertNil(w.lastSlcDelivery, "Estado's last delivery is a real delivery, so the 14-day rule can go red")

        await w.significantChange(fix(20))
        XCTAssertEqual(seen.wakes.map(\.timestamp), [Date(timeIntervalSince1970: 20)], "the second delivery is a wake")
        XCTAssertEqual(w.lastSlcDelivery, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(seen.initial.count, 1)
    }

    /// A fresh device has nothing cached: its first delivery comes with the first movement, later than the window
    /// and with a fresh timestamp, and must wake. An old timestamp is cached whenever it arrives.
    @MainActor
    func testALateFreshFirstDeliveryIsAWake() async {
        let seen = Seen()
        let w = wakeUps(seen)
        let start = Date(timeIntervalSince1970: 100)
        w.expectInitialDelivery(at: start)
        await w.significantChange(fix(160), receivedAt: start.addingTimeInterval(60))
        XCTAssertEqual(seen.wakes.count, 1, "60 s after the start with a fresh timestamp: movement")
        XCTAssertTrue(seen.initial.isEmpty)

        let cached = Seen()
        let c = wakeUps(cached)
        c.expectInitialDelivery(at: start)
        await c.significantChange(fix(50), receivedAt: start.addingTimeInterval(60))
        XCTAssertEqual(cached.initial.count, 1, "a timestamp older than the start is the cached position whenever it lands")
        XCTAssertTrue(cached.wakes.isEmpty)
    }

    @MainActor
    func testOnABackgroundLaunchTheFirstDeliveryIsTheWake() async {
        let seen = Seen()
        let w = wakeUps(seen)
        await w.significantChange(fix(10))
        XCTAssertEqual(seen.wakes.count, 1)
        XCTAssertTrue(seen.initial.isEmpty)
        XCTAssertEqual(w.lastSlcDelivery, Date(timeIntervalSince1970: 10))
    }
}
