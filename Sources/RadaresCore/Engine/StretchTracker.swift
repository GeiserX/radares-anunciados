// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Two gates plus an inside state per stretch: entry at a gate or between the gates, remaining, average speed, the
// four exits (design 2.5). The chord is used for the remaining estimate and for the mid-stretch join; the gates are
// exact. The inside state can be restored from the persisted ledger, so a relaunch mid-stretch still says
// "Fin de tramo" at the far gate.
// With a road line from roads.json (design 2.5): entry along a gate approach, a join anywhere along the real road,
// and the remaining distance along it. A car that loses the line for Thresholds.stretchPolylineLossFixes fixes is
// tracked on the chord again, with the same exits: road geometry never ends a corridor by itself.

import Foundation

public struct StretchTracker: Sendable {
    public enum Change: Sendable, Hashable {
        /// The point rule held at the near gate and the course points into the stretch, or the car joined the stretch
        /// between its gates (`remainingMetres` set). `.visual` means an OSM bearing on an average-speed section
        /// disagreed with the course: shown, not spoken, and not entered.
        case entered(radar: Radar, gate: Coordinate, approach: Approach, level: Level, remainingMetres: Double?)
        case exited(radar: Radar, reason: StretchExitReason)
    }

    public private(set) var inside: DriveSnapshot.StretchState?

    /// Distances to the nearer gate of each candidate line on earlier fixes, oldest first (first kept, tail bounded).
    private var histories: [String: [Double]] = [:]
    /// Consecutive fixes on which each candidate line qualified for a mid-stretch join.
    private var midJoinRuns: [String: Int] = [:]
    private var farGate: Coordinate?
    private var straightChord: Double = 0
    private var entrySpeedMps: Double?
    private var pathMetres: Double = 0
    private var lastCoordinate: Coordinate?
    /// Restored from the ledger: the path before the relaunch is unknown until the first fix estimates it from the chord.
    private var pathUnknown = false
    /// The sidecar of the current fix.
    private var roads: RoadGeometry?
    /// Per candidate line and gate side ("id#start", "id#end"): the last fix matched to a gate approach.
    private var gateHistories: [String: RoadHistory] = [:]
    /// Inside a stretch with a road line: the line, looked up once per stretch (also after a relaunch).
    private var line: Polyline?
    private var lineLookedUp = false
    /// Consecutive accurate fixes that failed the line; at Thresholds.stretchPolylineLossFixes the chord takes over.
    private var lineMisses = 0
    private var lineLost = false
    /// The last fix matched to the line: where along it, and when (the along-jump guard).
    private var lastOnLine: (along: Double, at: Date)?
    /// The line was matched at least once since entry: before that (the car still short of the gate) the chord
    /// estimate stands, as without a line.
    private var lineMatchedOnce = false

    public init() {}

    /// Resume the stretch the car was inside when the process died (the ledger's `stretch`). The far gate is the
    /// one the car did not enter through; the path driven so far is estimated on the first fix as the straight
    /// distance from the entry position (exact on a straight road, a lower bound on a bend).
    public init(resuming state: DriveSnapshot.StretchState?) {
        guard let state, let end = state.radar.end else { return }
        inside = state
        farGate = state.entryGate == end ? state.radar.start : end
        straightChord = Geo.distance(state.entryGate, farGate!)
        entrySpeedMps = state.entrySpeedMps
        pathUnknown = true
    }

