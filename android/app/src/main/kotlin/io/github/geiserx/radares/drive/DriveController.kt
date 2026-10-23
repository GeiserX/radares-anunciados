// SPDX-License-Identifier: GPL-3.0-or-later
//
// The drive, without Android in it (SPEC 8), so the tests drive it with a list of fixes and a fake clock:
//
//   idle -> probing (a wake-up)  -> driving (three fixes at 6 m/s within 60 s, or at once after an IN_VEHICLE
//                                   transition in the last 3 min)
//        probing -> stopped       (60 s without a drive: the fence is re-armed where the phone is, the service stops)
//   driving <-> paused            (the core DrivingDetector: stationary or 120 s under 1 m/s; a resume at 3 m/s)
//   driving/paused -> ended       (ON_FOOT, a pause over 10 min, or the detector's end): engine.endDrive, the
//                                   ledger written, the driveEnded row, the fence re-armed 400 m around the last fix;
//                                   after a pause over 10 min the service probes again instead of stopping, so a car
//                                   that parked twelve minutes and leaves is driving on its first fixes (SPEC 8)
//   idle -> driving/paused        (restore: the process died mid-drive and the drive record is fresh; the same drive
//                                   continues with the persisted stretch, no new driveStarted row; SPEC 4, 5)
//
// Every fix of a drive (paused included) goes through the engine; the events go to the dispatcher. The ledger is
// written on warn, pass, stretch entry and exit, and at drive end, never per fix (SPEC 4).

package io.github.geiserx.radares.drive

import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.engine.AlertEngine
import io.github.geiserx.radares.core.engine.AlertEvent
import io.github.geiserx.radares.core.engine.DriveSignal
import io.github.geiserx.radares.core.engine.DriveSnapshot
import io.github.geiserx.radares.core.engine.DrivingDetector
import io.github.geiserx.radares.core.engine.PassLedger
import io.github.geiserx.radares.core.geo.Geo
import io.github.geiserx.radares.core.model.Coordinate
import io.github.geiserx.radares.core.model.Fix
import io.github.geiserx.radares.core.secondsSince
import io.github.geiserx.radares.health.AppEvents
import java.time.Instant
import java.util.Locale

/** Where engine events go: the AlertDispatcher in the app, a recorder in tests. */
fun interface EventSink {
    fun handle(event: AlertEvent, fix: Fix?)
}

/** The drive as it must survive a process death (SPEC 4): enough to resume the same drive. */
data class DriveRecord(
    val startedAt: Instant,
    val wakeAt: Instant?,
    val pausedSince: Instant?,
    /** The newest time the drive was known alive; a record older than Thresholds.pauseEndMinutes is a dead drive. */
    val seenAt: Instant,
    val last: Coordinate?,
)

/** Where the drive record lives: SharedPreferences in the app, memory in tests. */
interface DriveRecordStore {
    fun load(): DriveRecord?
    fun save(record: DriveRecord)
    fun clear()

    object None : DriveRecordStore {
        override fun load(): DriveRecord? = null
        override fun save(record: DriveRecord) {}
        override fun clear() {}
    }
}

