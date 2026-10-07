// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RadaresCore

final class PassTrackerTests: XCTestCase {
    func testTheStateMachineRoundTrip() {
        var tracker = PassTracker(ledger: PassLedger())
        XCTAssertEqual(tracker.state(of: "r", now: t0), .idle)
        tracker.arm("r")
        XCTAssertEqual(tracker.state(of: "r", now: t0), .armed)
        tracker.disarm("r")
        XCTAssertEqual(tracker.state(of: "r", now: t0), .idle)
        tracker.arm("r")
        tracker.fire("r", level: .full, now: t0)
        XCTAssertEqual(tracker.state(of: "r", now: t0.addingTimeInterval(5)), .fired(.full))
        XCTAssertFalse(tracker.canFire("r", now: t0.addingTimeInterval(5)))
        tracker.markPassed("r", now: t0.addingTimeInterval(30))
        XCTAssertEqual(tracker.state(of: "r", now: t0.addingTimeInterval(31)), .passed)
        XCTAssertEqual(tracker.state(of: "r", now: t0.addingTimeInterval(35)), .cooldown, "the passed card lasts 4 s")
        XCTAssertEqual(tracker.firedIds, [])
    }

    func testCooldownNeedsBothTenMinutesAndTwoKilometres() {
        var tracker = PassTracker(ledger: PassLedger())
        tracker.fire("r", level: .full, now: t0)
        tracker.markPassed("r", now: t0.addingTimeInterval(20))
        tracker.observe("r", distance: 3000)
        XCTAssertEqual(tracker.state(of: "r", now: t0.addingTimeInterval(5 * 60)), .cooldown, "3 km but only 5 min")
        XCTAssertEqual(tracker.state(of: "r", now: t0.addingTimeInterval(11 * 60)), .idle, "11 min and 3 km")

        var short = PassTracker(ledger: PassLedger())
        short.fire("s", level: .full, now: t0)
        short.markPassed("s", now: t0.addingTimeInterval(20))
        short.observe("s", distance: 1000)
        XCTAssertEqual(short.state(of: "s", now: t0.addingTimeInterval(11 * 60)), .cooldown, "11 min but only 1 km")
        XCTAssertFalse(short.canFire("s", now: t0.addingTimeInterval(11 * 60)))
    }

    func testAFiredRadarNeverPassedStillCoolsDown() {
        var tracker = PassTracker(ledger: PassLedger())
        tracker.fire("r", level: .visual, now: t0)
        XCTAssertEqual(tracker.state(of: "r", now: t0.addingTimeInterval(60)), .fired(.visual))
        tracker.observe("r", distance: 2500)
        tracker.observe("r", distance: 100, )
        XCTAssertEqual(tracker.ledger.entry(for: "r")?.farthestMetres, 2500, "farthest never goes down")
        XCTAssertEqual(tracker.state(of: "r", now: t0.addingTimeInterval(10 * 60)), .idle)
    }

    func testLedgerRoundTripsThroughJSON() throws {
        var ledger = PassLedger()
        ledger.upsert(PassLedger.Entry(id: "a", firedAt: t0, level: .full, farthestMetres: 120, passedAt: t0.addingTimeInterval(40)))
        ledger.upsert(PassLedger.Entry(id: "b", firedAt: t0.addingTimeInterval(100), level: .visual))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(PassLedger.self, from: encoder.encode(ledger))
        XCTAssertEqual(back, ledger)
        XCTAssertEqual(back.entry(for: "b")?.level, .visual)
        ledger.upsert(PassLedger.Entry(id: "a", firedAt: t0, level: .full, farthestMetres: 900))
        XCTAssertEqual(ledger.entries.count, 2, "upsert replaces")
        XCTAssertEqual(ledger.entry(for: "a")?.farthestMetres, 900)
    }

    func testPruneDropsOldEntriesAndCapsTheCount() {
        var ledger = PassLedger()
        ledger.upsert(PassLedger.Entry(id: "old", firedAt: t0.addingTimeInterval(-25 * 3600)))
        ledger.upsert(PassLedger.Entry(id: "fresh", firedAt: t0.addingTimeInterval(-23 * 3600)))
        ledger.prune(now: t0)
        XCTAssertEqual(ledger.entries.map(\.id), ["fresh"])

        var big = PassLedger()
        for i in 0..<250 { big.upsert(PassLedger.Entry(id: "r\(i)", firedAt: t0.addingTimeInterval(Double(i)))) }
        big.prune(now: t0.addingTimeInterval(300))
        XCTAssertEqual(big.entries.count, Thresholds.ledgerMaxEntries)
        XCTAssertNil(big.entry(for: "r0"), "the oldest went first")
        XCTAssertNotNil(big.entry(for: "r249"))
    }

    func testTrackerPruneDropsFinishedPasses() {
        var tracker = PassTracker(ledger: PassLedger())
        tracker.fire("done", level: .full, now: t0)
        tracker.markPassed("done", now: t0.addingTimeInterval(10))
        tracker.observe("done", distance: 2500)
        tracker.fire("recent", level: .full, now: t0.addingTimeInterval(500))
        tracker.prune(now: t0.addingTimeInterval(700))
        XCTAssertEqual(tracker.ledger.entries.map(\.id), ["recent"])
    }
}