    /// One fix. `candidates` are the lines the engine allows to enter (alertable, not fired or cooling down).
    public mutating func ingest(
        _ fix: Fix,
        courseDegrees: Double?,
        warnDistance: Double,
        speedMps: Double?,
        candidates: [Radar],
        roads: RoadGeometry? = nil,
        now: Date
    ) -> Change? {
        self.roads = roads
        // Keep the gate distances for every candidate line, inside or not, so a stretch that shares a gate with
        // the one being left can be entered on the next fixes.
        var seen = Set<String>()
        var previous: [String: [Double]] = [:]
        for radar in candidates where radar.isLine {
            seen.insert(radar.id)
            let d = RadarStore.gateDistance(from: fix.coordinate, to: radar)
            previous[radar.id] = histories[radar.id] ?? []
            var h = histories[radar.id] ?? []
            h.append(d)
            if h.count > 8 { h.remove(at: 1) }
            histories[radar.id] = h
        }
        histories = histories.filter { seen.contains($0.key) }
        midJoinRuns = midJoinRuns.filter { seen.contains($0.key) }

        if var state = inside, let far = farGate {
            let along = Geo.projection(point: fix.coordinate, from: state.entryGate, to: far)
            if !lineLookedUp {
                line = roads?.line(for: state.radar.id)
                lineLookedUp = true
            }
            // Along the road line when the fix matches it, in the direction from the entry gate to the far one.
            let forward = state.entryGate == state.radar.start
            var fromEntryOnLine: Double?
            if let line, let m = RoadApproach.match(
                [line], at: fix.coordinate, course: courseDegrees, accuracy: fix.horizontalAccuracy,
                forward: forward, backward: !forward,
                previous: lastOnLine.map { (index: 0, along: $0.along, at: $0.at) }, now: now, speedMps: speedMps ?? fix.speed
            ) {
                let a = m.projection.alongMetres
                fromEntryOnLine = forward ? a : line.length - a
                lastOnLine = (a, now)
                lineMisses = 0
                lineLost = false
                lineMatchedOnce = true
            } else if line != nil {
                lastOnLine = nil
                if fix.horizontalAccuracy <= Thresholds.stretchPolylineLossMaxAccuracyM { lineMisses += 1 }
                if lineMisses >= Thresholds.stretchPolylineLossFixes { lineLost = true }
            }
            if pathUnknown {
                if let fromEntryOnLine, let entry = state.entryCoordinate {
                    pathMetres = Geo.distance(entry, state.entryGate) + fromEntryOnLine
                } else {
                    pathMetres = state.entryCoordinate.map { Geo.distance($0, fix.coordinate) } ?? along
                }
                pathUnknown = false
            } else if let last = lastCoordinate {
                pathMetres += Geo.distance(last, fix.coordinate)
            }
            lastCoordinate = fix.coordinate
            if let line, let fromEntryOnLine {
                state.remainingMetres = max(0, line.length - fromEntryOnLine)
            } else if line == nil || lineLost || !lineMatchedOnce {
                state.remainingMetres = max(0, straightChord - along)
            }
            // Otherwise a few missed fixes keep the last figure until the line is matched again or counted lost.
            let elapsed = now.timeIntervalSince(state.enteredAt)
            if state.radar.role == .averageSpeedSection, elapsed > 0 {
                state.avgKmh = pathMetres / elapsed * 3.6
            }
            inside = state

            let reason: StretchExitReason?
            let length = max(state.radar.roadMetres ?? 0, state.radar.chordMetres ?? 0, straightChord, line?.length ?? 0)
            if Geo.distance(fix.coordinate, far) <= Thresholds.stretchExitGateM {
                reason = .farGate
            } else if Geo.distance(fix.coordinate, state.entryGate) > length + Thresholds.stretchExitSlackM {
                reason = .distance
            } else if let v = entrySpeedMps, v > 0, elapsed > Thresholds.stretchExitTraverseFactor * (length / v) {
                reason = .time
            } else {
                reason = nil
            }
            if let reason {
                let radar = state.radar
                leave()
                return .exited(radar: radar, reason: reason)
            }
            return nil
        }

        guard let course = courseDegrees else {
            // A fix with no course cannot qualify for a join: the runs restart, three fixes means three in a row.
            midJoinRuns = [:]
            gateHistories = [:]
            return nil
        }
        let ordered = candidates.filter(\.isLine).sorted {
            RadarStore.gateDistance(from: fix.coordinate, to: $0) < RadarStore.gateDistance(from: fix.coordinate, to: $1)
        }

        // Gate approaches (design 2.5): every candidate line with gates is measured along the road leading into
        // each end, so the histories stay current for all of them.
        var gateMatches: [String: (gate: Coordinate, far: Coordinate, match: RoadMatch)] = [:]
        var onGateRoad = Set<String>()
        var keptGates = Set<String>()
        if let roads {
            for radar in ordered {
                guard let end = radar.end, let gates = roads.gates(for: radar.id) else { continue }
                for (side, approaches, gate, far) in [("start", gates.start, radar.start, end), ("end", gates.end, end, radar.start)] where !approaches.isEmpty {
                    let key = "\(radar.id)#\(side)"
                    guard let m = RoadApproach.evaluate(approaches: approaches, fix: fix, courseDegrees: course, speedMps: speedMps, previous: gateHistories[key], warnDistance: warnDistance) else { continue }
                    gateHistories[key] = m.history
                    keptGates.insert(key)
                    onGateRoad.insert(radar.id)
                    if m.approach.level != nil, (gateMatches[radar.id].map { m.approach.distanceMetres < $0.match.approach.distanceMetres } ?? true) {
                        gateMatches[radar.id] = (gate, far, m)
                    }
                }
            }
        }
        gateHistories = gateHistories.filter { keptGates.contains($0.key) }

        for radar in ordered {
            guard let end = radar.end else { continue }
            if let g = gateMatches[radar.id] {
                var approach = g.match.approach
                // The direction gate of 2.4 as on the cone path: a section's bearing against the course is shown, not entered.
                if let bearing = radar.bearing, !(radar.bidirectional || radar.role == .mobileCorridor) {
                    approach.directionMatch = ApproachEvaluator.matchesDirection(angleOff: Geo.angleDiff(course, bearing))
                }
                guard let level = approach.level else { continue }
                if level == .full {
                    enter(radar, from: g.gate, to: g.far, speedMps: speedMps, at: fix.coordinate, now: now)
                }
                return .entered(radar: radar, gate: g.gate, approach: approach, level: level, remainingMetres: nil)
            }
            // On a gate's road but not yet in range: the road decides, not the cone.
            if onGateRoad.contains(radar.id) { continue }
            let toStart = Geo.distance(fix.coordinate, radar.start)
            let toEnd = Geo.distance(fix.coordinate, end)
            let near = toStart <= toEnd ? radar.start : end
            let far = toStart <= toEnd ? end : radar.start
            let approach = ApproachEvaluator.evaluate(
                gate: near,
                bearing: radar.bearing,
                bidirectional: radar.bidirectional || radar.role == .mobileCorridor,
                fix: fix,
                courseDegrees: course,
                previousDistances: previous[radar.id] ?? [],
                warnDistance: warnDistance
            )
            guard let level = approach.level else { continue }
            guard Geo.angleDiff(course, Geo.bearing(from: near, to: far)) <= Thresholds.stretchEntryDeg else { continue }
            if level == .full {
                enter(radar, from: near, to: far, speedMps: speedMps, at: fix.coordinate, now: now)
            }
            return .entered(radar: radar, gate: near, approach: approach, level: level, remainingMetres: nil)
        }

        // Mid-stretch join (design 2.5): the car is between the gate margins, near the chord and heading along it,
        // on stretchMidJoinFixes consecutive fixes. The chord is not the road, so a bowed stretch can be missed.
        for radar in ordered {
            guard let end = radar.end else { continue }
            if let line = roads?.line(for: radar.id) {
                if let change = midJoinAlongLine(radar, end: end, line: line, fix: fix, course: course, speedMps: speedMps, now: now) { return change }
                continue
            }
            let chord = Geo.distance(radar.start, end)
            let chordCourse = Geo.bearing(from: radar.start, to: end)
            let along = Geo.alongChord(point: fix.coordinate, from: radar.start, to: end)
            let crossTrack = abs(Geo.crossTrack(point: fix.coordinate, from: radar.start, courseDegrees: chordCourse))
            let forward = Geo.angleDiff(course, chordCourse) <= Thresholds.stretchEntryDeg
            let backward = Geo.angleDiff(course, Geo.normalize(chordCourse + 180)) <= Thresholds.stretchEntryDeg
            let margin = Thresholds.stretchExitGateM
            var qualifies = along > margin && along < chord - margin
                && crossTrack <= Thresholds.stretchMidJoinCrossTrackM
                && (forward || backward)
            // The direction gate of 2.4 as at a gate; a mismatch is no entry here (nothing to show as "opposite").
            if qualifies, let bearing = radar.bearing, !(radar.bidirectional || radar.role == .mobileCorridor) {
                qualifies = Geo.angleDiff(course, bearing) <= Thresholds.bearingToleranceDeg
            }
            guard qualifies else {
                midJoinRuns[radar.id] = 0
                continue
            }
            let run = (midJoinRuns[radar.id] ?? 0) + 1
            midJoinRuns[radar.id] = run
            guard run >= Thresholds.stretchMidJoinFixes else { continue }
            let entryGate = forward ? radar.start : end
            let far = forward ? end : radar.start
            let remaining = forward ? chord - along : along
            enter(radar, from: entryGate, to: far, speedMps: speedMps, at: fix.coordinate, now: now)
            inside?.remainingMetres = remaining
            midJoinRuns = [:]
            let approach = Approach(ahead: true, closing: true, inRange: true, directionMatch: true, late: false, distanceMetres: remaining, crossTrackMetres: crossTrack)
            return .entered(radar: radar, gate: entryGate, approach: approach, level: .full, remainingMetres: remaining)
        }
        return nil
    }