class DriveController(
    private val clock: () -> Instant,
    /** `resuming` is true only for a drive restored after a process death: its persisted stretch is kept (SPEC 5). */
    private val engineFactory: (resuming: Boolean) -> AlertEngine?,
    private val sink: EventSink,
    private val events: AppEvents,
    private val ledgerSaver: (PassLedger) -> Unit,
    private val armFence: (Coordinate) -> Unit,
    private val stopService: () -> Unit,
    /** An IN_VEHICLE enter in the last Thresholds.motionWindowSeconds. */
    private val recentInVehicle: () -> Boolean,
    private val onDriveStart: () -> Unit = {},
    private val locale: Locale = Locale.getDefault(),
    private val records: DriveRecordStore = DriveRecordStore.None,
) {
    sealed class State {
        data object Idle : State()
        data class Probing(val since: Instant) : State()
        data object Driving : State()
        data class Paused(val since: Instant) : State()
    }

    var state: State = State.Idle
        private set

    /** The card, for the map and the car screen. */
    var snapshot: DriveSnapshot = DriveSnapshot.empty(clock(), locale)
        private set

    var onSnapshot: (DriveSnapshot, Boolean) -> Unit = { _, _ -> }

    private var engine: AlertEngine? = null
    private var detector = DrivingDetector()
    private var wakeAt: Instant? = null
    private var wake: Wake? = null
    private var probeMaxSpeed = 0.0
    private var startedAt: Instant? = null
    private var recordSavedAt: Instant? = null

    // Drive counters for the driveEnded row.
    private var firstFixAt: Instant? = null
    private var lastFix: Fix? = null
    private var lastMovingFixAt: Instant? = null
    private var lastFixLoggedAt: Instant? = null
    private var fixes = 0
    private var alerts = 0
    private var maxGapSeconds = 0.0
    private var metres = 0.0
    private var firstWarnAfterWakeM: Double? = null
    private var hadLateAlert = false

    val driveOn: Boolean get() = state == State.Driving || state is State.Paused

    fun onWake(wake: Wake) {
        val now = clock()
        events.wakeup(wake)
        when (wake) {
            Wake.OnFoot -> {
                // Walking ends the drive (SPEC 8); while probing it is a clear "not in a car".
                when (state) {
                    State.Driving, is State.Paused -> endDrive("on_foot")
                    is State.Probing -> finishProbe("idle")
                    State.Idle -> Unit
                }
            }
            Wake.Still -> Unit
            Wake.InVehicle, Wake.Fence, Wake.SelfTest -> {
                if (driveOn) return
                if (state == State.Idle) beginProbe(wake, now)
                if (wake == Wake.InVehicle || recentInVehicle()) startDrive()
            }
        }
    }

    /**
     * After a process death mid-drive (a START_STICKY restart, or any start while idle): continue the persisted drive
     * when its record is younger than Thresholds.pauseEndMinutes, with the stretch it was inside. Returns true when it
     * resumed; the caller then skips the probe.
     */
    fun restore(): Boolean {
        if (state != State.Idle) return false
        val record = records.load() ?: return false
        val now = clock()
        if (now.secondsSince(record.seenAt) >= Thresholds.pauseEndMinutes * 60) {
            records.clear()
            events.note("drive record expired at restart")
            return false
        }
        val engine = engineFactory(true)
        if (engine == null) {
            records.clear()
            return false
        }
        this.engine = engine
        resetCounters()
        startedAt = record.startedAt
        wakeAt = record.wakeAt
        wake = null
        detector = DrivingDetector()
        state = record.pausedSince?.let { State.Paused(it) } ?: State.Driving
        events.note("drive resumed after a process restart")
        saveRecord(now, record.last)
        return true
    }

    fun onFix(fix: Fix) {
        when (val s = state) {
            State.Idle -> return
            is State.Probing -> probeFix(fix, s)
            State.Driving, is State.Paused -> {
                when (detector.ingest(fix)) {
                    DriveSignal.PAUSED -> {
                        state = State.Paused(fix.timestamp)
                        events.drivePaused()
                        saveRecord(fix.timestamp, fix.coordinate)
                    }
                    // STARTED reaches here only on a drive restored paused: its fresh detector counts three fast fixes.
                    DriveSignal.RESUMED, DriveSignal.STARTED -> (state as? State.Paused)?.let { paused ->
                        state = State.Driving
                        events.driveResumed(fix.timestamp.secondsSince(paused.since))
                        saveRecord(fix.timestamp, fix.coordinate)
                    }
                    DriveSignal.ENDED -> {
                        ingest(fix)
                        endDrive("pause_over", reprobeWith = fix)
                        return
                    }
                    else -> Unit
                }
                ingest(fix)
            }
        }
    }

    private fun probeFix(fix: Fix, probing: State.Probing) {
        probeMaxSpeed = maxOf(probeMaxSpeed, fix.speed ?: 0.0)
        lastFix = fix
        // A phone at rest is no drive: end the probe at once rather than hold the GPS for the whole minute (SPEC 8).
        if (fix.isStationary) {
            finishProbe("idle")
            return
        }
        if (detector.ingest(fix) == DriveSignal.STARTED) {
            startDrive()
            ingest(fix)
        } else if (clock().secondsSince(probing.since) >= Thresholds.probeSeconds) {
            finishProbe("timeout")
        }
    }

    private fun beginProbe(wake: Wake?, at: Instant) {
        this.wake = wake
        wakeAt = at
        probeMaxSpeed = 0.0
        detector = DrivingDetector()
        state = State.Probing(at)
    }

    /** Once a second from the service: the probe timeout and the pause end, which no fix may bring. */
    fun onTick() {
        val now = clock()
        when (val s = state) {
            is State.Probing -> if (now.secondsSince(s.since) >= Thresholds.probeSeconds) finishProbe("timeout")
            is State.Paused -> if (now.secondsSince(s.since) >= Thresholds.pauseEndMinutes * 60) endDrive("pause_over", reprobe = true)
            else -> Unit
        }
    }

    private fun startDrive() {
        if (driveOn) return
        engine = engineFactory(false)
        if (engine == null) {
            // No feed at all: nothing can warn. The Estado row "Datos" is red; stop rather than burn GPS.
            events.probe("no_feed", probeMaxSpeed, secondsSinceWake())
            finish()
            return
        }
        events.probe("driving", probeMaxSpeed, secondsSinceWake())
        state = State.Driving
        // A motion-started drive: the detector starts idle and counts its own three fast fixes; its pause rules
        // apply from then on, and the ON_FOOT transition and the pause timer cover the time before.
        resetCounters()
        startedAt = clock()
        saveRecord(clock(), lastFix?.coordinate)
        events.driveStarted(wake ?: Wake.InVehicle)
        onDriveStart()
    }

    private fun resetCounters() {
        firstFixAt = null
        fixes = 0
        alerts = 0
        maxGapSeconds = 0.0
        metres = 0.0
        firstWarnAfterWakeM = null
        hadLateAlert = false
        lastMovingFixAt = null
        lastFixLoggedAt = null
    }

    /** The drive record, written on start, pause, resume and once a minute while fixes arrive; never per fix. */
    private fun saveRecord(now: Instant, last: Coordinate?) {
        val started = startedAt ?: return
        recordSavedAt = now
        records.save(DriveRecord(started, wakeAt, (state as? State.Paused)?.since, now, last))
    }

    private fun ingest(fix: Fix) {
        val engine = engine ?: return
        if (firstFixAt == null) firstFixAt = fix.timestamp
        lastFix?.let { prev ->
            if (firstFixAt != fix.timestamp) metres += Geo.distance(prev.coordinate, fix.coordinate)
        }
        if ((fix.speed ?: 0.0) >= Thresholds.pauseSlowSpeedMps) {
            lastMovingFixAt?.let { maxGapSeconds = maxOf(maxGapSeconds, fix.timestamp.secondsSince(it)) }
            lastMovingFixAt = fix.timestamp
        }
        lastFix = fix
        fixes += 1
        val now = clock()
        if (lastFixLoggedAt == null || now.secondsSince(lastFixLoggedAt!!) >= Thresholds.fixLogSeconds) {
            lastFixLoggedAt = now
            events.fix(fix)
        }
        if (recordSavedAt == null || now.secondsSince(recordSavedAt!!) >= Thresholds.fixLogSeconds) saveRecord(now, fix.coordinate)
        val produced = engine.ingest(fix)
        dispatch(produced, engine, fix)
        snapshot = engine.snapshot
        onSnapshot(snapshot, true)
    }

    private fun dispatch(produced: List<AlertEvent>, engine: AlertEngine, fix: Fix?) {
        var persist = false
        for (event in produced) {
            when (val k = event.kind) {
                is AlertEvent.Kind.Warn, AlertEvent.Kind.StretchEntered -> {
                    alerts += 1
                    if (firstWarnAfterWakeM == null) firstWarnAfterWakeM = metres
                    if (event.late) hadLateAlert = true
                    persist = true
                    if (k == AlertEvent.Kind.StretchEntered) event.radar?.let { events.stretchEntered(it.id) }
                }
                AlertEvent.Kind.Passed -> {
                    persist = true
                    event.radar?.let { events.passed(it.id) }
                }
                is AlertEvent.Kind.StretchExited -> {
                    persist = true
                    event.radar?.let { events.stretchExited(it.id, k.reason) }
                }
                AlertEvent.Kind.DriveEnded -> persist = true
            }
            sink.handle(event, fix)
        }
        if (persist) ledgerSaver(engine.ledger)
    }

    /**
     * Ends the drive. After a pause over the limit the service does not stop: it probes again, with the fix that
     * brought the end when there is one (`reprobeWith`), or waits for the next fixes (`reprobe`).
     */
    private fun endDrive(why: String, reprobe: Boolean = false, reprobeWith: Fix? = null) {
        val engine = engine
        if (engine != null) {
            dispatch(engine.endDrive(), engine, null)
            ledgerSaver(engine.ledger)
        }
        val firstFixAfterWakeS = if (wakeAt != null && firstFixAt != null) firstFixAt!!.secondsSince(wakeAt!!) else null
        events.driveEnded(fixes, maxGapSeconds, alerts, firstFixAfterWakeS, firstWarnAfterWakeM, hadLateAlert, why)
        lastFix?.let { armFence(it.coordinate) }
        snapshot = DriveSnapshot.empty(clock(), locale)
        onSnapshot(snapshot, false)
        this.engine = null
        records.clear()
        startedAt = null
        recordSavedAt = null
        if (reprobe || reprobeWith != null) {
            val at = reprobeWith?.timestamp ?: clock()
            beginProbe(null, at)
            reprobeWith?.let { probeFix(it, State.Probing(at)) }
            return
        }
        finish()
    }

    private fun finishProbe(result: String) {
        events.probe(result, probeMaxSpeed, secondsSinceWake())
        lastFix?.let { armFence(it.coordinate) }
        finish()
    }

    private fun finish() {
        state = State.Idle
        wake = null
        wakeAt = null
        lastFix = null
        stopService()
    }

    private fun secondsSinceWake(): Double = wakeAt?.let { clock().secondsSince(it) } ?: 0.0
}
