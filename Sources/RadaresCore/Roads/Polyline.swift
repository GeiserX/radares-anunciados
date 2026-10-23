// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A road line from roads.json (design 5.5): Google's encoded polyline at precision 5, decoded into vertices,
// cumulative metres and per-segment travel bearings. Projection runs in a flat frame around the line's middle
// (one cosine per line): over the 1.5 km of an approach or the 30 km of the longest stretch the error against the
// haversine distance is far under a GPS fix, and every per-fix test stays a few multiplications per segment.

import Foundation

public struct Polyline: Sendable, Hashable {
    /// Vertices in the order of the file: for an approach, the direction of travel, ending at the radar.
    public let vertices: [Coordinate]
    /// Metres from the first vertex to each vertex, measured in the flat frame.
    public let cumulative: [Double]
    /// Travel bearing of each segment (vertex i to i + 1), degrees 0..<360.
    public let segmentBearings: [Double]

    private let lat0: Double
    private let lon0: Double
    private let kx: Double
    private let ky: Double
    private let xs: [Double]
    private let ys: [Double]

    /// Total length in metres.
    public var length: Double { cumulative.last ?? 0 }

    /// Where a point falls on one segment.
    public struct Projection: Sendable, Hashable {
        /// Metres from the point to the segment (perpendicular, or to the nearer end).
        public var lateralMetres: Double
        /// Metres from the line's first vertex to the foot of the point on the segment.
        public var alongMetres: Double
        public var segmentIndex: Int
        public var segmentBearing: Double
    }

    /// At least two vertices; identical consecutive vertices are dropped. Nil when fewer than two distinct remain.
    public init?(vertices raw: [Coordinate]) {
        var v: [Coordinate] = []
        v.reserveCapacity(raw.count)
        for c in raw where v.last != c { v.append(c) }
        guard v.count >= 2 else { return nil }
        vertices = v
        let lats = v.map(\.latitude), lons = v.map(\.longitude)
        lat0 = (lats.min()! + lats.max()!) / 2
        lon0 = (lons.min()! + lons.max()!) / 2
        ky = Geo.earthRadiusM * .pi / 180
        kx = ky * cos(lat0 * .pi / 180)
        var xs: [Double] = [], ys: [Double] = []
        xs.reserveCapacity(v.count)
        ys.reserveCapacity(v.count)
        for c in v {
            xs.append((c.longitude - lon0) * kx)
            ys.append((c.latitude - lat0) * ky)
        }
        var cum: [Double] = [0]
        var bearings: [Double] = []
        cum.reserveCapacity(v.count)
        bearings.reserveCapacity(v.count - 1)
        for i in 1..<v.count {
            let dx = xs[i] - xs[i - 1], dy = ys[i] - ys[i - 1]
            cum.append(cum[i - 1] + (dx * dx + dy * dy).squareRoot())
            bearings.append(Geo.normalize(atan2(dx, dy) * 180 / .pi))
        }
        self.xs = xs
        self.ys = ys
        cumulative = cum
        segmentBearings = bearings
    }

    /// Decodes Google's encoded polyline algorithm at precision 5 (1e-5 degrees, latitude then longitude per vertex).
    /// Nil for a malformed string or fewer than two distinct vertices.
    public init?(encoded: String, precision: Int = 5) {
        guard let coords = Self.decode(encoded, precision: precision) else { return nil }
        self.init(vertices: coords)
    }

    public static func decode(_ encoded: String, precision: Int = 5) -> [Coordinate]? {
        var copy = encoded
        return copy.withUTF8 { decode(utf8: $0, precision: precision) }
    }

