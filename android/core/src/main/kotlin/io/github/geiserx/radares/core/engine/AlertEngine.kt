// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Engine/AlertEngine.swift.
// ingest(fix) -> List<AlertEvent>: candidates, course, warn distance, approach, pass state, stretches, pacing (design 2).
// Pure given the store: no I/O. The fix timestamps are the clock while driving (so a route vector replays hours in
// milliseconds); `now` is only read where no fix is involved (endDrive, the passed card's 4 s). Its default is the
// wall clock, exactly as AlertEngine.swift defaults to Date.init.
// The owner (the drive service) persists `ledger` on warn, passed, stretch entry and exit and drive end; the ledger
// carries the stretch the car is inside, so an engine rebuilt after a relaunch resumes it.

package io.github.geiserx.radares.core.engine

import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.feed.RadarStore
import io.github.geiserx.radares.core.geo.Geo
import io.github.geiserx.radares.core.health.StretchExitReason
import io.github.geiserx.radares.core.model.Fix
import io.github.geiserx.radares.core.model.Kind
import io.github.geiserx.radares.core.model.Radar
import io.github.geiserx.radares.core.model.Role
import io.github.geiserx.radares.core.phrasing.Phrasing
import io.github.geiserx.radares.core.roundHalfAway
import io.github.geiserx.radares.core.secondsSince
import java.time.Instant
import java.util.Locale
import kotlin.math.max

