// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RadaresCore

final class EventLogTests: XCTestCase {
    var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appending(path: "radares-tests-\(UUID().uuidString)/events.jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testAppendAndRecentRoundTrip() {
        var log = EventLog(url: url)
        XCTAssertEqual(log.recent(10), [])
        log.append(.launch(reason: .slc, state: .background), at: t0)
        log.append(.sessionTaken, at: t0.addingTimeInterval(1))
        log.append(.alert(id: "r", level: .full, distance: 820.5, speedMps: 33.3, late: false, crossTrackMetres: 2.5, suppressedByDirection: false, coordinate: .at(41.3, -1.9), sinks: [SinkOutcome(sink: .speech, ok: true)]), at: t0.addingTimeInterval(2))
        let all = log.recent(10)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0], LogEntry(t: t0, event: .launch(reason: .slc, state: .background)))
        XCTAssertEqual(all[2].t, t0.addingTimeInterval(2))
        guard case .alert(let id, let level, let distance, _, _, _, _, let coordinate, let sinks) = all[2].event else { return XCTFail("\(all[2])") }
        XCTAssertEqual(id, "r")
        XCTAssertEqual(level, .full)
        XCTAssertEqual(distance, 820.5)
        XCTAssertEqual(coordinate, .at(41.3, -1.9))
        XCTAssertEqual(sinks.first?.sink, .speech)
        XCTAssertEqual(log.recent(2).map(\.t), [t0.addingTimeInterval(1), t0.addingTimeInterval(2)], "the newest n, oldest first")
        XCTAssertEqual(log.count, 3)
    }

    func testOneJSONLinePerEntry() throws {
        var log = EventLog(url: url)
        log.append(.feedUpdated(count: 4505, etag: "\"abc\""), at: t0)
        log.append(.willTerminate, at: t0)
        let text = try XCTUnwrap(String(data: XCTUnwrap(log.export()), encoding: .utf8))
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("{\"event\":{\"feedUpdated\":{"), String(lines[0]))
        XCTAssertTrue(lines[0].contains("\"t\":\"2026-10-07T"), String(lines[0]))
        XCTAssertEqual(String(lines[1]), "{\"event\":{\"willTerminate\":{}},\"t\":\"2026-10-07T10:00:00Z\"}")
    }

    func testRotationAtTwoThousandLinesKeepsTheNewestHalf() {
        var log = EventLog(url: url)
        for i in 0..<Thresholds.logMaxLines {
            log.append(.fix(speedMps: Double(i), horizontalAccuracy: 5, isStationary: false), at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(log.count, Thresholds.logMaxLines)
        log.append(.sessionTaken, at: t0.addingTimeInterval(10_000))
        XCTAssertEqual(log.count, Thresholds.logMaxLines / 2 + 1)
        let kept = log.recent(Thresholds.logMaxLines)
        XCTAssertEqual(kept.count, Thresholds.logMaxLines / 2 + 1)
        XCTAssertEqual(kept.first?.event, .fix(speedMps: Double(Thresholds.logMaxLines / 2), horizontalAccuracy: 5, isStationary: false), "the oldest kept line is the middle one")
        XCTAssertEqual(kept.last?.event, .sessionTaken)
        XCTAssertEqual(EventLog(url: url).count, Thresholds.logMaxLines / 2 + 1, "a fresh instance counts the file")
    }

    func testUndecodableLinesAreSkippedAndWipeEmpties() throws {
        var log = EventLog(url: url)
        log.append(.sessionTaken, at: t0)
        var data = try Data(contentsOf: url)
        data.append(Data("{\"event\":{\"fromTheFuture\":{}},\"t\":\"2027-01-01T00:00:00Z\"}\n".utf8))
        try data.write(to: url)
        log.append(.activityStarted, at: t0.addingTimeInterval(5))
        XCTAssertEqual(log.recent(10).map(\.event), [.sessionTaken, .activityStarted])
        log.wipe()
        XCTAssertEqual(log.recent(10), [])
        XCTAssertNil(log.export())
        XCTAssertEqual(log.count, 0)
    }

    func testMissingFolderIsCreated() {
        var log = EventLog(url: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        log.append(.sessionTaken, at: t0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