    /// The decoder on raw bytes: one pass, no allocation but the result.
    static func decode(utf8 bytes: UnsafeBufferPointer<UInt8>, precision: Int) -> [Coordinate]? {
        let factor = pow(10.0, Double(precision))
        var coords: [Coordinate] = []
        coords.reserveCapacity(bytes.count / 4)
        var lat = 0, lon = 0
        var values = (0, 0)
        var which = 0
        var result = 0, shift = 0
        for b in bytes {
            guard b >= 63, b <= 126, shift <= 30 else { return nil }
            let chunk = Int(b) - 63
            result |= (chunk & 0x1f) << shift
            shift += 5
            if chunk >= 0x20 { continue }
            let v = (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
            result = 0
            shift = 0
            if which == 0 {
                values.0 = v
                which = 1
                continue
            }
            values.1 = v
            which = 0
            lat += values.0
            lon += values.1
            let c = Coordinate(latitude: Double(lat) / factor, longitude: Double(lon) / factor)
            guard abs(c.latitude) <= 90, abs(c.longitude) <= 180 else { return nil }
            coords.append(c)
        }
        // Cut inside a value, or a latitude without its longitude.
        guard shift == 0, which == 0 else { return nil }
        return coords
    }

    /// True when `encoded` decodes to at least two distinct vertices: the validator's test, without building a line.
    static func isValid(_ encoded: String, precision: Int = 5) -> Bool {
        guard let coords = decode(encoded, precision: precision), let first = coords.first else { return false }
        return coords.contains { $0 != first }
    }

    /// Encodes vertices with the same algorithm (tests and tools).
    public static func encode(_ coords: [Coordinate], precision: Int = 5) -> String {
        let factor = pow(10.0, Double(precision))
        var out = ""
        var pLat = 0, pLon = 0
        func put(_ value: Int) {
            var v = value < 0 ? ~(value << 1) : (value << 1)
            while v >= 0x20 {
                out.unicodeScalars.append(Unicode.Scalar(UInt8((0x20 | (v & 0x1f)) + 63)))
                v >>= 5
            }
            out.unicodeScalars.append(Unicode.Scalar(UInt8(v + 63)))
        }
        for c in coords {
            let lat = Int((c.latitude * factor).rounded()), lon = Int((c.longitude * factor).rounded())
            put(lat - pLat)
            put(lon - pLon)
            pLat = lat
            pLon = lon
        }
        return out
    }

    // MARK: Projection

    /// The point projected onto every segment, in segment order.
    public func projections(of point: Coordinate) -> [Projection] {
        let px = (point.longitude - lon0) * kx, py = (point.latitude - lat0) * ky
        var out: [Projection] = []
        out.reserveCapacity(xs.count - 1)
        for i in 0..<(xs.count - 1) {
            out.append(project(px, py, segment: i))
        }
        return out
    }

    /// The nearest segment's projection. With a hint (the segment of the last fix), the segments within `window` of it
    /// are searched first and their best is kept when it is within `maxLateral`; otherwise every segment is searched.
    public func project(_ point: Coordinate, hint: Int? = nil, window: Int = 8, maxLateral: Double = .infinity) -> Projection {
        let px = (point.longitude - lon0) * kx, py = (point.latitude - lat0) * ky
        let n = xs.count - 1
        if let hint {
            let lo = max(0, hint - window), hi = min(n - 1, hint + window)
            if lo <= hi {
                var best = project(px, py, segment: lo)
                for i in stride(from: lo + 1, through: hi, by: 1) {
                    let p = project(px, py, segment: i)
                    if p.lateralMetres < best.lateralMetres { best = p }
                }
                if best.lateralMetres <= maxLateral { return best }
            }
        }
        var best = project(px, py, segment: 0)
        for i in stride(from: 1, to: n, by: 1) {
            let p = project(px, py, segment: i)
            if p.lateralMetres < best.lateralMetres { best = p }
        }
        return best
    }

    /// The coordinate `metres` from the first vertex along the line, clamped to its ends.
    public func coordinate(atAlong metres: Double) -> Coordinate {
        if metres <= 0 { return vertices[0] }
        if metres >= length { return vertices[vertices.count - 1] }
        var i = 1
        while i < cumulative.count - 1, cumulative[i] < metres { i += 1 }
        let seg = cumulative[i] - cumulative[i - 1]
        let f = seg > 0 ? (metres - cumulative[i - 1]) / seg : 0
        let x = xs[i - 1] + f * (xs[i] - xs[i - 1]), y = ys[i - 1] + f * (ys[i] - ys[i - 1])
        return Coordinate(latitude: lat0 + y / ky, longitude: lon0 + x / kx)
    }

    private func project(_ px: Double, _ py: Double, segment i: Int) -> Projection {
        let ax = xs[i], ay = ys[i]
        let dx = xs[i + 1] - ax, dy = ys[i + 1] - ay
        let len2 = dx * dx + dy * dy
        var t = len2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / len2 : 0
        t = min(1, max(0, t))
        let qx = ax + t * dx, qy = ay + t * dy
        let lx = px - qx, ly = py - qy
        let seg = cumulative[i + 1] - cumulative[i]
        return Projection(lateralMetres: (lx * lx + ly * ly).squareRoot(), alongMetres: cumulative[i] + t * seg, segmentIndex: i, segmentBearing: segmentBearings[i])
    }

    /// Bounding boxes of consecutive pieces of at most `maxMetres` (at least one segment each), for the line index.
    func chunkBoxes(maxMetres: Double) -> [GeoBox] {
        var boxes: [GeoBox] = []
        var start = 0
        while start < vertices.count - 1 {
            var end = start + 1
            while end < vertices.count - 1, cumulative[end + 1] - cumulative[start] <= maxMetres { end += 1 }
            var box = GeoBox(vertices[start])
            for k in (start + 1)...end { box.add(vertices[k]) }
            boxes.append(box)
            start = end
        }
        return boxes
    }

    public static func == (a: Polyline, b: Polyline) -> Bool { a.vertices == b.vertices }
    public func hash(into hasher: inout Hasher) { hasher.combine(vertices) }
}

/// A latitude/longitude box in degrees.
struct GeoBox: Sendable, Hashable {
    var minLat: Double, maxLat: Double, minLon: Double, maxLon: Double

    init(_ c: Coordinate) {
        minLat = c.latitude
        maxLat = c.latitude
        minLon = c.longitude
        maxLon = c.longitude
    }

    mutating func add(_ c: Coordinate) {
        minLat = min(minLat, c.latitude)
        maxLat = max(maxLat, c.latitude)
        minLon = min(minLon, c.longitude)
        maxLon = max(maxLon, c.longitude)
    }
}
