// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The decoded feed in memory: a linear scan with a precomputed bounding box per radar (design 5.4).
// `candidates(near:within:on:)` applies the alertable rules: active, not reported, mobile_announced valid on `day`.
// A line is a candidate by its nearer gate or by its chord, so a car between the gates sees the stretch (design 2.5).
// No spatial index: 4,500 boxes compare in about 20 us; revisit at Thresholds.spatialIndexRevisitFeatures.

import Foundation

public final class RadarStore: Sendable {
    public let all: [Radar]

    /// One box per radar, same order as `all`: minLat, maxLat, minLon, maxLon in degrees.
    private let boxes: [Box]
    private let byId: [String: Int]

    private struct Box: Sendable {
        var minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
    }

    public init(radars: [Radar]) {
        all = radars
        boxes = radars.map { r in
            let lats = [r.start.latitude, r.end?.latitude ?? r.start.latitude]
            let lons = [r.start.longitude, r.end?.longitude ?? r.start.longitude]
            return Box(minLat: lats.min()!, maxLat: lats.max()!, minLon: lons.min()!, maxLon: lons.max()!)
        }
        var index: [String: Int] = [:]
        index.reserveCapacity(radars.count)
        for (i, r) in radars.enumerated() where index[r.id] == nil { index[r.id] = i }
        byId = index
    }

    public static func load(geojson: Data) throws -> RadarStore {
        RadarStore(radars: try FeedDecoder.decode(geojson))
    }

    public var count: Int { all.count }

    public var countsByKind: [Kind: Int] {
        var counts: [Kind: Int] = [:]
        for r in all { counts[r.kind, default: 0] += 1 }
        return counts
    }

    /// Alertable radars within `metres` of `near` (the point; for a line, the nearer gate or the chord between them)
    /// on the Europe/Madrid calendar day of `day`. Order: nearest first.
    public func candidates(near: Coordinate, within metres: Double, on day: Date) -> [Radar] {
        let dLat = metres / 111_320
        let cosLat = max(0.01, cos(near.latitude * .pi / 180))
        let dLon = metres / (111_320 * cosLat)
        let minLat = near.latitude - dLat, maxLat = near.latitude + dLat
        let minLon = near.longitude - dLon, maxLon = near.longitude + dLon
        var found: [(Double, Radar)] = []
        for i in boxes.indices {
            let b = boxes[i]
            if b.maxLat < minLat || b.minLat > maxLat || b.maxLon < minLon || b.minLon > maxLon { continue }
            let r = all[i]
            let d = Self.distance(from: near, to: r)
            guard d <= metres, r.isAlertable(on: day) else { continue }
            found.append((d, r))
        }
        found.sort { $0.0 < $1.0 }
        return found.map(\.1)
    }

    /// Metres from `point` to the nearer gate of `radar`.
    public static func gateDistance(from point: Coordinate, to radar: Radar) -> Double {
        let d = Geo.distance(point, radar.start)
        guard let end = radar.end else { return d }
        return min(d, Geo.distance(point, end))
    }

    /// Metres from `point` to the nearest part of `radar`: the point, or for a line the nearer gate or the chord.
    public static func distance(from point: Coordinate, to radar: Radar) -> Double {
        guard let end = radar.end else { return Geo.distance(point, radar.start) }
        return Geo.distanceToChord(point: point, from: radar.start, to: end)
    }

    public func radar(id: String) -> Radar? {
        byId[id].map { all[$0] }
    }
}
