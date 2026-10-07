// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// ingest(_:) -> [AlertEvent]: candidates, course, warn distance, approach, pass state, stretches, pacing (design 2).
// Pure given the store: no I/O. The fix timestamps are the clock while driving (so a route vector replays
// hours in milliseconds); `now` is only read where no fix is involved (endDrive, the passed card's 4 s).
// Owned by the location lane's drive loop, which persists `ledger` on warn, passed, stretch entry and exit and drive
// end; the ledger carries the stretch the car is inside, so an engine rebuilt after a relaunch resumes it.

import Foundation

public final class AlertEngine {
    private let store: RadarStore
    private let now: @Sendable () -> Date
    private let locale: Locale

    private var passes: PassTracker
    private var stretches: StretchTracker
    private var previousFix: Fix?
    /// The fixes of the last Thresholds.courseFallbackWindowSeconds, oldest first: the baseline of a derived course.
    private var recentFixes: [Fix] = []
    /// Last valid speeds, oldest first, at most Thresholds.speedMedianFixes.
    private var speeds: [Double] = []
    /// Distances to each point candidate on earlier fixes since it entered the band (first kept, tail bounded).
    private var histories: [String: [Double]] = [:]
    /// Fired points not yet passed: the minimum seen and the run of increases after it.
    private var passing: [String: PassWatch] = [:]
    private var lastSpokenAt: Date?
    private var lastPassed: (radar: Radar, at: Date)?
    private var current: DriveSnapshot

    /// Why the last stretch was left, for the log row the location lane writes.
    public private(set) var lastStretchExitReason: StretchExitReason?

    private struct PassWatch {
        var minDistance: Double
        var lastDistance: Double
        var increases = 0
        var opposite: Bool
    }

    public init(store: RadarStore, ledger: PassLedger, now: @escaping @Sendable () -> Date = Date.init, locale: Locale = .autoupdatingCurrent) {
        self.store = store
        self.now = now
        self.locale = locale
        passes = PassTracker(ledger: ledger)
        // The stretch the previous process was inside, while its pass is still open (design 2.5, relaunch).
        let resumed = ledger.stretch.flatMap { state in ledger.entry(for: state.radar.id)?.passedAt == nil ? state : nil }
        stretches = StretchTracker(resuming: resumed)
        current = .empty(at: now(), locale: locale)
        if let state = stretches.inside {
            // The card is the stretch's from the start, not "Sin radares cerca" until the first fix after the relaunch.
            current.stretch = state
            current.next = state.radar
            current.distanceMetres = state.remainingMetres
            current.content = stretchContent(median: nil, at: now())
        }
    }

    /// The pass ledger plus the stretch the car is inside: what the owner persists.
    public var ledger: PassLedger {
        var l = passes.ledger
        l.stretch = stretches.inside
        return l
    }

    public var snapshot: DriveSnapshot {
        var s = current
        if s.content.phase == .passed, let passed = lastPassed, now().timeIntervalSince(passed.at) >= Thresholds.passedCardSeconds {
            s.content = stretches.inside != nil ? stretchContent(median: s.speedMps, at: now()) : .watching(at: now(), locale: locale)
        }
        return s
    }

    // MARK: Ingest

