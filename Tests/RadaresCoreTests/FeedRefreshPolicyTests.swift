// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RadaresCore

final class FeedRefreshPolicyTests: XCTestCase {
    let policy = FeedRefreshPolicy()

    func meta(ageHours: Double) -> FeedMeta {
        FeedMeta(fetchedAt: t0.addingTimeInterval(-ageHours * 3600), featureCount: 4500)
    }

    func testManualAlwaysRefreshes() {
        XCTAssertTrue(policy.shouldRefresh(meta: meta(ageHours: 0.01), now: t0, trigger: .manual))
    }

    func testNoFeedYetRefreshesOnAnyTrigger() {
        for trigger in [FeedRefreshPolicy.Trigger.foreground, .background, .driveStart] {
            XCTAssertTrue(policy.shouldRefresh(meta: FeedMeta(), now: t0, trigger: trigger), "\(trigger)")
        }
    }

    func testForegroundAndBackgroundAtSixHours() {
        for trigger in [FeedRefreshPolicy.Trigger.foreground, .background] {
            XCTAssertFalse(policy.shouldRefresh(meta: meta(ageHours: 5.9), now: t0, trigger: trigger), "\(trigger)")
            XCTAssertTrue(policy.shouldRefresh(meta: meta(ageHours: 6), now: t0, trigger: trigger), "\(trigger)")
        }
    }

    func testDriveStartAtTwentyFourHours() {
        XCTAssertFalse(policy.shouldRefresh(meta: meta(ageHours: 23), now: t0, trigger: .driveStart))
        XCTAssertTrue(policy.shouldRefresh(meta: meta(ageHours: 25), now: t0, trigger: .driveStart))
    }

    func testCheckedAtDoesNotCountAsFetched() {
        var m = meta(ageHours: 30)
        m.checkedAt = t0
        XCTAssertTrue(policy.shouldRefresh(meta: m, now: t0, trigger: .driveStart), "a 304 moves checkedAt, the body is still 30 h old")
    }
}
