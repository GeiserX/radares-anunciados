// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The route vectors of Fixtures/vectors (design 10): each is a drive over the fixture with the events the engine must
// produce. The same files are the Android contract (docs/SPEC.md). One test per vector so a failure names the drive.

import XCTest
@testable import RadaresCore

struct Vector: Decodable {
    struct VFix: Decodable {
        let t: String
        let lat: Double
        let lon: Double
        let speed: Double?
        let course: Double?
        let accuracy: Double
        let stationary: Bool
    }

    struct VEvent: Decodable {
        let kind: String
        let level: String?
        let radar: String?
        let distance: Double?
        let tolerance: Double?
        let late: Bool?
        let opposite: Bool?
        let spoken: String?
        let exitReason: String?
    }

    struct VSnapshot: Decodable {
        let fixIndex: Int
        let stretch: String?
        let remainingMetres: Double?
        let tolerance: Double?
        let avgKmh: Double?
        let avgTolerance: Double?
        let phase: String?
    }

    let name: String
    let description: String
    let locale: String?
    let negativeControl: Bool?
    let fixes: [VFix]
    let expected: [VEvent]
    let snapshots: [VSnapshot]?

    static func load(_ name: String) throws -> Vector {
        let url = try Fixtures.url(name, ext: "json", subdirectory: "Fixtures/vectors")
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    var fixList: [Fix] {
        let iso = ISO8601DateFormatter()
        return fixes.map { f in
            Fix(coordinate: .at(f.lat, f.lon), timestamp: iso.date(from: f.t)!, speed: f.speed, course: f.course, horizontalAccuracy: f.accuracy, isStationary: f.stationary)
        }
    }
}

struct VectorRun {
    var events: [(index: Int, event: AlertEvent)] = []
    var mismatches: [String] = []
}

enum VectorRunner {
    static func run(_ vector: Vector, store: RadarStore, ledger: PassLedger = PassLedger()) -> VectorRun {
        let engine = AlertEngine(store: store, ledger: ledger, locale: Locale(identifier: vector.locale ?? "es_ES"))
        var run = VectorRun()
        for (i, fix) in vector.fixList.enumerated() {
            for e in engine.ingest(fix) {
                run.events.append((i, e))
            }
            for check in vector.snapshots ?? [] where check.fixIndex == i {
                let s = engine.snapshot
                if let id = check.stretch, s.stretch?.radar.id != id { run.mismatches.append("fix \(i): expected inside \(id), got \(s.stretch?.radar.id ?? "nil")") }
                if let remaining = check.remainingMetres {
                    let got = s.stretch?.remainingMetres ?? -1
                    if abs(got - remaining) > (check.tolerance ?? 50) { run.mismatches.append("fix \(i): remaining \(got) vs \(remaining)") }
                }
                if let avg = check.avgKmh {
                    let got = s.stretch?.avgKmh ?? -1
                    if abs(got - avg) > (check.avgTolerance ?? 3) { run.mismatches.append("fix \(i): avg \(got) vs \(avg)") }
                }
                if let phase = check.phase, s.content.phase.rawValue != phase { run.mismatches.append("fix \(i): phase \(s.content.phase) vs \(phase)") }
            }
        }
        run.mismatches.append(contentsOf: compare(run.events.map(\.event), to: vector.expected))
        return run
    }

    static func describe(_ e: AlertEvent) -> String {
        "\(e.kind) \(e.radar?.id ?? "-") \(e.distance.map { Int($0) } ?? -1) m late=\(e.late) spoken=\(e.phrase?.spoken ?? "nil")"
    }

    static func compare(_ events: [AlertEvent], to expected: [Vector.VEvent]) -> [String] {
        var out: [String] = []
        if events.count != expected.count {
            out.append("expected \(expected.count) events, got \(events.count): \(events.map(describe))")
        }
        for (i, (e, x)) in zip(events, expected).enumerated() {
            let kind: String
            var level: String?
            var exitReason: StretchExitReason?
            switch e.kind {
            case .warn(let l): kind = "warn"; level = l.rawValue
            case .passed: kind = "passed"
            case .stretchEntered: kind = "stretchEntered"; level = "full"
            case .stretchExited(let r): kind = "stretchExited"; exitReason = r
            case .driveEnded: kind = "driveEnded"
            }
            if kind != x.kind { out.append("event \(i): kind \(kind) vs \(x.kind)") }
            if let l = x.level, l != level { out.append("event \(i): level \(level ?? "nil") vs \(l)") }
            if let r = x.radar, r != e.radar?.id { out.append("event \(i): radar \(e.radar?.id ?? "nil") vs \(r)") }
            if let d = x.distance {
                let got = e.distance ?? -1
                if abs(got - d) > (x.tolerance ?? 40) { out.append("event \(i): distance \(got) vs \(d) ± \(x.tolerance ?? 40)") }
            }
            if let late = x.late, late != e.late { out.append("event \(i): late \(e.late) vs \(late)") }
            if let opposite = x.opposite, opposite != e.content.opposite { out.append("event \(i): opposite \(e.content.opposite) vs \(opposite)") }
            if let spoken = x.spoken, spoken != e.phrase?.spoken { out.append("event \(i): spoken \"\(e.phrase?.spoken ?? "nil")\" vs \"\(spoken)\"") }
            if x.spoken == nil, kind == "warn", level == "visual", e.phrase != nil { out.append("event \(i): a visual warning must not have a phrase") }
            if x.spoken == nil, kind == "stretchExited", e.phrase != nil { out.append("event \(i): a silent exit must not have a phrase") }
            // The reason rides on the event itself, so the log row can be written from the event alone.
            if let reason = x.exitReason, reason != exitReason?.rawValue { out.append("event \(i): exit reason \(exitReason?.rawValue ?? "nil") vs \(reason)") }
        }
        return out
    }
}

final class AlertEngineVectorTests: XCTestCase {
    nonisolated(unsafe) static var sharedStore: RadarStore?

