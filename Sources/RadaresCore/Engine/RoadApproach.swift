// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The road rule of design 2.3: a fix is matched to a road polyline only by a segment that passes BOTH tests, lateral
// distance and course, and the smallest lateral among those wins; the course is never tested after a lateral pick,
// because on a switchback two legs sit within 25 m with opposite bearings. While matched, the along-road position may
// not jump further than Thresholds.roadAlongJumpFactor x speed x seconds + Thresholds.roadAlongJumpFloorM. A matched
// fix gives the four tests of ApproachEvaluator measured along the road: distance = length - along.

import Foundation

/// What the last matched fix left for the next one: which polyline, where along it, when, and the along-road
/// distances seen so far (the first kept for `late`, the tail for `closing`).
public struct RoadHistory: Sendable, Hashable {
    public var polylineIndex: Int
    public var along: Double
    public var at: Date
    public var distances: [Double]

    public init(polylineIndex: Int, along: Double, at: Date, distances: [Double]) {
        self.polylineIndex = polylineIndex
        self.along = along
        self.at = at
        self.distances = distances
    }
}

/// One fix matched to a polyline.
public struct PolylineMatch: Sendable, Hashable {
    public var polylineIndex: Int
    public var projection: Polyline.Projection
    /// The course runs with the polyline's vertex order (false: against it, only when the caller allowed it).
    public var forward: Bool
}

/// A fix matched to a radar's approach: the approach measured along the road, and the history to keep.
public struct RoadMatch: Sendable, Hashable {
    public var polylineIndex: Int
    public var lateralMetres: Double
    public var alongMetres: Double
    public var lengthMetres: Double
    public var approach: Approach
    public var history: RoadHistory

    /// Metres left along the road to the radar (negative past it).
    public var distanceMetres: Double { lengthMetres - alongMetres }
}

public enum RoadApproach {
    /// Lateral limit for a fix: Thresholds.roadMatchLateralM, or more with a poor fix.
    public static func lateralLimit(accuracy: Double) -> Double {
        max(Thresholds.roadMatchLateralM, Thresholds.roadMatchAccuracyFactor * accuracy)
    }

    /// The candidate rule. Every segment of every polyline is projected; a segment is a candidate when it is within
    /// the lateral limit AND its travel direction is within Thresholds.roadMatchCourseDeg of the course (with the
    /// vertex order, against it when `backward`, either when both are allowed). With no course only the lateral test
    /// applies (inside a stretch at walking pace). A candidate on the previous fix's polyline whose along-road position
    /// jumped further than the guard allows is dropped. The smallest lateral among the rest wins.
    public static func match(
        _ polylines: [Polyline],
        at point: Coordinate,
        course: Double?,
        accuracy: Double,
        forward: Bool = true,
        backward: Bool = false,
        previous: (index: Int, along: Double, at: Date)? = nil,
        now: Date? = nil,
        speedMps: Double? = nil
    ) -> PolylineMatch? {
        let limit = lateralLimit(accuracy: accuracy)
        var maxJump: Double?
        if let previous, let now {
            let dt = max(0, now.timeIntervalSince(previous.at))
            maxJump = Thresholds.roadAlongJumpFactor * max(0, speedMps ?? 0) * dt + Thresholds.roadAlongJumpFloorM
        }
        var best: PolylineMatch?
        for (i, line) in polylines.enumerated() {
            for p in line.projections(of: point) where p.lateralMetres <= limit {
                var isForward = true
                if let course {
                    let along = Geo.angleDiff(course, p.segmentBearing) <= Thresholds.roadMatchCourseDeg
                    let against = Geo.angleDiff(course, Geo.normalize(p.segmentBearing + 180)) <= Thresholds.roadMatchCourseDeg
                    if forward, along {
                        isForward = true
                    } else if backward, against {
                        isForward = false
                    } else {
                        continue
                    }
                } else {
                    isForward = forward
                }
                if let previous, let maxJump, previous.index == i, abs(p.alongMetres - previous.along) > maxJump { continue }
                if best == nil || p.lateralMetres < best!.projection.lateralMetres {
                    best = PolylineMatch(polylineIndex: i, projection: p, forward: isForward)
                }
            }
        }
        return best
    }

    /// Metres from `point` to the nearest of `polylines`, whatever the course (the off-road test).
    public static func minLateral(_ polylines: [Polyline], at point: Coordinate) -> Double {
        polylines.map { $0.project(point).lateralMetres }.min() ?? .infinity
    }

    /// The approach to a radar (or a stretch gate) along the road, or nil when the fix matches none of `approaches`.
    /// Every approach runs in the direction of travel and ends at the radar, so a match is always the monitored flow.
    public static func evaluate(
        approaches: [Polyline],
        fix: Fix,
        courseDegrees: Double,
        speedMps: Double?,
        previous: RoadHistory?,
        warnDistance: Double
    ) -> RoadMatch? {
        let prev = previous.map { (index: $0.polylineIndex, along: $0.along, at: $0.at) }
        guard let m = match(approaches, at: fix.coordinate, course: courseDegrees, accuracy: fix.horizontalAccuracy, previous: prev, now: fix.timestamp, speedMps: speedMps ?? fix.speed) else {
            return nil
        }
        let length = approaches[m.polylineIndex].length
        let along = m.projection.alongMetres
        let distance = length - along
        // A switch to the other polyline (the other side of a two-way road) restarts the history.
        let earlier = previous?.polylineIndex == m.polylineIndex ? previous!.distances : []

        var closing = false
        let n = earlier.count
        if n >= Thresholds.closingFixes {
            closing = true
            var later = distance
            for i in stride(from: n - 1, through: n - Thresholds.closingFixes, by: -1) {
                if earlier[i] - later < Thresholds.closingMinM { closing = false; break }
                later = earlier[i]
            }
        }
        let firstSeen = earlier.first ?? distance
        let approach = Approach(
            ahead: along < length,
            closing: closing,
            inRange: distance <= warnDistance,
            directionMatch: true,
            late: firstSeen < warnDistance - Thresholds.lateBandM,
            distanceMetres: distance,
            crossTrackMetres: m.projection.lateralMetres
        )
        var kept = earlier
        kept.append(distance)
        if kept.count > 8 { kept.remove(at: 1) }
        let history = RoadHistory(polylineIndex: m.polylineIndex, along: along, at: fix.timestamp, distances: kept)
        return RoadMatch(polylineIndex: m.polylineIndex, lateralMetres: m.projection.lateralMetres, alongMetres: along, lengthMetres: length, approach: approach, history: history)
    }
}
