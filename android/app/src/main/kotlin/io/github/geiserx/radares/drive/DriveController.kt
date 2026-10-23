// SPDX-License-Identifier: GPL-3.0-or-later
//
// The drive, without Android in it (SPEC 8), so the tests drive it with a list of fixes and a fake clock:
//
//   idle -> probing (a wake-up)  -> driving (three fixes at 6 m/s within 60 s, or at once after an IN_VEHICLE
//                                   transition in the last 3 min)
//        probing -> stopped       (60 s without a drive: the fence is re-armed where the phone is, the service stops)
//   driving <-> paused            (the core DrivingDetector: stationary or 120 s under 1 m/s; a resume at 3 m/s)
//   driving/paused -> ended       (ON_FOOT, a pause over 10 min, or the detector's end): engine.endDrive, the
//                                   ledger written, the driveEnded row, the fence re-armed 400 m around the last fix
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

class DriveController(
    private val clock: () -> Instant,
    private val engineFactory: () -> AlertEngine?,
    private val sink: EventSink,
    private val events: AppEvents,
    private val ledgerSaver: (PassLedger) -> Unit,
    private val armFence: (Coordinate) -> Unit,
    private val stopService: () -> Unit,
    /** An IN_VEHICLE enter in the last Thresholds.motionWindowSeconds. */
    private val recentInVehicle: () -> Boolean,
    private val onDriveStart: () -> Unit = {},
    private val locale: Locale = Locale.getDefault(),
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
                if (state == State.Idle) {
                    this.wake = wake
                    wakeAt = now
                    probeMaxSpeed = 0.0
                    detector = DrivingDetector()
                    state = State.Probing(now)
                }
                if (wake == Wake.InVehicle || recentInVehicle()) startDrive()
            }
        }
    }

    fun onFix(fix: Fix) {
        when (val s = state) {
            State.Idle -> return
            is State.Probing -> {
                probeMaxSpeed = maxOf(probeMaxSpeed, fix.speed ?: 0.0)
                lastFix = fix
                if (detector.ingest(fix) == DriveSignal.STARTED) {
                    startDrive()
                    ingest(fix)
                } else if (clock().secondsSince(s.since) >= Thresholds.probeSeconds) {
                    finishProbe("timeout")
                }
            }
            State.Driving, is State.Paused -> {
                when (detector.ingest(fix)) {
                    DriveSignal.PAUSED -> {
                        state = State.Paused(fix.timestamp)
                        events.drivePaused()
                    }
                    DriveSignal.RESUMED -> {
                        val since = (state as? State.Paused)?.since
                        state = State.Driving
                        events.driveResumed(since?.let { fix.timestamp.secondsSince(it) } ?: 0.0)
                    }
                    DriveSignal.ENDED -> {
                        ingest(fix)
                        endDrive("pause_over")
                        return
                    }
                    else -> Unit
                }
                ingest(fix)
            }
        }
    }

    /** Once a second from the service: the probe timeout and the pause end, which no fix may bring. */
    fun onTick() {
        val now = clock()
        when (val s = state) {
            is State.Probing -> if (now.secondsSince(s.since) >= Thresholds.probeSeconds) finishProbe("timeout")
            is State.Paused -> if (now.secondsSince(s.since) >= Thresholds.pauseEndMinutes * 60) endDrive("pause_over")
            else -> Unit
        }
    }

    private fun startDrive() {
        if (driveOn) return
        engine = engineFactory()
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
        firstFixAt = null
        fixes = 0
        alerts = 0
        maxGapSeconds = 0.0
        metres = 0.0
        firstWarnAfterWakeM = null
        hadLateAlert = false
        lastMovingFixAt = null
        lastFixLoggedAt = null
        events.driveStarted(wake ?: Wake.InVehicle)
        onDriveStart()
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

    private fun endDrive(why: String) {
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
