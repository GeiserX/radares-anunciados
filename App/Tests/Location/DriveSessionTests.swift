// Lane: location
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The parts of the location lane that run without Core Location: the CLLocation to Fix rule, the persisted drive,
// and the drive counters that end up in the driveEnded row. The state machine itself is exercised on the Simulator
// (docs/VERIFY.md, "State-machine run").

import CoreLocation
import RadaresCore
import XCTest
@testable import RadaresAnunciados

final class DriveSessionTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "io.github.geiserx.radares.tests.DriveSessionTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: DriveSession.stateMachineOnlyArgument)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func location(lat: Double, lon: Double, speed: Double, course: Double, at t: TimeInterval) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: course,
            courseAccuracy: 3,
            speed: speed,
            speedAccuracy: 1,
            timestamp: Date(timeIntervalSince1970: t)
        )
    }

    func testFixDropsNegativeSpeedAndCourse() {
        let invalid = DriveSession.fix(from: location(lat: 41.3, lon: -1.9, speed: -1, course: -1, at: 0), isStationary: true)
        XCTAssertNil(invalid.speed)
        XCTAssertNil(invalid.course)
        XCTAssertTrue(invalid.isStationary)

        let valid = DriveSession.fix(from: location(lat: 41.3, lon: -1.9, speed: 33.3, course: 90, at: 0), isStationary: false)
        XCTAssertEqual(valid.speed, 33.3)
        XCTAssertEqual(valid.course, 90)
        XCTAssertEqual(valid.horizontalAccuracy, 5)
        XCTAssertEqual(valid.coordinate, Coordinate(latitude: 41.3, longitude: -1.9))
    }

    func testPersistedDriveRoundTrip() {
        let fix = Fix(coordinate: Coordinate(latitude: 1, longitude: 2), timestamp: Date(timeIntervalSince1970: 10), speed: 3, horizontalAccuracy: 5)
        let drive = PersistedDrive(
            startedAt: Date(timeIntervalSince1970: 1),
            reason: .wakeup(.monitor),
            lastFix: fix,
            backgroundActivitySessionOutstanding: true,
            pausedSince: Date(timeIntervalSince1970: 20),
            wakeAt: Date(timeIntervalSince1970: 0),
            firstFixAt: Date(timeIntervalSince1970: 10)
        )
        drive.save(to: defaults)
        XCTAssertEqual(PersistedDrive.load(from: defaults), drive)
        PersistedDrive.clear(from: defaults)
        XCTAssertNil(PersistedDrive.load(from: defaults))
    }

    func testCountersInDriveEndedRow() async {
        let session = DriveSession(suiteName: suite)
        await session.begin(reason: .wakeup(.slc), wakeAt: Date(timeIntervalSince1970: 100), backgroundActivity: false)
        func fix(_ t: TimeInterval, lon: Double, speed: Double?) -> Fix {
            Fix(coordinate: Coordinate(latitude: 41.3, longitude: lon), timestamp: Date(timeIntervalSince1970: t), speed: speed, horizontalAccuracy: 5)
        }
        await session.ingest(fix(130, lon: -1.900, speed: 10), paused: false)
        await session.ingest(fix(131, lon: -1.901, speed: 10), paused: false)
        // A 15 s hole while moving is the gap the health rule reads.
        await session.ingest(fix(146, lon: -1.902, speed: 10), paused: false)
        // Fixes while paused or under 1 m/s never widen the gap.
        await session.ingest(fix(200, lon: -1.902, speed: 0.2), paused: true)
        await session.ingest(fix(260, lon: -1.902, speed: 0.2), paused: false)
        let persisted = await session.persisted
        XCTAssertEqual(persisted?.firstFixAt, Date(timeIntervalSince1970: 130))

        let row = await session.end()
        guard case let .driveEnded(fixes, maxGapSeconds, alerts, firstFixAfterWakeS, firstWarnAfterWakeM) = row else {
            return XCTFail("expected a driveEnded row, got \(row)")
        }
        XCTAssertEqual(fixes, 5)
        XCTAssertEqual(maxGapSeconds, 15)
        XCTAssertEqual(alerts, 0)
        XCTAssertEqual(firstFixAfterWakeS, 30)
        XCTAssertNil(firstWarnAfterWakeM, "no engine ran, so no warn")
        XCTAssertNil(PersistedDrive.load(from: defaults), "the drive is forgotten at its end")
        let active = await session.isActive
        XCTAssertFalse(active)
    }

    /// Design 2.6: the ledger is written on warn and pass (and stretch entry and exit, and drive end), never on a
    /// quiet fix. Dropping the write on warn would repeat the voice after a kill between the warning and the pass.
    func testLedgerIsPersistedOnWarnAndPassNotOnAQuietFix() {
        XCTAssertTrue(DriveSession.persistsLedger(after: [.warn(.full)], force: false))
        XCTAssertTrue(DriveSession.persistsLedger(after: [.warn(.visual)], force: false))
        XCTAssertTrue(DriveSession.persistsLedger(after: [.passed], force: false))
        XCTAssertTrue(DriveSession.persistsLedger(after: [.stretchEntered], force: false))
        XCTAssertTrue(DriveSession.persistsLedger(after: [.stretchExited(.farGate)], force: false))
        XCTAssertFalse(DriveSession.persistsLedger(after: [], force: false), "a quiet fix writes nothing")
        XCTAssertFalse(DriveSession.persistsLedger(after: [.driveEnded], force: false), "the drive end writes through force")
        XCTAssertTrue(DriveSession.persistsLedger(after: [.driveEnded], force: true))
    }

    /// A stretch in the ledger belongs to the drive that was killed inside it: a resumed drive restores it, a new
    /// drive (the same ledger, a different day or place) starts outside every stretch.
    func testTheLedgerStretchIsRestoredOnlyForAResumedDrive() {
        let radar = Radar(id: "s", kind: .stretch, role: .mobileCorridor, start: Coordinate(latitude: 40.5, longitude: 0.13), end: Coordinate(latitude: 40.51, longitude: 0.24), name: "N-232", source: "dgt_invive", attribution: "")
        var ledger = PassLedger(entries: [PassLedger.Entry(id: "s", firedAt: Date(timeIntervalSince1970: 0))])
        ledger.stretch = DriveSnapshot.StretchState(radar: radar, enteredAt: Date(timeIntervalSince1970: 0), entryGate: radar.start)
        XCTAssertNotNil(DriveSession.ledgerForEngine(ledger, resuming: true).stretch)
        XCTAssertNil(DriveSession.ledgerForEngine(ledger, resuming: false).stretch)
        XCTAssertEqual(DriveSession.ledgerForEngine(ledger, resuming: false).entries.count, 1, "the passes stay either way")
    }

    /// The surfaces run off the fix loop: enqueue returns while the first job is still held at a gate, the second
    /// job waits for the first, drain waits for both. A queue that ran jobs inline would never return from the
    /// first enqueue, which the 3 s race turns into a failure instead of a hang.
    func testSurfaceQueueRunsInOrderWithoutHoldingTheCaller() async {
        let queue = SerialTaskQueue()
        let order = Order()
        let gate = Gate()
        let returned = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await queue.enqueue {
                    await gate.wait()
                    await order.add(1)
                }
                await queue.enqueue { await order.add(2) }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(returned, "enqueue must return while the first job is still held at the gate")
        let before = await order.seen
        XCTAssertEqual(before, [], "nothing has run while the first job is held")
        await gate.open()
        await queue.drain()
        let after = await order.seen
        XCTAssertEqual(after, [1, 2], "in order, the second after the first")
    }

    private actor Order {
        var seen: [Int] = []
        func add(_ n: Int) { seen.append(n) }
    }

    private actor Gate {
        private var isOpen = false
        func open() { isOpen = true }
        func wait() async {
            while !isOpen { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    func testMetresIsHaversine() {
        // 0.01 degrees of longitude at 41.3 degrees north is about 836 m.
        let d = DriveSession.metres(Coordinate(latitude: 41.3, longitude: -1.90), Coordinate(latitude: 41.3, longitude: -1.91))
        XCTAssertEqual(d, 836, accuracy: 2)
    }
}
