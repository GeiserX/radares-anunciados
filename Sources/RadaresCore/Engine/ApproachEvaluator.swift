// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The four tests of design 2.3 against one gate: ahead, closing, inRange, directionMatch; plus late and cross-track.

import Foundation

public struct Approach: Sendable, Hashable {
    public var ahead: Bool
    public var closing: Bool
    public var inRange: Bool
    public var directionMatch: Bool
    public var late: Bool
    public var distanceMetres: Double
    public var crossTrackMetres: Double

    /// `.full` when all four hold, `.visual` when only directionMatch fails, nil otherwise.
    public var level: Level? {
        guard ahead, closing, inRange else { return nil }
        return directionMatch ? .full : .visual
    }

    public init(ahead: Bool, closing: Bool, inRange: Bool, directionMatch: Bool, late: Bool, distanceMetres: Double, crossTrackMetres: Double) {
        self.ahead = ahead
        self.closing = closing
        self.inRange = inRange
        self.directionMatch = directionMatch
        self.late = late
        self.distanceMetres = distanceMetres
        self.crossTrackMetres = crossTrackMetres
    }
}

public struct ApproachEvaluator: Sendable {
    /// `previousDistances` are the distances to this gate on earlier fixes, oldest first, since the gate entered the
    /// candidate band: the first one decides `late`, the last two decide `closing`.
    public static func evaluate(
        gate: Coordinate,
        bearing: Double?,
        bidirectional: Bool,
        fix: Fix,
        courseDegrees: Double,
        previousDistances: [Double],
        warnDistance: Double
    ) -> Approach {
        let distance = Geo.distance(fix.coordinate, gate)
        let toGate = Geo.bearing(from: fix.coordinate, to: gate)
        let ahead = Geo.angleDiff(courseDegrees, toGate) <= Thresholds.aheadDeg

        var closing = false
        let n = previousDistances.count
        if n >= Thresholds.closingFixes {
            closing = true
            var later = distance
            for i in stride(from: n - 1, through: n - Thresholds.closingFixes, by: -1) {
                let earlier = previousDistances[i]
                if earlier - later < Thresholds.closingMinM { closing = false; break }
                later = earlier
            }
        }

        let inRange = distance <= warnDistance
        let directionMatch: Bool
        if let bearing, !bidirectional {
            directionMatch = Geo.angleDiff(courseDegrees, bearing) <= Thresholds.bearingToleranceDeg
        } else {
            directionMatch = true
        }
        let firstSeen = previousDistances.first ?? distance
        let late = firstSeen < warnDistance - Thresholds.lateBandM
        let crossTrack = Geo.crossTrack(point: gate, from: fix.coordinate, courseDegrees: courseDegrees)
        return Approach(ahead: ahead, closing: closing, inRange: inRange, directionMatch: directionMatch, late: late, distanceMetres: distance, crossTrackMetres: crossTrack)
    }
}
