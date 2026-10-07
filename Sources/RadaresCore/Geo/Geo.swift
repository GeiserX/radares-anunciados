// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Haversine distance, atan2 bearing, angle difference, cross-track distance and projection onto a chord.
// Spherical formulas on a 6,371 km Earth: at the distances the engine cares about (under 100 km) the error
// against WGS84 is well under the GPS accuracy of a fix.

import Foundation

public enum Geo {
    /// Mean Earth radius in metres.
    public static let earthRadiusM: Double = 6_371_000

    /// Metres between two coordinates (haversine).
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let s1 = sin(dLat / 2), s2 = sin(dLon / 2)
        let h = s1 * s1 + cos(lat1) * cos(lat2) * s2 * s2
        return 2 * earthRadiusM * asin(min(1, sqrt(h)))
    }

    /// Degrees 0..<360 from `from` to `to` (initial bearing).
    public static func bearing(from: Coordinate, to: Coordinate) -> Double {
        let lat1 = from.latitude * .pi / 180, lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return normalize(atan2(y, x) * 180 / .pi)
    }

    /// Smallest absolute difference between two headings, 0...180.
    public static func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(normalize(a) - normalize(b))
        return d > 180 ? 360 - d : d
    }

    /// Any angle folded into 0..<360.
    public static func normalize(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Lateral metres from the line through `from` along `courseDegrees` to `point` (signed: positive to the right of the course).
    public static func crossTrack(point: Coordinate, from: Coordinate, courseDegrees: Double) -> Double {
        let d13 = distance(from, point) / earthRadiusM
        let t13 = bearing(from: from, to: point) * .pi / 180
        let t12 = courseDegrees * .pi / 180
        return asin(sin(d13) * sin(t13 - t12)) * earthRadiusM
    }

    /// Metres along the chord `from`->`to` of the projection of `point`, clamped to the chord.
    public static func projection(point: Coordinate, from: Coordinate, to: Coordinate) -> Double {
        let chord = distance(from, to)
        guard chord > 0 else { return 0 }
        let d13 = distance(from, point)
        guard d13 > 0 else { return 0 }
        let course = bearing(from: from, to: to)
        let xt = crossTrack(point: point, from: from, courseDegrees: course) / earthRadiusM
        let ratio = min(1, max(-1, cos(d13 / earthRadiusM) / cos(xt)))
        var along = acos(ratio) * earthRadiusM
        if angleDiff(course, bearing(from: from, to: point)) > 90 { along = -along }
        return min(chord, max(0, along))
    }

    /// The coordinate `metres` away from `from` along `bearingDegrees`. Used by tests and the self-test to build a target ahead.
    public static func destination(from: Coordinate, bearingDegrees: Double, metres: Double) -> Coordinate {
        let lat1 = from.latitude * .pi / 180, lon1 = from.longitude * .pi / 180
        let t = bearingDegrees * .pi / 180, d = metres / earthRadiusM
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(t))
        let lon2 = lon1 + atan2(sin(t) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return Coordinate(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }
}
