// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// ingest(_:) -> [AlertEvent]: candidates, course, warn distance, approach, pass state, stretches, pacing (design 2).
// Pure given the store: no I/O. The fix timestamps are the clock while driving (so a route vector replays
// hours in milliseconds); `now` is only read where no fix is involved (endDrive, the passed card's 4 s).
// Owned by the location lane's drive loop, which persists `ledger` on warn, passed and drive end.

import Foundation

public final class AlertEngine {
    private let store: RadarStore
    private let now: @Sendable () -> Date
    private let locale: Locale

    private var passes: PassTracker
    private var stretches = StretchTracker()
    private var previousFix: Fix?
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
        current = .empty(at: now())
    }

    public var ledger: PassLedger { passes.ledger }

    public var snapshot: DriveSnapshot {
        var s = current
        if s.content.phase == .passed, let passed = lastPassed, now().timeIntervalSince(passed.at) >= Thresholds.passedCardSeconds {
            s.content = .watching(at: now())
        }
        return s
    }

    // MARK: Ingest

    public func ingest(_ fix: Fix) -> [AlertEvent] {
        let t = fix.timestamp
        var events: [AlertEvent] = []

        // Course (design 2.3): the platform course at road speed, else the heading between the last two fixes.
        var course: Double?
        if let c = fix.course, (fix.speed ?? 0) >= Thresholds.courseMinSpeedMps {
            course = c
        } else if let prev = previousFix, Geo.distance(prev.coordinate, fix.coordinate) >= Thresholds.courseFallbackMinM {
            course = Geo.bearing(from: prev.coordinate, to: fix.coordinate)
        }
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
            case .entered(let radar, _, let approach, let level):
                if level == .full {
                    passes.fire(radar.id, level: .full, now: t)
                    let paced = lastSpokenAt.map { t.timeIntervalSince($0) < Thresholds.pacingSeconds } ?? false
                    if !paced { lastSpokenAt = t }
                    let content = stretchContent(fix: fix, median: median)
                    let draft = AlertEvent(kind: .stretchEntered, radar: radar, distance: approach.distanceMetres, late: approach.late, crossTrackMetres: approach.crossTrackMetres, phrase: nil, content: content)
                    events.append(withPhrase(draft, phrase: paced ? nil : Phrasing.make(draft, locale: locale)))
                } else {
                    passes.fire(radar.id, level: .visual, now: t)
                    passing[radar.id] = PassWatch(minDistance: approach.distanceMetres, lastDistance: approach.distanceMetres, opposite: true)
                    let content = radarContent(radar, phase: .alert, distance: approach.distanceMetres, median: median, opposite: true, at: t)
                    events.append(AlertEvent(kind: .warn(.visual), radar: radar, distance: approach.distanceMetres, late: approach.late, crossTrackMetres: approach.crossTrackMetres, phrase: nil, content: content))
                }
            case .exited(let radar, let reason):
                passes.markPassed(radar.id, now: t)
                lastStretchExitReason = reason
                let draft = AlertEvent(kind: .stretchExited, radar: radar, distance: nil, late: false, crossTrackMetres: nil, phrase: nil, content: .watching(at: t))
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

        // Passed (design 2.3): three increases after the minimum, or under 30 m.
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
                } else if distance > watch.lastDistance {
                    watch.increases += 1
                    passed = watch.increases >= Thresholds.passedFixes
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
            events.append(AlertEvent(kind: .stretchExited, radar: radar, distance: nil, late: false, crossTrackMetres: nil, phrase: nil, content: .watching(at: t)))
        }
        passes.prune(now: t)
        histories = [:]
        passing = [:]
        speeds = []
        previousFix = nil
        lastSpokenAt = nil
        lastPassed = nil
        current = .empty(at: t)
        events.append(AlertEvent(kind: .driveEnded, radar: nil, distance: nil, late: false, crossTrackMetres: nil, phrase: nil, content: .watching(at: t)))
        return events
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

    private func stretchContent(fix: Fix, median: Double?) -> DriveContent {
        guard let state = stretches.inside else { return .watching(at: fix.timestamp) }
        var c = radarContent(state.radar, phase: .insideStretch, distance: nil, median: median, opposite: false, at: fix.timestamp)
        c.stretchRemainingMetres = state.remainingMetres.map { Int($0.rounded()) }
        c.avgKmh = state.avgKmh.map { Int($0.rounded()) }
        c.note = "aprox."
        return c
    }

    private func buildSnapshot(fix: Fix, course: Double?, median: Double?, candidates: [Radar], at t: Date) -> DriveSnapshot {
        var s = DriveSnapshot(content: .watching(at: t))
        s.speedMps = median
        s.courseDegrees = course
        s.lastFix = fix
        s.stretch = stretches.inside

        let visualIds = Set(passes.ledger.entries.filter { $0.passedAt == nil && $0.level == .visual }.map(\.id))
        s.visualRows = visualIds.compactMap { id in
            guard let radar = store.radar(id: id) else { return nil }
            return DriveSnapshot.VisualRow(radar: radar, distanceMetres: RadarStore.gateDistance(from: fix.coordinate, to: radar), opposite: passing[id]?.opposite ?? false)
        }.sorted { $0.distanceMetres < $1.distanceMetres }

        if stretches.inside != nil {
            s.next = stretches.inside?.radar
            s.distanceMetres = stretches.inside?.remainingMetres
            s.content = stretchContent(fix: fix, median: median)
            return s
        }
        let fullFired = passes.ledger.entries.filter { $0.passedAt == nil && $0.level == .full }.compactMap { store.radar(id: $0.id) }
        if let radar = fullFired.min(by: { RadarStore.gateDistance(from: fix.coordinate, to: $0) < RadarStore.gateDistance(from: fix.coordinate, to: $1) }) {
            let d = RadarStore.gateDistance(from: fix.coordinate, to: radar)
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
        if let radar = armed.first {
            let d = Geo.distance(fix.coordinate, radar.start)
            s.next = radar
            s.distanceMetres = d
            s.content = radarContent(radar, phase: .approaching, distance: d, median: median, opposite: false, at: t)
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
        var c = DriveContent.watching(at: t)
        c.speedKmh = median.map { Int(($0 * 3.6).rounded()) }
        s.content = c
        return s
    }
}
