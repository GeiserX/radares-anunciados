// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Haversine distance, atan2 bearing, angle difference, cross-track distance and projection onto a chord.

import Foundation

public enum Geo {
    /// Metres between two coordinates (haversine).
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        fatalError("lane: core")
    }

    /// Degrees 0..<360 from `from` to `to`.
    public static func bearing(from: Coordinate, to: Coordinate) -> Double {
        fatalError("lane: core")
    }

    /// Smallest absolute difference between two headings, 0...180.
    public static func angleDiff(_ a: Double, _ b: Double) -> Double {
        fatalError("lane: core")
    }

    /// Lateral metres from the line through `from` along `courseDegrees` to `point` (signed).
    public static func crossTrack(point: Coordinate, from: Coordinate, courseDegrees: Double) -> Double {
        fatalError("lane: core")
    }

    /// Metres along the chord `from`->`to` of the projection of `point`, clamped to the chord.
    public static func projection(point: Coordinate, from: Coordinate, to: Coordinate) -> Double {
        fatalError("lane: core")
    }
}
