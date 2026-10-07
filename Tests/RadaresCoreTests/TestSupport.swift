// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared helpers: the fixture, synthetic radars and fixes. Tests run offline against Fixtures/ only.

import Foundation
import XCTest
@testable import RadaresCore

enum Fixtures {
    static func url(_ name: String, ext: String, subdirectory: String = "Fixtures") throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory), "missing fixture \(name).\(ext)")
    }

    static func feedData() throws -> Data {
        try Data(contentsOf: url("feed-sample", ext: "geojson"))
    }

    static func store() throws -> RadarStore {
        try RadarStore.load(geojson: feedData())
    }

    static func radar(_ id: String) throws -> Radar {
        try XCTUnwrap(store().radar(id: id), "fixture has no radar \(id)")
    }

    /// The fixture replicated with suffixed ids until it has at least `count` features: a feed-sized file, offline.
    static func syntheticFeed(count: Int) throws -> Data {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: feedData()) as? [String: Any])
        let base = try XCTUnwrap(json["features"] as? [[String: Any]])
        var features: [[String: Any]] = []
        var copy = 0
        while features.count < count {
            for f in base {
                var g = f
                if copy > 0, let id = f["id"] as? String { g["id"] = "\(id)#\(copy)" }
                features.append(g)
                if features.count >= count { break }
            }
            copy += 1
        }
        return try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
    }

    static let es = Locale(identifier: "es_ES")
    static let en = Locale(identifier: "en_GB")
}

extension Coordinate {
    static func at(_ lat: Double, _ lon: Double) -> Coordinate { Coordinate(latitude: lat, longitude: lon) }
}

func makeRadar(
    id: String = "test",
    kind: Kind = .fixed,
    role: Role = .point,
    start: Coordinate = .at(41.3, -1.9),
    end: Coordinate? = nil,
    name: String = "Radar fijo A-2 km 202.3",
    road: String? = nil,
    kmFrom: Double? = nil,
    kmTo: Double? = nil,
    maxspeed: Int? = nil,
    bearing: Double? = nil,
    bidirectional: Bool = false,
    directionText: String? = nil,
    validFrom: Date? = nil,
    validTo: Date? = nil,
    active: Bool = true,
    source: String = "dgt"
) -> Radar {
    var chord: Double?
    var roadMetres: Double?
    if let end { chord = Geo.distance(start, end) }
    if let kmFrom, let kmTo { roadMetres = abs(kmTo - kmFrom) * 1000 }
    return Radar(
        id: id, kind: kind, role: role, start: start, end: end, chordMetres: chord, roadMetres: roadMetres, name: name,
        road: road, kmFrom: kmFrom, kmTo: kmTo, maxspeed: maxspeed, bearing: bearing, bidirectional: bidirectional,
        directionText: directionText, validFrom: validFrom, validTo: validTo, active: active, source: source,
        attribution: "test", url: nil, province: nil
    )
}

func makeFix(_ c: Coordinate, t: Date, speed: Double? = 25, course: Double? = 0, accuracy: Double = 5, stationary: Bool = false) -> Fix {
    Fix(coordinate: c, timestamp: t, speed: speed, course: course, horizontalAccuracy: accuracy, isStationary: stationary)
}

let t0 = Date(timeIntervalSince1970: 1_791_367_200) // 2026-10-07T10:00:00Z

func madridDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Madrid")!
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

/// A straight 1 Hz drive from `metresBefore` before `gate` along `course`, to `metresAfter` beyond it.
func straightFixes(gate: Coordinate, course: Double, speed: Double, metresBefore: Double, metresAfter: Double, start: Date = t0, courseInFix: Bool = true) -> [Fix] {
    var fixes: [Fix] = []
    var pos = Geo.destination(from: gate, bearingDegrees: Geo.normalize(course + 180), metres: metresBefore)
    let n = Int(((metresBefore + metresAfter) / speed).rounded())
    for i in 0..<n {
        pos = Geo.destination(from: pos, bearingDegrees: course, metres: speed)
        fixes.append(makeFix(pos, t: start.addingTimeInterval(Double(i + 1)), speed: speed, course: courseInFix ? course : nil))
    }
    return fixes
}
