// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Decodable shapes of feed.geojson (design 5.5). Unknown kinds and properties are ignored by the decoder;
// an unknown geometry type decodes as `.unsupported` so one odd feature never fails the whole file.

import Foundation

public struct GeoJSONFeatureCollection: Decodable, Sendable {
    public let type: String
    public let features: [GeoJSONFeature]
}

public struct GeoJSONFeature: Decodable, Sendable {
    public let id: String?
    public let geometry: GeoJSONGeometry?
    public let properties: GeoJSONProperties?
}

/// Point or LineString; coordinates are [lon, lat] pairs as GeoJSON writes them.
public enum GeoJSONGeometry: Decodable, Sendable {
    case point([Double])
    case lineString([[Double]])
    case unsupported(String)

    private enum CodingKeys: String, CodingKey {
        case type, coordinates
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "Point":
            self = .point(try c.decode([Double].self, forKey: .coordinates))
        case "LineString":
            self = .lineString(try c.decode([[Double]].self, forKey: .coordinates))
        default:
            self = .unsupported(type)
        }
    }
}

public struct GeoJSONProperties: Decodable, Sendable {
    public let kind: String?
    public let name: String?
    public let source: String?
    public let active: Bool?
    public let maxspeed: Int?
    public let direction: String?
    public let province: String?
    public let url: String?
    public let attribution: String?
    public let validFrom: String?
    public let validTo: String?
    public let road: String?
    public let kmFrom: Double?
    public let kmTo: Double?
    /// Travel bearing of the monitored traffic, 0..<360, written by the feed's roads step (design 5.5).
    public let bearing: Double?
    /// "travel" whenever `bearing` is present; anything else and the bearing is ignored.
    public let directionSemantics: String?
    /// "high" or "low"; an unknown value reads as low.
    public let directionConfidence: String?
    /// The strongest signal behind `bearing` ("official_km", "oneway", "osm_tag"): kept for audit, not used.
    public let bearingSource: String?
    /// The publisher's road number on a point ("A-7"). Not `road`, so 0.1.3's notification body is unchanged.
    public let roadRef: String?
    /// The publisher's km marker on a point.
    public let km: Double?
    /// "positive", "negative" or "both": the publisher's direction along the km markers, verbatim.
    public let kmDirection: String?

    enum CodingKeys: String, CodingKey {
        case kind, name, source, active, maxspeed, direction, province, url, attribution, road, bearing, km
        case validFrom = "valid_from"
        case validTo = "valid_to"
        case kmFrom = "km_from"
        case kmTo = "km_to"
        case directionSemantics = "direction_semantics"
        case directionConfidence = "direction_confidence"
        case bearingSource = "bearing_source"
        case roadRef = "road_ref"
        case kmDirection = "km_direction"
    }
}