    public func ingest(_ fix: Fix) -> [AlertEvent] {
        let t = fix.timestamp
        var events: [AlertEvent] = []

        recentFixes.removeAll { t.timeIntervalSince($0.timestamp) > Thresholds.courseFallbackWindowSeconds }
        let course = courseInUse(fix)
        recentFixes.append(fix)
        previousFix = fix

        if let s = fix.speed, s >= 0 {
            speeds.append(s)
            if speeds.count > Thresholds.speedMedianFixes { speeds.removeFirst(speeds.count - Thresholds.speedMedianFixes) }
        }
        let median = WarnPolicy.medianSpeed(speeds)
        let warn = WarnPolicy.warnDistance(speed: median ?? 0)

        let candidates = store.candidates(near: fix.coordinate, within: warn + Thresholds.candidateBandM, on: t)

        // The 2 km half of the cooldown: how far the car has been from every fired radar.
        for entry in passes.ledger.entries where entry.farthestMetres < Thresholds.cooldownM {
            if let radar = store.radar(id: entry.id) {
                passes.observe(entry.id, distance: RadarStore.gateDistance(from: fix.coordinate, to: radar))
            }
        }

        // Stretches first: an entry is one event, an exit another, never both on one fix.
        let lines = candidates.filter { $0.isLine && passes.canFire($0.id, now: t) }
        if let change = stretches.ingest(fix, courseDegrees: course, warnDistance: warn, speedMps: median, candidates: lines, now: t) {
            switch change {
            case .entered(let radar, _, let approach, let level, let remaining):
                if level == .full {
                    // A stretch entry is spoken whatever the pacing clock says: it is the one sentence of a corridor
                    // that can run for 30 km, and the synthesizer queues it behind a point's sentence (design 2.6).
                    passes.fire(radar.id, level: .full, now: t)
                    lastSpokenAt = t
                    let content = stretchContent(median: median, at: t)
                    let draft = AlertEvent(kind: .stretchEntered, radar: radar, distance: approach.distanceMetres, late: approach.late, crossTrackMetres: approach.crossTrackMetres, phrase: nil, content: content)
                    let phrase = remaining.map { Phrasing.makeJoined(draft, remainingMetres: $0, locale: locale) } ?? Phrasing.make(draft, locale: locale)
                    events.append(withPhrase(draft, phrase: phrase))
                } else {
                    passes.fire(radar.id, level: .visual, now: t)
                    passing[radar.id] = PassWatch(minDistance: approach.distanceMetres, lastDistance: approach.distanceMetres, opposite: true)
                    let content = radarContent(radar, phase: .alert, distance: approach.distanceMetres, median: median, opposite: true, at: t)
                    events.append(AlertEvent(kind: .warn(.visual), radar: radar, distance: approach.distanceMetres, late: approach.late, crossTrackMetres: approach.crossTrackMetres, phrase: nil, content: content))
                }
            case .exited(let radar, let reason):
                passes.markPassed(radar.id, now: t)
                lastStretchExitReason = reason
                let draft = AlertEvent(kind: .stretchExited(reason), radar: radar, distance: nil, late: false, crossTrackMetres: nil, phrase: nil, content: .watching(at: t, locale: locale))
                events.append(withPhrase(draft, phrase: reason == .farGate ? Phrasing.make(draft, locale: locale) : nil))
            }
        }

        // Points (design 2.3): record the distance history, evaluate, arm or fire.
        var fires: [(Radar, Approach)] = []
        var seen = Set<String>()
        for radar in candidates where !radar.isLine {
            seen.insert(radar.id)
            let previous = histories[radar.id] ?? []
            let distance = Geo.distance(fix.coordinate, radar.start)
            var h = previous
            h.append(distance)
            if h.count > 8 { h.remove(at: 1) }
            histories[radar.id] = h

            guard let course, passes.canFire(radar.id, now: t) else { continue }
            let approach = ApproachEvaluator.evaluate(gate: radar.start, bearing: radar.bearing, bidirectional: radar.bidirectional, fix: fix, courseDegrees: course, previousDistances: previous, warnDistance: warn)
            if approach.level != nil {
                fires.append((radar, approach))
            } else if approach.ahead {
                passes.arm(radar.id)
            } else {
                passes.disarm(radar.id)
            }
        }
        histories = histories.filter { seen.contains($0.key) }

        // Pacing and the combined sentence (design 2.6): one voice per fix and per 8 s; the rest are shown.
        fires.sort { $0.1.distanceMetres < $1.1.distanceMetres }
        var spoken: (Radar, Approach)? = nil
        var second: Double? = nil
        var fired: [(Radar, Approach, Level)] = []
        for (radar, approach) in fires {
            var level = approach.level ?? .visual
            if level == .full {
                if approach.distanceMetres < Thresholds.noVoiceBelowM {
                    level = .visual
                } else if let last = lastSpokenAt, t.timeIntervalSince(last) < Thresholds.pacingSeconds {
                    level = .visual
                } else if spoken != nil {
                    level = .visual
                    if second == nil { second = approach.distanceMetres }
                } else {
                    spoken = (radar, approach)
                }
            }
            passes.fire(radar.id, level: level, now: t)
            passing[radar.id] = PassWatch(minDistance: approach.distanceMetres, lastDistance: approach.distanceMetres, opposite: !approach.directionMatch)
            fired.append((radar, approach, level))
        }
        if spoken != nil { lastSpokenAt = t }
        for (radar, approach, level) in fired {
            let opposite = !approach.directionMatch
            let content = radarContent(radar, phase: .alert, distance: approach.distanceMetres, median: median, opposite: opposite, at: t)
            let draft = AlertEvent(kind: .warn(level), radar: radar, distance: approach.distanceMetres, late: approach.late, crossTrackMetres: approach.crossTrackMetres, phrase: nil, content: content)
            let isSpoken = level == .full && spoken?.0.id == radar.id
            events.append(withPhrase(draft, phrase: isSpoken ? Phrasing.make(draft, locale: locale, alsoAt: second) : nil))
        }

        // Passed (design 2.3): three increases of at least closingMinM after the minimum, the distance at least
        // max(passedMinRiseM, accuracy) above it, or under 30 m. GPS wander while stopped before the radar is no pass.
        for id in passes.firedIds {
            guard let radar = store.radar(id: id), !radar.isLine else { continue }
            let distance = Geo.distance(fix.coordinate, radar.start)
            guard var watch = passing[id] else {
                passing[id] = PassWatch(minDistance: distance, lastDistance: distance, opposite: false)
                continue
            }
            if fired.contains(where: { $0.0.id == id }) { continue }
            var passed = distance < Thresholds.passedBelowM
            if !passed {
                if distance < watch.minDistance {
                    watch.minDistance = distance
                    watch.increases = 0
                } else if distance - watch.lastDistance >= Thresholds.closingMinM {
                    watch.increases += 1
                    let rise = distance - watch.minDistance
                    passed = watch.increases >= Thresholds.passedFixes && rise >= max(Thresholds.passedMinRiseM, fix.horizontalAccuracy)
                } else {
                    watch.increases = 0
                }
            }
            watch.lastDistance = distance
            passing[id] = watch
            if passed {
                passes.markPassed(id, now: t)
                passing.removeValue(forKey: id)
                lastPassed = (radar, t)
                let content = radarContent(radar, phase: .passed, distance: distance, median: median, opposite: false, at: t)
                events.append(AlertEvent(kind: .passed, radar: radar, distance: distance, late: false, crossTrackMetres: nil, phrase: nil, content: content))
            }
        }
        let firedNow = Set(passes.firedIds)
        passing = passing.filter { firedNow.contains($0.key) }

        current = buildSnapshot(fix: fix, course: course, median: median, candidates: candidates, at: t)
        return events
    }