    func store() throws -> RadarStore {
        if let s = Self.sharedStore { return s }
        let s = try Fixtures.store()
        Self.sharedStore = s
        return s
    }

    func check(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let vector = try Vector.load(name)
        let run = VectorRunner.run(vector, store: try store())
        XCTAssertTrue(run.mismatches.isEmpty, "\(name): \(run.mismatches.joined(separator: " | "))", file: file, line: line)
    }

    func testA2At120KmhNortheast() throws { try check("a2-120kmh-ne") }
    func testA2At120KmhSouthwest() throws { try check("a2-120kmh-sw") }
    func testLeonTodayFires() throws { try check("leon-50kmh-today") }
    func testLeonTomorrowIsSilent() throws { try check("leon-50kmh-tomorrow") }
    func testParallelRoadNeverFires() throws { try check("a2-parallel-150m") }
    func testHeadOnTwinFires() throws { try check("a2-head-on-90kmh") }
    func testBehindNeverFires() throws { try check("a2-behind") }
    func testOSMBearingSameFlowIsFull() throws { try check("osm-bearing-same") }
    func testOSMBearingOppositeFlowIsVisual() throws { try check("osm-bearing-opposite") }
    func testBothIsFull() throws { try check("osm-both") }
    func testNoCourseAtTwoMetresPerSecondIsSilent() throws { try check("a2-no-course-2mps") }
    func testCourseDerivedFromFixesFires() throws { try check("a2-no-course-20mps") }
    func testLateWakeAt150mFiresLate() throws { try check("a2-late-150m") }
    func testFirstSeenAt40mIsCardOnly() throws { try check("a2-first-seen-40m") }
    func testUTurnInsideFiveMinutesIsOnePass() throws { try check("a2-uturn-5min") }
    func testReapproachAfterElevenMinutesAndThreeKmFiresAgain() throws { try check("a2-uturn-11min-3km") }
    func testPairPacingOneSpokenOneVisual() throws { try check("pair-123m-pacing") }
    func testPairOnOneFixIsOneSentence() throws { try check("pair-123m-same-fix") }
    func testCorridorFromTheWest() throws { try check("corridor-n232-from-west") }
    func testCorridorFromTheEast() throws { try check("corridor-n232-from-east") }
    func testCorridorSilentExitByDistance() throws { try check("corridor-n232-exit-distance") }
    func testCorridorSilentExitByTime() throws { try check("corridor-n232-exit-time") }
    func testAverageSpeedSection() throws { try check("section-z40-100kmh") }

    /// The negative control: a vector with the warning deleted from its expectation must not pass.
    func testBrokenVectorIsRejected() throws {
        let vector = try Vector.load("broken-a2-no-warning")
        XCTAssertEqual(vector.negativeControl, true)
        let run = VectorRunner.run(vector, store: try store())
        XCTAssertFalse(run.mismatches.isEmpty, "the harness accepted a vector whose expectation is known to be wrong")
        XCTAssertTrue(run.mismatches.first?.contains("expected 1 events, got 2") ?? false, "\(run.mismatches)")
    }

    func testEveryVectorFileHasATest() throws {
        let dir = try Fixtures.url("a2-120kmh-ne", ext: "json", subdirectory: "Fixtures/vectors").deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        let untested = files.filter { !source.contains("\"\($0)\"") }
        XCTAssertEqual(untested, [], "vectors without a test")
        XCTAssertEqual(files.count, 24)
    }