class AlertEngine(
    private val store: RadarStore,
    ledger: PassLedger,
    private val now: () -> Instant = Instant::now,
    private val locale: Locale = Locale.getDefault(),
) {
    private val passes = PassTracker(ledger)
    private val stretches: StretchTracker
    private var previousFix: Fix? = null
    /// The fixes of the last Thresholds.courseFallbackWindowSeconds, oldest first: the baseline of a derived course.
    private var recentFixes: MutableList<Fix> = mutableListOf()
    /// Last valid speeds, oldest first, at most Thresholds.speedMedianFixes.
    private var speeds: MutableList<Double> = mutableListOf()
    /// Distances to each point candidate on earlier fixes since it entered the band (first kept, tail bounded).
    private var histories: MutableMap<String, List<Double>> = mutableMapOf()
    /// Fired points not yet passed: the minimum seen and the run of increases after it.
    private var passing: MutableMap<String, PassWatch> = mutableMapOf()
    private var lastSpokenAt: Instant? = null
    private var lastPassed: Pair<Radar, Instant>? = null
    private var current: DriveSnapshot

    /// Why the last stretch was left, for the log row the drive service writes.
    var lastStretchExitReason: StretchExitReason? = null
        private set

    private data class PassWatch(
        val minDistance: Double,
        val lastDistance: Double,
        val increases: Int = 0,
        val opposite: Boolean,
    )

    init {
        // The stretch the previous process was inside, while its pass is still open (design 2.5, relaunch).
        val resumed = ledger.stretch?.let { state -> if (ledger.entry(state.radar.id)?.passedAt == null) state else null }
        stretches = StretchTracker(resumed)
        var c = DriveSnapshot.empty(now(), locale)
        val state = stretches.inside
        if (state != null) {
            // The card is the stretch's from the start, not "Sin radares cerca" until the first fix after the relaunch.
            c = c.copy(stretch = state, next = state.radar, distanceMetres = state.remainingMetres)
            current = c
            current = c.copy(content = stretchContent(null, now()))
        } else {
            current = c
        }
    }

    /// The pass ledger plus the stretch the car is inside: what the owner persists.
    val ledger: PassLedger get() = passes.ledger.copy(stretch = stretches.inside)

    val snapshot: DriveSnapshot
        get() {
            var s = current
            val passed = lastPassed
            if (s.content.phase == DrivePhase.PASSED && passed != null && now().secondsSince(passed.second) >= Thresholds.passedCardSeconds) {
                val t = now()
                s = s.copy(content = if (stretches.inside != null) stretchContent(s.speedMps, t) else DriveContent.watching(t, locale))
            }
            return s
        }

    // Ingest

    fun ingest(fix: Fix): List<AlertEvent> {
        val t = fix.timestamp
        val events = mutableListOf<AlertEvent>()

        recentFixes.removeAll { t.secondsSince(it.timestamp) > Thresholds.courseFallbackWindowSeconds }
        val course = courseInUse(fix)
        recentFixes.add(fix)
        previousFix = fix

        val s0 = fix.speed
        if (s0 != null && s0 >= 0) {
            speeds.add(s0)
            if (speeds.size > Thresholds.speedMedianFixes) speeds = speeds.takeLast(Thresholds.speedMedianFixes).toMutableList()
        }
        val median = WarnPolicy.medianSpeed(speeds)
        val warn = WarnPolicy.warnDistance(median ?: 0.0)

        val candidates = store.candidates(fix.coordinate, warn + Thresholds.candidateBandM, t)

        // The 2 km half of the cooldown: how far the car has been from every fired radar.
        for (entry in passes.ledger.entries) {
            if (!(entry.farthestMetres < Thresholds.cooldownM)) continue
            val radar = store.radar(entry.id) ?: continue
            passes.observe(entry.id, RadarStore.gateDistance(fix.coordinate, radar))
        }

        // Stretches first: an entry is one event, an exit another, never both on one fix.
        val lines = candidates.filter { it.isLine && passes.canFire(it.id, t) }
        when (val change = stretches.ingest(fix, course, warn, median, lines, t)) {
            is StretchTracker.Change.Entered -> {
                val radar = change.radar
                val approach = change.approach
                if (change.level == Level.FULL) {
                    // A stretch entry is spoken whatever the pacing clock says (design 2.6).
                    passes.fire(radar.id, Level.FULL, t)
                    lastSpokenAt = t
                    val content = stretchContent(median, t)
                    val draft = AlertEvent(kind = AlertEvent.Kind.StretchEntered, radar = radar, distance = approach.distanceMetres, late = approach.late, crossTrackMetres = approach.crossTrackMetres, phrase = null, content = content)
                    val remaining = change.remainingMetres
                    val phrase = if (remaining != null) Phrasing.makeJoined(draft, remaining, locale) else Phrasing.make(draft, locale)
                    events.add(draft.copy(phrase = phrase))
                } else {
                    passes.fire(radar.id, Level.VISUAL, t)
                    passing[radar.id] = PassWatch(minDistance = approach.distanceMetres, lastDistance = approach.distanceMetres, opposite = true)
                    val content = radarContent(radar, DrivePhase.ALERT, approach.distanceMetres, median, true, t)
                    events.add(AlertEvent(kind = AlertEvent.Kind.Warn(Level.VISUAL), radar = radar, distance = approach.distanceMetres, late = approach.late, crossTrackMetres = approach.crossTrackMetres, phrase = null, content = content))
                }
            }
            is StretchTracker.Change.Exited -> {
                passes.markPassed(change.radar.id, t)
                lastStretchExitReason = change.reason
                val draft = AlertEvent(kind = AlertEvent.Kind.StretchExited(change.reason), radar = change.radar, content = DriveContent.watching(t, locale))
                events.add(draft.copy(phrase = if (change.reason == StretchExitReason.FAR_GATE) Phrasing.make(draft, locale) else null))
            }
            null -> {}
        }

        // Points (design 2.3): record the distance history, evaluate, arm or fire.
        val fires = mutableListOf<Pair<Radar, Approach>>()
        val seen = mutableSetOf<String>()
        for (radar in candidates) {
            if (radar.isLine) continue
            seen.add(radar.id)
            val previous = histories[radar.id] ?: emptyList()
            val distance = Geo.distance(fix.coordinate, radar.start)
            val h = previous.toMutableList()
            h.add(distance)
            if (h.size > 8) h.removeAt(1)
            histories[radar.id] = h

            if (course == null || !passes.canFire(radar.id, t)) continue
            val approach = ApproachEvaluator.evaluate(radar.start, radar.bearing, radar.bidirectional, fix, course, previous, warn)
            if (approach.level != null) {
                fires.add(radar to approach)
            } else if (approach.ahead) {
                passes.arm(radar.id)
            } else {
                passes.disarm(radar.id)
            }
        }
        histories = histories.filterKeys { it in seen }.toMutableMap()

        // Pacing and the combined sentence (design 2.6): one voice per fix and per 8 s; the rest are shown.
        fires.sortBy { it.second.distanceMetres }
        var spoken: Pair<Radar, Approach>? = null
        var second: Double? = null
        val fired = mutableListOf<Triple<Radar, Approach, Level>>()
        for ((radar, approach) in fires) {
            var level = approach.level ?: Level.VISUAL
            if (level == Level.FULL) {
                val last = lastSpokenAt
                if (approach.distanceMetres < Thresholds.noVoiceBelowM) {
                    level = Level.VISUAL
                } else if (last != null && t.secondsSince(last) < Thresholds.pacingSeconds) {
                    level = Level.VISUAL
                } else if (spoken != null) {
                    level = Level.VISUAL
                    if (second == null) second = approach.distanceMetres
                } else {
                    spoken = radar to approach
                }
            }
            passes.fire(radar.id, level, t)
            passing[radar.id] = PassWatch(minDistance = approach.distanceMetres, lastDistance = approach.distanceMetres, opposite = !approach.directionMatch)
            fired.add(Triple(radar, approach, level))
        }
        if (spoken != null) lastSpokenAt = t
        for ((radar, approach, level) in fired) {
            val opposite = !approach.directionMatch
            val content = radarContent(radar, DrivePhase.ALERT, approach.distanceMetres, median, opposite, t)
            val draft = AlertEvent(kind = AlertEvent.Kind.Warn(level), radar = radar, distance = approach.distanceMetres, late = approach.late, crossTrackMetres = approach.crossTrackMetres, phrase = null, content = content)
            val isSpoken = level == Level.FULL && spoken?.first?.id == radar.id
            events.add(draft.copy(phrase = if (isSpoken) Phrasing.make(draft, locale, second) else null))
        }

        // Passed (design 2.3): three increases of at least closingMinM after the minimum, the distance at least
        // max(passedMinRiseM, accuracy) above it, or under 30 m. GPS wander while stopped before the radar is no pass.
        for (id in passes.firedIds) {
            val radar = store.radar(id) ?: continue
            if (radar.isLine) continue
            val distance = Geo.distance(fix.coordinate, radar.start)
            var watch = passing[id]
            if (watch == null) {
                passing[id] = PassWatch(minDistance = distance, lastDistance = distance, opposite = false)
                continue
            }
            if (fired.any { it.first.id == id }) continue
            var passed = distance < Thresholds.passedBelowM
            if (!passed) {
                if (distance < watch.minDistance) {
                    watch = watch.copy(minDistance = distance, increases = 0)
                } else if (distance - watch.lastDistance >= Thresholds.closingMinM) {
                    watch = watch.copy(increases = watch.increases + 1)
                    val rise = distance - watch.minDistance
                    passed = watch.increases >= Thresholds.passedFixes && rise >= max(Thresholds.passedMinRiseM, fix.horizontalAccuracy)
                } else {
                    watch = watch.copy(increases = 0)
                }
            }
            watch = watch.copy(lastDistance = distance)
            passing[id] = watch
            if (passed) {
                passes.markPassed(id, t)
                passing.remove(id)
                lastPassed = radar to t
                val content = radarContent(radar, DrivePhase.PASSED, distance, median, false, t)
                events.add(AlertEvent(kind = AlertEvent.Kind.Passed, radar = radar, distance = distance, late = false, crossTrackMetres = null, phrase = null, content = content))
            }
        }
        val firedNow = passes.firedIds.toSet()
        passing = passing.filterKeys { it in firedNow }.toMutableMap()

        current = buildSnapshot(fix, course, median, candidates, t)
        return events
    }

    fun endDrive(): List<AlertEvent> {
        val t = now()
        val events = mutableListOf<AlertEvent>()
        val change = stretches.endDrive()
        if (change is StretchTracker.Change.Exited) {
            passes.markPassed(change.radar.id, t)
            lastStretchExitReason = change.reason
            events.add(AlertEvent(kind = AlertEvent.Kind.StretchExited(change.reason), radar = change.radar, content = DriveContent.watching(t, locale)))
        }
        passes.prune(t)
        histories = mutableMapOf()
        passing = mutableMapOf()
        speeds = mutableListOf()
        previousFix = null
        recentFixes = mutableListOf()
        lastSpokenAt = null
        lastPassed = null
        current = DriveSnapshot.empty(t, locale)
        events.add(AlertEvent(kind = AlertEvent.Kind.DriveEnded, radar = null, content = DriveContent.watching(t, locale)))
        return events
    }

    // Course (design 2.3)

    /// The platform course at road speed; the platform course when the platform marked the speed invalid but the car
    /// moved at road speed since the previous fix; else the heading from the most recent fix of the last
    /// courseFallbackWindowSeconds at least courseFallbackMinM behind; else nothing.
    private fun courseInUse(fix: Fix): Double? {
        val c = fix.course
        if (c != null && (fix.speed ?: 0.0) >= Thresholds.courseMinSpeedMps) return c
        val prev = previousFix
        if (c != null && fix.speed == null && prev != null) {
            val seconds = max(1.0, fix.timestamp.secondsSince(prev.timestamp))
            if (Geo.distance(prev.coordinate, fix.coordinate) >= Thresholds.courseMinSpeedMps * seconds) return c
        }
        val baseline = recentFixes.lastOrNull { Geo.distance(it.coordinate, fix.coordinate) >= Thresholds.courseFallbackMinM }
        if (baseline != null) return Geo.bearing(baseline.coordinate, fix.coordinate)
        return null
    }

    // Content

    private fun radarContent(radar: Radar, phase: DrivePhase, distance: Double?, median: Double?, opposite: Boolean, at: Instant): DriveContent {
        val en = Phrasing.isEnglish(locale)
        var title = Phrasing.kindTitle(radar, locale)
        if (phase == DrivePhase.PASSED) title = if (en) "Radar passed" else "Radar superado"
        return DriveContent(
            phase = phase,
            kindSymbol = symbol(radar),
            title = title,
            subtitle = Phrasing.subtitle(radar, locale),
            distanceMetres = distance?.let { roundHalfAway(it).toInt() },
            limit = radar.maxspeed,
            speedKmh = median?.let { roundHalfAway(it * 3.6).toInt() },
            opposite = opposite,
            updatedAt = at,
        )
    }

    /// The card inside a stretch: the remaining figure (the surfaces label it "aprox.") and, in a section, the average.
    private fun stretchContent(median: Double?, at: Instant): DriveContent {
        val state = stretches.inside ?: return DriveContent.watching(at, locale)
        return radarContent(state.radar, DrivePhase.INSIDE_STRETCH, null, median, false, at).copy(
            stretchRemainingMetres = state.remainingMetres?.let { roundHalfAway(it).toInt() },
            avgKmh = state.avgKmh?.let { roundHalfAway(it).toInt() },
        )
    }

    /// The card, in this order: a full-fired point not yet passed, the 4 s passed card, an armed point ahead, the
    /// stretch the car is inside, the nearest candidate as "cerca", nothing.
    private fun buildSnapshot(fix: Fix, course: Double?, median: Double?, candidates: List<Radar>, t: Instant): DriveSnapshot {
        val visualIds = passes.ledger.entries.filter { it.passedAt == null && it.level == Level.VISUAL }.map { it.id }.toSet()
        val visualRows = visualIds.mapNotNull { id ->
            val radar = store.radar(id) ?: return@mapNotNull null
            DriveSnapshot.VisualRow(radar, RadarStore.gateDistance(fix.coordinate, radar), passing[id]?.opposite ?: false)
        }.sortedBy { it.distanceMetres }
        val s = DriveSnapshot(
            speedMps = median,
            courseDegrees = course,
            lastFix = fix,
            stretch = stretches.inside,
            visualRows = visualRows,
            content = DriveContent.watching(t, locale),
        )

        // Points only: a line's entry stays "fired" until its exit, and the stretch card below shows it.
        val fullFired = passes.ledger.entries.filter { it.passedAt == null && it.level == Level.FULL }.mapNotNull { store.radar(it.id) }.filter { !it.isLine }
        val nearestFired = fullFired.minByOrNull { Geo.distance(fix.coordinate, it.start) }
        if (nearestFired != null) {
            val d = Geo.distance(fix.coordinate, nearestFired.start)
            return s.copy(next = nearestFired, distanceMetres = d, content = radarContent(nearestFired, DrivePhase.ALERT, d, median, false, t))
        }
        val passed = lastPassed
        if (passed != null && t.secondsSince(passed.second) < Thresholds.passedCardSeconds) {
            return s.copy(next = passed.first, content = radarContent(passed.first, DrivePhase.PASSED, null, median, false, t))
        }
        val armed = candidates.filter { !it.isLine && passes.state(it.id, t) == PassTracker.State.Armed }
        // The card keeps the radar it already shows while that one stays armed, so a city does not flip it.
        val keep = armed.firstOrNull { it.id == current.next?.id } ?: armed.firstOrNull()
        if (keep != null) {
            val d = Geo.distance(fix.coordinate, keep.start)
            return s.copy(next = keep, distanceMetres = d, content = radarContent(keep, DrivePhase.APPROACHING, d, median, false, t))
        }
        val state = stretches.inside
        if (state != null) {
            return s.copy(next = state.radar, distanceMetres = state.remainingMetres, content = stretchContent(median, t))
        }
        val nearest = candidates.firstOrNull()
        if (nearest != null) {
            val d = RadarStore.gateDistance(fix.coordinate, nearest)
            val c = radarContent(nearest, DrivePhase.WATCHING, d, median, false, t).copy(subtitle = if (Phrasing.isEnglish(locale)) "nearby" else "cerca")
            return s.copy(next = nearest, distanceMetres = d, content = c)
        }
        return s.copy(content = DriveContent.watching(t, locale).copy(speedKmh = median?.let { roundHalfAway(it * 3.6).toInt() }))
    }

    companion object {
        /// The kind symbol of the card (SF Symbol names, kept so both apps log the same token; the app maps it).
        fun symbol(radar: Radar): String = when (radar.kind) {
            Kind.FIXED -> "camera.fill"
            Kind.SECTION -> "ruler.fill"
            Kind.STRETCH -> if (radar.role == Role.MOBILE_CORRIDOR) "road.lanes" else "timer"
            Kind.MOBILE_ANNOUNCED -> "camera.badge.clock.fill"
            Kind.MOBILE_RECURRING -> "camera.badge.clock"
            Kind.TRAILER -> "truck.box.fill"
            Kind.REPORTED -> "questionmark.circle"
        }
    }
}