    public func endDrive() -> [AlertEvent] {
        let t = now()
        var events: [AlertEvent] = []
        if case .exited(let radar, let reason)? = stretches.endDrive() {
            passes.markPassed(radar.id, now: t)
            lastStretchExitReason = reason
            events.append(AlertEvent(kind: .stretchExited(reason), radar: radar, distance: nil, late: false, crossTrackMetres: nil, phrase: nil, content: .watching(at: t, locale: locale)))
        }
        passes.prune(now: t)
        histories = [:]
        passing = [:]
        speeds = []
        previousFix = nil
        recentFixes = []
        lastSpokenAt = nil
        lastPassed = nil
        current = .empty(at: t, locale: locale)
        events.append(AlertEvent(kind: .driveEnded, radar: nil, distance: nil, late: false, crossTrackMetres: nil, phrase: nil, content: .watching(at: t, locale: locale)))
        return events
    }

    // MARK: Course (design 2.3)

    /// The platform course at road speed; the platform course when the platform marked the speed invalid but the car
    /// moved at road speed since the previous fix; else the heading from the most recent fix of the last
    /// courseFallbackWindowSeconds at least courseFallbackMinM behind; else nothing (nothing fires, the card shows
    /// the nearest radar as "cerca").
    private func courseInUse(_ fix: Fix) -> Double? {
        if let c = fix.course, (fix.speed ?? 0) >= Thresholds.courseMinSpeedMps {
            return c
        }
        if let c = fix.course, fix.speed == nil, let prev = previousFix {
            let seconds = max(1, fix.timestamp.timeIntervalSince(prev.timestamp))
            if Geo.distance(prev.coordinate, fix.coordinate) >= Thresholds.courseMinSpeedMps * seconds {
                return c
            }
        }
        if let baseline = recentFixes.last(where: { Geo.distance($0.coordinate, fix.coordinate) >= Thresholds.courseFallbackMinM }) {
            return Geo.bearing(from: baseline.coordinate, to: fix.coordinate)
        }
        return nil
    }

    // MARK: Content

    private func withPhrase(_ e: AlertEvent, phrase: Phrase?) -> AlertEvent {
        AlertEvent(kind: e.kind, radar: e.radar, distance: e.distance, late: e.late, crossTrackMetres: e.crossTrackMetres, phrase: phrase, content: e.content)
    }

    static func symbol(for radar: Radar) -> String {
        switch radar.kind {
        case .fixed: "camera.fill"
        case .section: "ruler.fill"
        case .stretch: radar.role == .mobileCorridor ? "road.lanes" : "timer"
        case .mobileAnnounced: "camera.badge.clock.fill"
        case .mobileRecurring: "camera.badge.clock"
        case .trailer: "truck.box.fill"
        case .reported: "questionmark.circle"
        }
    }

