// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Two gates plus an inside state per stretch: entry at a gate or between the gates, remaining, average speed, the
// four exits (design 2.5). The chord is used for the remaining estimate and for the mid-stretch join; the gates are
// exact. The inside state can be restored from the persisted ledger, so a relaunch mid-stretch still says
// "Fin de tramo" at the far gate.

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
        now: Date
    ) -> Change? {
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
            if pathUnknown {
                pathMetres = state.entryCoordinate.map { Geo.distance($0, fix.coordinate) } ?? along
                pathUnknown = false
            } else if let last = lastCoordinate {
                pathMetres += Geo.distance(last, fix.coordinate)
            }
            lastCoordinate = fix.coordinate
            state.remainingMetres = max(0, straightChord - along)
            let elapsed = now.timeIntervalSince(state.enteredAt)
            if state.radar.role == .averageSpeedSection, elapsed > 0 {
                state.avgKmh = pathMetres / elapsed * 3.6
            }
            inside = state

            let reason: StretchExitReason?
            let length = max(state.radar.roadMetres ?? 0, state.radar.chordMetres ?? 0, straightChord)
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

        guard let course = courseDegrees else { return nil }
        let ordered = candidates.filter(\.isLine).sorted {
            RadarStore.gateDistance(from: fix.coordinate, to: $0) < RadarStore.gateDistance(from: fix.coordinate, to: $1)
        }
        for radar in ordered {
            guard let end = radar.end else { continue }
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
        inside = DriveSnapshot.StretchState(radar: radar, enteredAt: now, entryGate: near, remainingMetres: straightChord, avgKmh: nil, entrySpeedMps: speedMps, entryCoordinate: coordinate)
    }

    private mutating func leave() {
        inside = nil
        farGate = nil
        entrySpeedMps = nil
        pathMetres = 0
        pathUnknown = false
        lastCoordinate = nil
    }
}
