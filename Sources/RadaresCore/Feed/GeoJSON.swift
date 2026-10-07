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

    enum CodingKeys: String, CodingKey {
        case kind, name, source, active, maxspeed, direction, province, url, attribution, road
        case validFrom = "valid_from"
        case validTo = "valid_to"
        case kmFrom = "km_from"
        case kmTo = "km_to"
    }
}
