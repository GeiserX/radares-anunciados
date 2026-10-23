// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// roads.json in memory (design 5.4, 5.5): per feature id either the approaches to a point radar or the road line of
// a stretch with its gate approaches. The encoded strings are kept and decoded on first use into a small cache, so
// the whole file never sits in memory as coordinates (about 260,000 vertices would be 12 MB; the strings are 1.3 MB).
// Stretch lines are indexed by boxes of at most Thresholds.roadChunkM of road, so `lineCandidates` finds a bowed
// corridor near its road, not by its chord. A linear scan over about 19,000 boxes, like RadarStore.

import Foundation

/// The road geometry of one feature.
public enum RoadShape: Sendable, Hashable {
    /// A point radar: one polyline per monitored direction, each in the direction of travel and ending at the radar.
    case approaches([Polyline])
    /// A stretch: the road from the feed's first vertex to its last (undirected), and the approaches that end at each
    /// gate and run toward the stretch.
    case line(Polyline, gatesStart: [Polyline], gatesEnd: [Polyline])
}

/// The shapes of roads.json (design 5.5). Unknown keys are ignored.
struct RoadsFile: Decodable {
    struct Approach: Decodable {
        let polyline: String
        let bearing: Double?
    }

    struct Gates: Decodable {
        let start: [Approach]?
        let end: [Approach]?
    }

    struct Entry: Decodable {
        let approaches: [Approach]?
        let line: String?
        let gates: Gates?
    }

    let version: Int
    let precision: Int?
    let attribution: String?
    let features: [String: Entry]
}

public final class RoadGeometry: @unchecked Sendable {
    private enum Encoded {
        case approaches([String])
        case line(String, start: [String], end: [String])
    }

    private struct LineBox {
        var box: GeoBox
        var id: String
    }

    private let encoded: [String: Encoded]
    private let precision: Int
    private let boxes: [LineBox]
    /// Shapes given as values (tests) or decoded on use. Guarded by `lock`; cleared when it grows past `cacheLimit`.
    private var cache: [String: RoadShape]
    private let pinned: Bool
    private let lock = NSLock()
    private static let cacheLimit = 512

    /// The number of feature ids with geometry.
    public let count: Int

    /// From values, for tests and synthetic stores. Nothing is decoded later.
    public init(shapes: [String: RoadShape]) {
        encoded = [:]
        precision = 5
        cache = shapes
        pinned = true
        count = shapes.count
        var boxes: [LineBox] = []
        for (id, shape) in shapes.sorted(by: { $0.key < $1.key }) {
            if case .line(let line, _, _) = shape {
                boxes.append(contentsOf: line.chunkBoxes(maxMetres: Thresholds.roadChunkM).map { LineBox(box: $0, id: id) })
            }
        }
        self.boxes = boxes
    }

    /// From the file's bytes. Lines are decoded once here for their boxes and dropped; everything else on use.
    /// Throws when the JSON does not parse; RoadsValidator checks the rest before a download replaces the file.
    public convenience init(data: Data) throws {
        let file = try JSONDecoder().decode(RoadsFile.self, from: data)
        self.init(file: file)
    }

    init(file: RoadsFile) {
        var encoded: [String: Encoded] = [:]
        encoded.reserveCapacity(file.features.count)
        var boxes: [LineBox] = []
        let precision = file.precision ?? 5
        for (id, entry) in file.features.sorted(by: { $0.key < $1.key }) {
            if let line = entry.line {
                encoded[id] = .line(line, start: entry.gates?.start?.map(\.polyline) ?? [], end: entry.gates?.end?.map(\.polyline) ?? [])
                if let p = Polyline(encoded: line, precision: precision) {
                    boxes.append(contentsOf: p.chunkBoxes(maxMetres: Thresholds.roadChunkM).map { LineBox(box: $0, id: id) })
                }
            } else if let approaches = entry.approaches, !approaches.isEmpty {
                encoded[id] = .approaches(approaches.map(\.polyline))
            }
        }
        self.encoded = encoded
        self.precision = precision
        self.boxes = boxes
        cache = [:]
        pinned = false
        count = encoded.count
    }

