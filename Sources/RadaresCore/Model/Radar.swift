// Lane: frozen (orchestrator)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The feed's `kind` property, verbatim. `reported` is an unconfirmed OSM note: map only, never warned.
public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
    case fixed
    case section
    case stretch
    case mobileAnnounced = "mobile_announced"
    /// A place where a mobile radar is set up often, derived from published fines (Barcelona, Madrid); no dates.
    case mobileRecurring = "mobile_recurring"
    case trailer
    case reported
}

/// What the app does with a radar, derived by the decoder (design 2.1):
/// `stretch` from `dgt_invive` is a mobile corridor, any other `stretch` an average-speed section, everything else a point.
public enum Role: String, Codable, Sendable, Hashable {
    case point
    case mobileCorridor
    case averageSpeedSection
}

/// One alertable thing from the feed, normalised. Value type, Codable so route vectors and the pass ledger can carry it.
public struct Radar: Sendable, Codable, Identifiable, Hashable {
    /// `feature.id`, unique and stable per source.
    public let id: String
    public let kind: Kind
    public let role: Role
    /// The Point, or the first vertex of the LineString.
    public let start: Coordinate
    /// The last vertex of a LineString; nil for a point.
    public let end: Coordinate?
    /// Sum of the segment lengths of the LineString; nil for a point.
    public let chordMetres: Double?
    /// `|km_to - km_from| * 1000` when both are present.
    public let roadMetres: Double?
    public let name: String
    public let road: String?
    public let kmFrom: Double?
    public let kmTo: Double?
    /// Speed limit in km/h; nil when the feed has none (most entries today).
    public let maxspeed: Int?
    /// Degrees 0..<360, heading of the monitored traffic per OSM; nil when unknown. Contested data: demotes, never hides.
    public let bearing: Double?
    /// `direction == "both"`.
    public let bidirectional: Bool
    /// A place name such as "ZARAGOZA": spoken and shown, never used to gate.
    public let directionText: String?
    /// `mobile_announced` only: the calendar day range (Europe/Madrid) the announcement covers.
    public let validFrom: Date?
    public let validTo: Date?
    public let active: Bool
    public let source: String
    public let attribution: String
    public let url: URL?
    public let province: String?

    public init(
        id: String,
        kind: Kind,
        role: Role,
        start: Coordinate,
        end: Coordinate? = nil,
        chordMetres: Double? = nil,
        roadMetres: Double? = nil,
        name: String,
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
        source: String,
        attribution: String,
        url: URL? = nil,
        province: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.role = role
        self.start = start
        self.end = end
        self.chordMetres = chordMetres
        self.roadMetres = roadMetres
        self.name = name
        self.road = road
        self.kmFrom = kmFrom
        self.kmTo = kmTo
        self.maxspeed = maxspeed
        self.bearing = bearing
        self.bidirectional = bidirectional
        self.directionText = directionText
        self.validFrom = validFrom
        self.validTo = validTo
        self.active = active
        self.source = source
        self.attribution = attribution
        self.url = url
        self.province = province
    }

    /// True for lines (stretches); the two gates are `start` and `end`.
    public var isLine: Bool { end != nil }

    /// Length used for speech and the remaining estimate: the road length when the feed has km markers, else the chord.
    public var lengthMetres: Double? { roadMetres ?? chordMetres }
}