    /// The mid-stretch join along the road line (design 2.5): matched to the line (lateral and course, either way
    /// along it) between the gate margins on stretchMidJoinFixes consecutive fixes. Replaces the chord rule for a line
    /// that has a road line, so a corridor bowing 2 km off its chord is joined where the road is.
    private mutating func midJoinAlongLine(_ radar: Radar, end: Coordinate, line: Polyline, fix: Fix, course: Double, speedMps: Double?, now: Date) -> Change? {
        let margin = Thresholds.stretchExitGateM
        var qualifies = false
        var m: PolylineMatch?
        if let found = RoadApproach.match([line], at: fix.coordinate, course: course, accuracy: fix.horizontalAccuracy, forward: true, backward: true) {
            let a = found.projection.alongMetres
            qualifies = a > margin && a < line.length - margin
            m = found
        }
        // The direction gate of 2.4 as at a gate; a mismatch is no entry here (nothing to show as "opposite").
        if qualifies, let bearing = radar.bearing, !(radar.bidirectional || radar.role == .mobileCorridor) {
            qualifies = Geo.angleDiff(course, bearing) <= Thresholds.bearingToleranceDeg
        }
        guard qualifies, let m else {
            midJoinRuns[radar.id] = 0
            return nil
        }
        let run = (midJoinRuns[radar.id] ?? 0) + 1
        midJoinRuns[radar.id] = run
        guard run >= Thresholds.stretchMidJoinFixes else { return nil }
        let along = m.projection.alongMetres
        let entryGate = m.forward ? radar.start : end
        let far = m.forward ? end : radar.start
        let remaining = m.forward ? line.length - along : along
        enter(radar, from: entryGate, to: far, speedMps: speedMps, at: fix.coordinate, now: now)
        inside?.remainingMetres = remaining
        lastOnLine = (along, now)
        lineMatchedOnce = true
        midJoinRuns = [:]
        let approach = Approach(ahead: true, closing: true, inRange: true, directionMatch: true, late: false, distanceMetres: remaining, crossTrackMetres: m.projection.lateralMetres)
        return .entered(radar: radar, gate: entryGate, approach: approach, level: .full, remainingMetres: remaining)
    }