    /// The decoded shape of `id`, or nil when the file has none (the radar then runs today's straight-line rules).
    public func shape(for id: String) -> RoadShape? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[id] { return hit }
        guard !pinned, let e = encoded[id] else { return nil }
        let shape: RoadShape?
        switch e {
        case .approaches(let strings):
            let ps = strings.compactMap { Polyline(encoded: $0, precision: precision) }
            shape = ps.isEmpty ? nil : .approaches(ps)
        case .line(let line, let start, let end):
            shape = Polyline(encoded: line, precision: precision).map {
                .line($0, gatesStart: start.compactMap { Polyline(encoded: $0, precision: precision) }, gatesEnd: end.compactMap { Polyline(encoded: $0, precision: precision) })
            }
        }
        if let shape {
            if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[id] = shape
        }
        return shape
    }

    public func approaches(for id: String) -> [Polyline]? {
        if case .approaches(let ps)? = shape(for: id) { return ps }
        return nil
    }

    public func line(for id: String) -> Polyline? {
        if case .line(let p, _, _)? = shape(for: id) { return p }
        return nil
    }

    public func gates(for id: String) -> (start: [Polyline], end: [Polyline])? {
        if case .line(_, let s, let e)? = shape(for: id) { return (s, e) }
        return nil
    }

    /// Ids of stretch lines with a piece of road within about `metres` of `near` (box test, no exact distance).
    public func lineCandidates(near: Coordinate, within metres: Double) -> [String] {
        let dLat = metres / 111_320
        let dLon = metres / (111_320 * max(0.01, cos(near.latitude * .pi / 180)))
        let minLat = near.latitude - dLat, maxLat = near.latitude + dLat
        let minLon = near.longitude - dLon, maxLon = near.longitude + dLon
        var seen = Set<String>()
        var out: [String] = []
        for b in boxes {
            let box = b.box
            if box.maxLat < minLat || box.minLat > maxLat || box.maxLon < minLon || box.minLon > maxLon { continue }
            if seen.insert(b.id).inserted { out.append(b.id) }
        }
        return out
    }

    /// Number of line boxes (tests and the memory note in design 5.4).
    public var boxCount: Int { boxes.count }
}

public enum RoadsError: Error, Sendable, Hashable {
    case tooLarge(Int)
    case notJSON(String)
    case wrongVersion(Int)
    case tooFewEntries(Int)
    case brokenPolyline(id: String)
}

/// The checks of design 5.1 for roads.json: at most Thresholds.roadsMaxBytes, parses, version 1, at least
/// Thresholds.roadsMinEntries usable entries (a line, or at least one approach), every polyline present (approaches,
/// line, gates) decodes to at least two distinct vertices. An entry with no usable polyline (`{"approaches": []}`) is
/// skipped and not counted, as RoadGeometry skips it: one empty entry must not refuse the whole file.
/// A refused file keeps the old one; a radar without geometry runs today's rules.
public enum RoadsValidator {
    public static func validate(_ data: Data) -> Result<RoadGeometry, RoadsError> {
        guard data.count <= Thresholds.roadsMaxBytes else { return .failure(.tooLarge(data.count)) }
        let file: RoadsFile
        do {
            file = try JSONDecoder().decode(RoadsFile.self, from: data)
        } catch {
            return .failure(.notJSON(String(describing: error).prefix(200).description))
        }
        guard file.version == 1 else { return .failure(.wrongVersion(file.version)) }
        let precision = file.precision ?? 5
        var usable = 0
        for (id, entry) in file.features {
            var strings = entry.approaches?.map(\.polyline) ?? []
            if let line = entry.line { strings.append(line) }
            strings += entry.gates?.start?.map(\.polyline) ?? []
            strings += entry.gates?.end?.map(\.polyline) ?? []
            for s in strings where !Polyline.isValid(s, precision: precision) {
                return .failure(.brokenPolyline(id: id))
            }
            if entry.line != nil || !(entry.approaches ?? []).isEmpty { usable += 1 }
        }
        guard usable >= Thresholds.roadsMinEntries else { return .failure(.tooFewEntries(usable)) }
        return .success(RoadGeometry(file: file))
    }
}
