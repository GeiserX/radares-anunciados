// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The decoded feed in memory: a linear scan with a precomputed bounding box per radar (design 5.4).
// `candidates(near:within:on:)` applies the alertable rules: active, not reported, mobile_announced valid on `day`.

import Foundation

public final class RadarStore: Sendable {
    public let all: [Radar]

    public init(radars: [Radar]) {
        all = radars
    }

    public static func load(geojson: Data) throws -> RadarStore {
        fatalError("lane: core")
    }

    public var count: Int { all.count }

    public var countsByKind: [Kind: Int] {
        fatalError("lane: core")
    }

    public func candidates(near: Coordinate, within metres: Double, on day: Date) -> [Radar] {
        fatalError("lane: core")
    }

    public func radar(id: String) -> Radar? {
        fatalError("lane: core")
    }
}