    private func radarContent(_ radar: Radar, phase: DrivePhase, distance: Double?, median: Double?, opposite: Bool, at date: Date) -> DriveContent {
        let en = Phrasing.isEnglish(locale)
        var title = Phrasing.kindTitle(radar, locale: locale)
        if phase == .passed { title = en ? "Radar passed" : "Radar superado" }
        return DriveContent(
            phase: phase,
            kindSymbol: Self.symbol(for: radar),
            title: title,
            subtitle: Phrasing.subtitle(radar, locale: locale),
            distanceMetres: distance.map { Int($0.rounded()) },
            limit: radar.maxspeed,
            speedKmh: median.map { Int(($0 * 3.6).rounded()) },
            opposite: opposite,
            updatedAt: date
        )
    }

    /// The card inside a stretch: the remaining figure (the surfaces label it "aprox.") and, in a section, the average.
    private func stretchContent(median: Double?, at date: Date) -> DriveContent {
        guard let state = stretches.inside else { return .watching(at: date, locale: locale) }
        var c = radarContent(state.radar, phase: .insideStretch, distance: nil, median: median, opposite: false, at: date)
        c.stretchRemainingMetres = state.remainingMetres.map { Int($0.rounded()) }
        c.avgKmh = state.avgKmh.map { Int($0.rounded()) }
        return c
    }

    /// The card, in this order: a full-fired point not yet passed (inside a stretch too, so the milestones and
    /// "Radar superado" of a point in a corridor reach the driver), the 4 s passed card, an armed point ahead, the
    /// stretch the car is inside, the nearest candidate as "cerca", nothing.
    private func buildSnapshot(fix: Fix, course: Double?, median: Double?, candidates: [Radar], at t: Date) -> DriveSnapshot {
        var s = DriveSnapshot(content: .watching(at: t, locale: locale))
        s.speedMps = median
        s.courseDegrees = course
        s.lastFix = fix
        s.stretch = stretches.inside

        let visualIds = Set(passes.ledger.entries.filter { $0.passedAt == nil && $0.level == .visual }.map(\.id))
        s.visualRows = visualIds.compactMap { id in
            guard let radar = store.radar(id: id) else { return nil }
            return DriveSnapshot.VisualRow(radar: radar, distanceMetres: RadarStore.gateDistance(from: fix.coordinate, to: radar), opposite: passing[id]?.opposite ?? false)
        }.sorted { $0.distanceMetres < $1.distanceMetres }

        // Points only: a line's entry stays "fired" until its exit, and the stretch card below shows it.
        let fullFired = passes.ledger.entries.filter { $0.passedAt == nil && $0.level == .full }.compactMap { store.radar(id: $0.id) }.filter { !$0.isLine }
        if let radar = fullFired.min(by: { Geo.distance(fix.coordinate, $0.start) < Geo.distance(fix.coordinate, $1.start) }) {
            let d = Geo.distance(fix.coordinate, radar.start)
            s.next = radar
            s.distanceMetres = d
            s.content = radarContent(radar, phase: .alert, distance: d, median: median, opposite: false, at: t)
            return s
        }
        if let passed = lastPassed, t.timeIntervalSince(passed.at) < Thresholds.passedCardSeconds {
            s.next = passed.radar
            s.content = radarContent(passed.radar, phase: .passed, distance: nil, median: median, opposite: false, at: t)
            return s
        }
        let armed = candidates.filter { !$0.isLine && passes.state(of: $0.id, now: t) == .armed }
        // The card keeps the radar it already shows while that one stays armed: with several radars ahead at once
        // (a city), the nearest one flips every few fixes and every flip would be a Live Activity update.
        if let radar = armed.first(where: { $0.id == current.next?.id }) ?? armed.first {
            let d = Geo.distance(fix.coordinate, radar.start)
            s.next = radar
            s.distanceMetres = d
            s.content = radarContent(radar, phase: .approaching, distance: d, median: median, opposite: false, at: t)
            return s
        }
        if let state = stretches.inside {
            s.next = state.radar
            s.distanceMetres = state.remainingMetres
            s.content = stretchContent(median: median, at: t)
            return s
        }
        if let radar = candidates.first {
            let d = RadarStore.gateDistance(from: fix.coordinate, to: radar)
            s.next = radar
            s.distanceMetres = d
            var c = radarContent(radar, phase: .watching, distance: d, median: median, opposite: false, at: t)
            c.subtitle = Phrasing.isEnglish(locale) ? "nearby" : "cerca"
            s.content = c
            return s
        }
        var c = DriveContent.watching(at: t, locale: locale)
        c.speedKmh = median.map { Int(($0 * 3.6).rounded()) }
        s.content = c
        return s
    }
}
