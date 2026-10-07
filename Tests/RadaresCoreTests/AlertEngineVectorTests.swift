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
    var snapshots: [VSnapshot]?

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

/// A clock the engine reads through its `now` closure, moved to each fix's timestamp by the test.
final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

enum VectorRunner {
    static func run(_ vector: Vector, store: RadarStore, ledger: PassLedger = PassLedger()) -> VectorRun {
        let engine = AlertEngine(store: store, ledger: ledger, locale: Locale(identifier: vector.locale ?? "es_ES"))
        var run = VectorRun()
        // A snapshot check the fix loop never reaches would otherwise pass silently (a typo in fixIndex turns the
        // remaining, average and phase assertions off).
        for check in vector.snapshots ?? [] where check.fixIndex >= vector.fixes.count {
            run.mismatches.append("snapshot at \(check.fixIndex) never reached: the vector has \(vector.fixes.count) fixes")
        }
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
    func testCourseDerivedFromAFixFifteenMetresBackAtSixMetresPerSecond() throws { try check("a2-no-course-6mps") }
    func testPlatformCourseWithInvalidSpeedFires() throws { try check("a2-speed-nil-course-10mps") }
    func testStoppedBeforeTheRadarWithGPSWanderIsNotAPass() throws { try check("a2-stopped-jitter-200m") }
    func testCorridorJoinedBetweenTheGates() throws { try check("corridor-n232-mid-join") }
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
        XCTAssertEqual(files.count, 28)
    }

    /// A snapshot check that names a fix the vector does not have must fail the vector, not pass unnoticed.
    func testASnapshotCheckBeyondTheLastFixFailsTheVector() throws {
        var vector = try Vector.load("corridor-n232-from-west")
        vector.snapshots = [Vector.VSnapshot(fixIndex: 99_999, stretch: nil, remainingMetres: 1, tolerance: nil, avgKmh: nil, avgTolerance: nil, phase: nil)]
        let run = VectorRunner.run(vector, store: try store())
        XCTAssertTrue(run.mismatches.contains { $0.contains("never reached") }, "\(run.mismatches)")
    }

    func fullWarnings(_ v: Vector) -> Int {
        v.expected.filter { $0.kind == "warn" && $0.level == "full" }.count
    }

