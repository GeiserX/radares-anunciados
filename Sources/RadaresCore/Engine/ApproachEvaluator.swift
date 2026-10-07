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
    public static func evaluate(
        gate: Coordinate,
        bearing: Double?,
        bidirectional: Bool,
        fix: Fix,
        courseDegrees: Double,
        previousDistances: [Double],
        warnDistance: Double
    ) -> Approach {
        fatalError("lane: core")
    }
}
