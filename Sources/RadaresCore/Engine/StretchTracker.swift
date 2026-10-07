// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Two gates plus an inside state per stretch: entry, remaining, average speed, the four exits (design 2.5).
// The chord is only used for the remaining estimate; the gates are exact.

import Foundation

public struct StretchTracker: Sendable {
    public enum Change: Sendable, Hashable {
        /// The point rule held at the near gate and the course points into the stretch. `.visual` means an OSM
        /// bearing on an average-speed section disagreed with the course: shown, not spoken, and not entered.
        case entered(radar: Radar, gate: Coordinate, approach: Approach, level: Level)
        case exited(radar: Radar, reason: StretchExitReason)
    }

    public private(set) var inside: DriveSnapshot.StretchState?

    /// Distances to the nearer gate of each candidate line on earlier fixes, oldest first (first kept, tail bounded).
    private var histories: [String: [Double]] = [:]
    private var farGate: Coordinate?
    private var straightChord: Double = 0
    private var entrySpeedMps: Double?
    private var pathMetres: Double = 0
    private var lastCoordinate: Coordinate?

    public init() {}

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

        if var state = inside, let far = farGate {
            if let last = lastCoordinate { pathMetres += Geo.distance(last, fix.coordinate) }
            lastCoordinate = fix.coordinate
            let along = Geo.projection(point: fix.coordinate, from: state.entryGate, to: far)
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
                straightChord = Geo.distance(near, far)
                farGate = far
                entrySpeedMps = speedMps
                pathMetres = 0
                lastCoordinate = fix.coordinate
                inside = DriveSnapshot.StretchState(radar: radar, enteredAt: now, entryGate: near, remainingMetres: straightChord, avgKmh: nil)
            }
            return .entered(radar: radar, gate: near, approach: approach, level: level)
        }
        return nil
    }

    /// Drive end: the inside state is dropped silently.
    public mutating func endDrive() -> Change? {
        guard let state = inside else { return nil }
        leave()
        return .exited(radar: state.radar, reason: .driveEnd)
    }

    private mutating func leave() {
        inside = nil
        farGate = nil
        entrySpeedMps = nil
        pathMetres = 0
        lastCoordinate = nil
    }
}