    /// A silent vector expects nothing at all; its twin on the same radar expects a full warning. The U-turn inside
    /// five minutes is the once-per-pass twin: exactly one full warning, where its eleven-minute twin has two.
    func testEveryMustNotFireVectorHasAMustFireTwin() throws {
        let silent = ["leon-50kmh-tomorrow": "leon-50kmh-today", "a2-parallel-150m": "a2-head-on-90kmh", "a2-behind": "a2-head-on-90kmh", "a2-no-course-2mps": "a2-no-course-20mps"]
        for (quiet, loud) in silent {
            let q = try Vector.load(quiet), l = try Vector.load(loud)
            XCTAssertTrue(q.expected.isEmpty, "\(quiet) must expect no event at all, got \(q.expected.map(\.kind))")
            XCTAssertGreaterThanOrEqual(fullWarnings(l), 1, loud)
        }
        XCTAssertEqual(fullWarnings(try Vector.load("a2-uturn-5min")), 1, "one pass, one warning")
        XCTAssertEqual(fullWarnings(try Vector.load("a2-uturn-11min-3km")), 2, "two passes, two warnings")
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

    /// Killed inside the corridor and relaunched: the engine rebuilt from the persisted ledger is still inside, says
    /// "Fin de tramo." at the far gate and the card leaves the stretch afterwards.
    func testRelaunchMidStretchStillExitsAtTheFarGate() throws {
        let vector = try Vector.load("corridor-n232-from-west")
        let fixes = vector.fixList
        let store = try store()
        let first = AlertEngine(store: store, ledger: PassLedger(), locale: Fixtures.es)
        for fix in fixes.prefix(150) { _ = first.ingest(fix) }
        XCTAssertNotNil(first.snapshot.stretch)
        XCTAssertEqual(first.ledger.stretch?.radar.id, "dgt_invive-Tramo_Invive_344", "the ledger carries the stretch for the relaunch")

        let second = AlertEngine(store: store, ledger: first.ledger, locale: Fixtures.es)
        XCTAssertEqual(second.snapshot.stretch?.radar.id, "dgt_invive-Tramo_Invive_344", "restored before the first fix")
        var events: [AlertEvent] = []
        var phasesAfterExit: [DrivePhase] = []
        for fix in fixes[150...] {
            let e = second.ingest(fix)
            events.append(contentsOf: e)
            if !events.isEmpty, events.contains(where: { if case .stretchExited = $0.kind { return true } else { return false } }) {
                phasesAfterExit.append(second.snapshot.content.phase)
            }
        }
        XCTAssertEqual(events.map(\.kind), [.stretchExited(.farGate)])
        XCTAssertEqual(events.first?.phrase?.spoken, "Fin de tramo.")
        XCTAssertNil(second.ledger.stretch, "the exit clears the stretch in the ledger")
        XCTAssertFalse(phasesAfterExit.contains(.insideStretch), "the card leaves the stretch: \(phasesAfterExit)")
        XCTAssertEqual(second.snapshot.content.phase, .watching)
    }

    /// The restore is consistent with the pass state: a stretch whose pass is already over is not re-entered.
    func testRelaunchAfterTheStretchWasPassedDoesNotRestoreIt() throws {
        let corridor = try Fixtures.radar("dgt_invive-Tramo_Invive_344")
        var ledger = PassLedger(entries: [PassLedger.Entry(id: corridor.id, firedAt: t0, level: .full, passedAt: t0.addingTimeInterval(600))])
        ledger.stretch = DriveSnapshot.StretchState(radar: corridor, enteredAt: t0, entryGate: corridor.start)
        let engine = AlertEngine(store: try store(), ledger: ledger, locale: Fixtures.es)
        XCTAssertNil(engine.snapshot.stretch)
        XCTAssertNil(engine.ledger.stretch)
    }

    /// A relaunch inside an average-speed section: the path before the relaunch is estimated from the chord, so the
    /// average stays near the real one instead of restarting from zero over the whole elapsed time.
    func testRelaunchInsideASectionKeepsTheAverage() throws {
        let vector = try Vector.load("section-z40-100kmh")
        let fixes = vector.fixList
        let store = try store()
        let first = AlertEngine(store: store, ledger: PassLedger(), locale: Fixtures.es)
        for fix in fixes.prefix(107) { _ = first.ingest(fix) }
        let second = AlertEngine(store: store, ledger: first.ledger, locale: Fixtures.es)
        for fix in fixes[107..<140] { _ = second.ingest(fix) }
        let avg = try XCTUnwrap(second.snapshot.stretch?.avgKmh)
        XCTAssertEqual(avg, 100, accuracy: 5, "the path before the relaunch is estimated from the entry position; a restart from zero would read about 50")
    }

    /// A point radar inside a corridor owns the card while it is ahead and for the 4 s passed card, then the
    /// stretch card comes back; the voice and the stretch exit are unchanged.
    func testPointInsideAStretchOwnsTheCardUntilPassed() throws {
        let vector = try Vector.load("corridor-n232-from-west")
        let corridor = try Fixtures.radar("dgt_invive-Tramo_Invive_344")
        let end = try XCTUnwrap(corridor.end)
        let onChord = Geo.destination(from: corridor.start, bearingDegrees: Geo.bearing(from: corridor.start, to: end), metres: 5000)
        let point = makeRadar(id: "inside", start: onChord, name: "Radar fijo N-232", road: "N-232", kmFrom: 25.8, maxspeed: 90)
        let clock = TestClock(t0)
        let engine = AlertEngine(store: RadarStore(radars: try store().all + [point]), ledger: PassLedger(), now: { clock.now }, locale: Fixtures.es)
        var kinds: [AlertEvent.Kind] = []
        var cardWhileAhead: [DriveContent] = []
        var passedCards = 0
        var backInside = false
        var fired = false, passed = false
        for fix in vector.fixList {
            clock.now = fix.timestamp
            let events = engine.ingest(fix)
            kinds.append(contentsOf: events.map(\.kind))
            for e in events where e.radar?.id == point.id {
                if case .warn(.full) = e.kind { fired = true; XCTAssertEqual(e.phrase?.spoken, "Radar fijo a 600 metros. Límite 90.") }
                if case .passed = e.kind { passed = true }
            }
            let card = engine.snapshot.content
            if fired, !passed { cardWhileAhead.append(card) }
            if passed, card.phase == .passed { passedCards += 1 }
            if passed, card.phase == .insideStretch { backInside = true }
        }
        XCTAssertTrue(fired && passed)
        XCTAssertFalse(cardWhileAhead.isEmpty)
        XCTAssertTrue(cardWhileAhead.allSatisfy { $0.phase == .alert && $0.title == "Radar fijo" && $0.distanceMetres != nil }, "the point owns the card while ahead: \(cardWhileAhead.map(\.phase))")
        let distances = cardWhileAhead.compactMap(\.distanceMetres)
        XCTAssertGreaterThan(distances.first ?? 0, distances.last ?? 0, "the card counts down: \(distances)")
        XCTAssertEqual(passedCards, Int(Thresholds.passedCardSeconds), "Radar superado holds for the designed seconds at 1 Hz")
        XCTAssertTrue(backInside, "the stretch card returns after the pass")
        XCTAssertTrue(kinds.contains(.stretchExited(.farGate)))
        XCTAssertEqual(engine.snapshot.content.phase, .watching)
    }

    /// A fixed radar 100 m before a corridor gate at 90 km/h: its sentence and, 4 s later, the stretch sentence.
    /// Pacing never silences a stretch entry; a point inside the gap after it is still visual.
    func testStretchEntryIsSpokenInsideThePacingGap() throws {
        let vector = try Vector.load("corridor-n232-from-west")
        let corridor = try Fixtures.radar("dgt_invive-Tramo_Invive_344")
        let end = try XCTUnwrap(corridor.end)
        let into = Geo.bearing(from: corridor.start, to: end)
        let before = Geo.destination(from: corridor.start, bearingDegrees: Geo.normalize(into + 180), metres: 100)
        let point = makeRadar(id: "beforeGate", start: before, name: "Radar fijo N-232", road: "N-232", kmFrom: 20.7, maxspeed: 90)
        let engine = AlertEngine(store: RadarStore(radars: try store().all + [point]), ledger: PassLedger(), locale: Fixtures.es)
        var events: [(Date, AlertEvent)] = []
        for fix in vector.fixList { events.append(contentsOf: engine.ingest(fix).map { (fix.timestamp, $0) }) }
        let warn = try XCTUnwrap(events.first { if case .warn(.full) = $0.1.kind { return $0.1.radar?.id == point.id } else { return false } })
        let entered = try XCTUnwrap(events.first { $0.1.kind == .stretchEntered })
        XCTAssertLessThan(entered.0.timeIntervalSince(warn.0), Thresholds.pacingSeconds, "the layout must put the entry inside the gap")
        XCTAssertEqual(warn.1.phrase?.spoken, "Radar fijo a 600 metros. Límite 90.")
        XCTAssertEqual(entered.1.phrase?.spoken, "Tramo de radar móvil, N-232, 10 kilómetros.")
        XCTAssertEqual(events.last?.1.phrase?.spoken, "Fin de tramo.")

        // The other order: a point 100 m past the gate fires inside the gap after the stretch sentence and is visual.
        let after = Geo.destination(from: corridor.start, bearingDegrees: into, metres: 100)
        let pointAfter = makeRadar(id: "afterGate", start: after, name: "Radar fijo N-232", road: "N-232", kmFrom: 20.9, maxspeed: 90)
        let second = AlertEngine(store: RadarStore(radars: try store().all + [pointAfter]), ledger: PassLedger(), locale: Fixtures.es)
        var later: [AlertEvent] = []
        for fix in vector.fixList { later.append(contentsOf: second.ingest(fix)) }
        let afterWarn = try XCTUnwrap(later.first { $0.radar?.id == pointAfter.id })
        XCTAssertEqual(afterWarn.kind, .warn(.visual))
        XCTAssertNil(afterWarn.phrase)
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

    /// Two radars armed ahead, the nearer one changing as the car moves: the card keeps the radar it shows until it
    /// fires or drops out, so a city does not flip the card (and spend a Live Activity update) every few fixes.
    func testSnapshotKeepsTheArmedRadarItShowsWhileItStaysArmed() throws {
        let origin = Coordinate.at(41.3, -1.9)
        // A on the line 940 m ahead; B 700 m ahead and 600 m beside (922 m away, 41° off the course): B is nearer
        // for the first fixes, A from the sixth, and neither is in range (warn 750 m at 30 m/s) before the eighth.
        let a = makeRadar(id: "A", start: Geo.destination(from: origin, bearingDegrees: 90, metres: 940))
        let b = makeRadar(id: "B", start: Geo.destination(from: Geo.destination(from: origin, bearingDegrees: 90, metres: 700), bearingDegrees: 0, metres: 600))
        let engine = AlertEngine(store: RadarStore(radars: [a, b]), ledger: PassLedger(), locale: Fixtures.es)
        var shown: [String] = []
        for i in 0..<7 {
            let fix = makeFix(Geo.destination(from: origin, bearingDegrees: 90, metres: Double(i) * 30), t: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)), speed: 30, course: 90)
            XCTAssertTrue(engine.ingest(fix).isEmpty, "fix \(i) must not fire")
            shown.append(engine.snapshot.next?.id ?? "-")
        }
        XCTAssertEqual(shown.first, "B", "B is the nearer armed radar at the start")
        XCTAssertEqual(Set(shown).count, 1, "the card stays on B while B stays armed: \(shown)")
    }

    /// A corridor chord passing beside the car does not take the card from a point ahead, and the "cerca" card can
    /// name a line the car is beside: the chord makes it a candidate.
    func testALineIsACandidateByItsChord() throws {
        let corridor = try Fixtures.radar("dgt_invive-Tramo_Invive_344")
        let end = try XCTUnwrap(corridor.end)
        let mid = Geo.destination(from: corridor.start, bearingDegrees: Geo.bearing(from: corridor.start, to: end), metres: 5000)
        let beside = Geo.destination(from: mid, bearingDegrees: Geo.bearing(from: corridor.start, to: end) + 90, metres: 100)
        let found = try store().candidates(near: beside, within: 500, on: t0)
        XCTAssertTrue(found.contains { $0.id == corridor.id }, "5 km from both gates, 100 m from the chord")
        XCTAssertFalse(try store().candidates(near: Geo.destination(from: mid, bearingDegrees: 0, metres: 2000), within: 500, on: t0).contains { $0.id == corridor.id })
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