    func testEveryMustNotFireVectorHasAMustFireTwin() throws {
        let silent = ["leon-50kmh-tomorrow": "leon-50kmh-today", "a2-parallel-150m": "a2-head-on-90kmh", "a2-behind": "a2-head-on-90kmh", "a2-no-course-2mps": "a2-no-course-20mps", "a2-uturn-5min": "a2-uturn-11min-3km"]
        for (quiet, loud) in silent {
            let q = try Vector.load(quiet), l = try Vector.load(loud)
            XCTAssertFalse(q.expected.contains { $0.kind == "warn" && $0.level == "full" } && q.expected.count > 2, quiet)
            XCTAssertTrue(l.expected.contains { $0.kind == "warn" && $0.level == "full" }, loud)
        }
    }

    func testLedgerSurvivesARelaunchMidDrive() throws {
        let vector = try Vector.load("a2-120kmh-ne")
        let fixes = vector.fixList
        let store = try store()
        let first = AlertEngine(store: store, ledger: PassLedger(), locale: Fixtures.es)
        var fired: Int?
        for (i, fix) in fixes.enumerated() {
            if first.ingest(fix).contains(where: { if case .warn = $0.kind { return true } else { return false } }) { fired = i; break }
        }
        let at = try XCTUnwrap(fired)
        // The process dies two fixes later and comes back with the persisted ledger.
        _ = first.ingest(fixes[at + 1])
        let second = AlertEngine(store: store, ledger: first.ledger, locale: Fixtures.es)
        var events: [AlertEvent] = []
        for fix in fixes[(at + 2)...] { events.append(contentsOf: second.ingest(fix)) }
        XCTAssertFalse(events.contains { if case .warn = $0.kind { return true } else { return false } }, "the voice must not repeat after a relaunch")
        XCTAssertEqual(events.filter { $0.kind == .passed }.count, 1)
    }

    func testEndDriveClosesAStretchSilentlyAndPrunes() throws {
        let vector = try Vector.load("corridor-n232-from-west")
        let fixes = vector.fixList
        let engine = AlertEngine(store: try store(), ledger: PassLedger(), locale: Fixtures.es)
        for fix in fixes.prefix(150) { _ = engine.ingest(fix) }
        XCTAssertNotNil(engine.snapshot.stretch)
        let events = engine.endDrive()
        XCTAssertEqual(events.map(\.kind), [.stretchExited(.driveEnd), .driveEnded])
        XCTAssertNil(events.first?.phrase)
        XCTAssertEqual(engine.lastStretchExitReason, .driveEnd)
        XCTAssertNil(engine.snapshot.stretch)
        XCTAssertEqual(engine.snapshot.content.phase, .watching)
        XCTAssertEqual(engine.ledger.entries.count, 1, "the stretch pass is kept until its cooldown is over")
    }

    /// The under-30 m rule on its own: the car fires, drives to 10 m from the radar and stops there, so the
    /// distance never increases three times. Only `passedBelowM` can mark the pass.
    func testStoppingAtTheRadarIsAPassByTheThirtyMetreRule() throws {
        let engine = AlertEngine(store: try store(), ledger: PassLedger(), locale: Fixtures.es)
        let a2 = try Fixtures.radar("dgt-CABINACINEMOMETRO_120001")
        var fixes = straightFixes(gate: a2.start, course: 60, speed: 25, metresBefore: 1010, metresAfter: 0)
        fixes.removeLast()
        let stop = Geo.destination(from: a2.start, bearingDegrees: 240, metres: 10)
        let last = try XCTUnwrap(fixes.last).timestamp
        for i in 1...5 { fixes.append(makeFix(stop, t: last.addingTimeInterval(Double(i)), speed: 0, course: nil)) }
        var kinds: [AlertEvent.Kind] = []
        for fix in fixes { kinds.append(contentsOf: engine.ingest(fix).map(\.kind)) }
        XCTAssertEqual(kinds, [.warn(.full), .passed])
        let passedIndex = try XCTUnwrap(fixes.firstIndex { Geo.distance($0.coordinate, a2.start) < Thresholds.passedBelowM })
        XCTAssertEqual(fixes[passedIndex].speed, 0, "the first fix under 30 m is the stopped one")
    }

    func testSnapshotShowsTheNearestRadarAsCercaWithoutACourse() throws {
        let vector = try Vector.load("a2-no-course-2mps")
        let engine = AlertEngine(store: try store(), ledger: PassLedger(), locale: Fixtures.es)
        for fix in vector.fixList.prefix(20) { _ = engine.ingest(fix) }
        let s = engine.snapshot
        XCTAssertNil(s.courseDegrees)
        XCTAssertEqual(s.next?.id, "dgt-CABINACINEMOMETRO_120001")
        XCTAssertEqual(s.content.subtitle, "cerca")
        XCTAssertEqual(s.content.phase, .watching)
        XCTAssertEqual(s.content.title, "Radar fijo")
    }
}
