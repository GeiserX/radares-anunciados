// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// GeoJSON -> [Radar]: the three direction vocabularies, negative bearings mod 360, section twins merged into
// their stretch, roles by kind and source (design 2.1).

import Foundation

public enum FeedDecoder {
    /// The feed's calendar: `valid_from` / `valid_to` are Europe/Madrid calendar days.
    public static let madrid = TimeZone(identifier: "Europe/Madrid")!

    public static var madridCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = madrid
        return c
    }

    public static func decode(_ data: Data) throws -> [Radar] {
        let collection = try JSONDecoder().decode(GeoJSONFeatureCollection.self, from: data)
        return radars(from: collection)
    }

    /// Normalises an already parsed collection. Features without an id, a usable geometry or a known kind are skipped.
    public static func radars(from collection: GeoJSONFeatureCollection) -> [Radar] {
        struct Decoded {
            var radar: Radar
            var sectionMaxspeed: Int?
        }

        var lines: [Radar] = []
        var points: [Radar] = []
        for feature in collection.features {
            guard let radar = radar(from: feature) else { continue }
            if radar.isLine { lines.append(radar) } else { points.append(radar) }
        }

        // Section twins: a `section` point sitting exactly on a stretch endpoint is that stretch's gate, so it is
        // folded into the stretch (its limit fills a missing one) and the pass is one pass. Both ends, every stretch.
        var endpointIndex: [Coordinate: [Int]] = [:]
        for (i, line) in lines.enumerated() {
            endpointIndex[line.start, default: []].append(i)
            if let end = line.end { endpointIndex[end, default: []].append(i) }
        }
        var limitFromSection: [Int: Int] = [:]
        var kept: [Radar] = []
        kept.reserveCapacity(points.count)
        for point in points {
            if point.kind == .section, let owners = endpointIndex[point.start] {
                if let limit = point.maxspeed {
                    for i in owners where lines[i].maxspeed == nil { limitFromSection[i] = limit }
                }
                continue
            }
            kept.append(point)
        }
        var result: [Radar] = []
        result.reserveCapacity(kept.count + lines.count)
        result.append(contentsOf: kept)
        for (i, line) in lines.enumerated() {
            if let limit = limitFromSection[i] {
                result.append(line.with(maxspeed: limit))
            } else {
                result.append(line)
            }
        }
        return result
    }

    static func radar(from feature: GeoJSONFeature) -> Radar? {
        guard let id = feature.id, !id.isEmpty,
              let props = feature.properties,
              let kindString = props.kind, let kind = Kind(rawValue: kindString),
              let geometry = feature.geometry
        else { return nil }

        let start: Coordinate
        var end: Coordinate?
        var chord: Double?
        switch geometry {
        case .point(let c):
            guard let s = coordinate(c) else { return nil }
            start = s
        case .lineString(let cs):
            let vertices = cs.compactMap(coordinate)
            guard vertices.count >= 2, vertices.count == cs.count else { return nil }
            start = vertices[0]
            end = vertices[vertices.count - 1]
            var sum = 0.0
            for i in 1..<vertices.count { sum += Geo.distance(vertices[i - 1], vertices[i]) }
            chord = sum
        case .unsupported:
            return nil
        }

        let source = props.source ?? ""
        let role: Role
        if kind == .stretch {
            role = source == "dgt_invive" ? .mobileCorridor : .averageSpeedSection
        } else {
            role = .point
        }

        let direction = parseDirection(props.direction)
        var roadMetres: Double?
        if let from = props.kmFrom, let to = props.kmTo { roadMetres = abs(to - from) * 1000 }

        return Radar(
            id: id,
            kind: kind,
            role: role,
            start: start,
            end: end,
            chordMetres: chord,
            roadMetres: roadMetres,
            name: props.name ?? id,
            road: props.road,
            kmFrom: props.kmFrom,
            kmTo: props.kmTo,
            maxspeed: props.maxspeed,
            bearing: direction.bearing,
            bidirectional: direction.bidirectional,
            directionText: direction.text,
            validFrom: day(props.validFrom),
            validTo: day(props.validTo),
            active: props.active ?? true,
            source: source,
            attribution: props.attribution ?? "",
            url: props.url.flatMap(URL.init(string:)),
            province: props.province
        )
    }

    struct Direction: Equatable {
        var bearing: Double?
        var bidirectional = false
        var text: String?
    }

    /// The four vocabularies of `properties.direction` (design 2.1): a numeric string is an OSM bearing (negatives folded
    /// mod 360), `both` is bidirectional, a place name is spoken text, null is nothing. OSM's relative tokens
    /// `forward` / `backward` name no place and carry no absolute heading, so they are treated as null.
    static func parseDirection(_ raw: String?) -> Direction {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return Direction() }
        if raw == "both" { return Direction(bidirectional: true) }
        if let value = Double(raw), raw.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "." }) {
            return Direction(bearing: Geo.normalize(value))
        }
        if raw == "forward" || raw == "backward" { return Direction() }
        return Direction(text: raw)
    }

    /// `yyyy-MM-dd` as the start of that day in Europe/Madrid; nil for anything else.
    static func day(_ raw: String?) -> Date? {
        guard let raw, raw.count == 10 else { return nil }
        let parts = raw.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d),
              let date = madridCalendar.date(from: DateComponents(year: y, month: m, day: d)),
              madridCalendar.component(.day, from: date) == d
        else { return nil }
        return date
    }

    private static func coordinate(_ pair: [Double]) -> Coordinate? {
        guard pair.count >= 2, pair[0].isFinite, pair[1].isFinite, abs(pair[1]) <= 90, abs(pair[0]) <= 180 else { return nil }
        return Coordinate(latitude: pair[1], longitude: pair[0])
    }
}

extension Radar {
    func with(maxspeed: Int?) -> Radar {
        Radar(
            id: id, kind: kind, role: role, start: start, end: end, chordMetres: chordMetres, roadMetres: roadMetres,
            name: name, road: road, kmFrom: kmFrom, kmTo: kmTo, maxspeed: maxspeed, bearing: bearing,
            bidirectional: bidirectional, directionText: directionText, validFrom: validFrom, validTo: validTo,
            active: active, source: source, attribution: attribution, url: url, province: province
        )
    }

    /// Alertable (design 2.1): active, not an unconfirmed note, and for an announced mobile radar the day is inside its range.
    public func isAlertable(on day: Date) -> Bool {
        guard active, kind != .reported else { return false }
        guard kind == .mobileAnnounced else { return true }
        let today = FeedDecoder.madridCalendar.startOfDay(for: day)
        if let from = validFrom, today < from { return false }
        if let to = validTo, today > to { return false }
        return validFrom != nil || validTo != nil
    }
}