    /// Drive end: the inside state is dropped silently.
    public mutating func endDrive() -> Change? {
        midJoinRuns = [:]
        guard let state = inside else { return nil }
        leave()
        return .exited(radar: state.radar, reason: .driveEnd)
    }

    private mutating func enter(_ radar: Radar, from near: Coordinate, to far: Coordinate, speedMps: Double?, at coordinate: Coordinate, now: Date) {
        straightChord = Geo.distance(near, far)
        farGate = far
        entrySpeedMps = speedMps
        pathMetres = 0
        pathUnknown = false
        lastCoordinate = coordinate
        line = roads?.line(for: radar.id)
        lineLookedUp = true
        lineMisses = 0
        lineLost = false
        lastOnLine = nil
        lineMatchedOnce = false
        gateHistories = [:]
        inside = DriveSnapshot.StretchState(radar: radar, enteredAt: now, entryGate: near, remainingMetres: line?.length ?? straightChord, avgKmh: nil, entrySpeedMps: speedMps, entryCoordinate: coordinate)
    }

    private mutating func leave() {
        inside = nil
        farGate = nil
        entrySpeedMps = nil
        pathMetres = 0
        pathUnknown = false
        lastCoordinate = nil
        line = nil
        lineLookedUp = false
        lineMisses = 0
        lineLost = false
        lastOnLine = nil
        lineMatchedOnce = false
    }
}
