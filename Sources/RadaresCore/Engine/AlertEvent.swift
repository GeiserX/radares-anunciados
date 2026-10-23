// Lane: frozen (orchestrator)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// `.full` = speech + the Time Sensitive notification. `.visual` = the notification without the voice and the
/// in-app card row (opposite direction, pacing gap). A missed warning costs a fine, a wrong
/// "opposite" costs a glance, so contested direction data demotes to `.visual` and never hides.
public enum Level: String, Sendable, Codable, Hashable {
    case full
    case visual
}

/// What the surfaces say and show for one event. Built by `Phrasing` in the core, so the sentence a route
/// vector expects is the sentence the car hears.
public struct Phrase: Sendable, Codable, Hashable {
    /// The sentence for the speech synthesizer, e.g. "Radar fijo a 800 metros. Límite 90."
    public let spoken: String
    /// Short line for the notification title, e.g. "Radar fijo a 800 m".
    public let title: String
    /// Second line, e.g. "A-2 km 202,3 · límite 90 km/h".
    public let body: String

    public init(spoken: String, title: String, body: String) {
        self.spoken = spoken
        self.title = title
        self.body = body
    }
}

/// The in-app card's phase.
public enum DrivePhase: String, Sendable, Codable, Hashable {
    case watching
    case approaching
    case alert
    case passed
    case insideStretch
    case paused
    case degraded
}

/// The in-app card (the Mapa tab's "next radar" view, design 4.4) and the notification's source of a
/// `.visual` warning's text. Display values are rounded here (metres and km/h as integers) so the card is
/// small and stable.
public struct DriveContent: Sendable, Codable, Hashable {
    public var phase: DrivePhase
    /// SF Symbol name for the kind, e.g. "camera.fill".
    public var kindSymbol: String
    /// "Radar fijo", "Tramo radar móvil", "Sin radares cerca".
    public var title: String
    /// Road and km, or the name.
    public var subtitle: String
    /// Distance to the next gate, shown at milestones only.
    public var distanceMetres: Int?
    /// Speed limit in km/h when known.
    public var limit: Int?
    public var speedKmh: Int?
    /// The row is a radar for the opposite flow ("sentido contrario").
    public var opposite: Bool
    /// Inside a stretch: chord minus the projection of the car, labelled "aprox.".
    public var stretchRemainingMetres: Int?
    /// Inside an average-speed section: path length since entry over elapsed time.
    public var avgKmh: Int?
    /// "Datos de hace 3 días", "Abre la app". The "aprox." of the stretch remainder is the surfaces' caption, not a note.
    public var note: String?
    public var updatedAt: Date
    /// A straight-line warning for a radar whose road the car is clearly not on (design 2.3): posted silently, never
    /// spoken, and upgraded to a spoken warning once if the car joins the road.
    public var held: Bool
    /// A radar for the opposite flow with a high-confidence bearing (design 2.4): nothing is posted or spoken, only
    /// the log row is written, so a wrong hide can be found in an exported log.
    public var hidden: Bool

    public init(
        phase: DrivePhase,
        kindSymbol: String,
        title: String,
        subtitle: String,
        distanceMetres: Int? = nil,
        limit: Int? = nil,
        speedKmh: Int? = nil,
        opposite: Bool = false,
        stretchRemainingMetres: Int? = nil,
        avgKmh: Int? = nil,
        note: String? = nil,
        updatedAt: Date,
        held: Bool = false,
        hidden: Bool = false
    ) {
        self.phase = phase
        self.kindSymbol = kindSymbol
        self.title = title
        self.subtitle = subtitle
        self.distanceMetres = distanceMetres
        self.limit = limit
        self.speedKmh = speedKmh
        self.opposite = opposite
        self.stretchRemainingMetres = stretchRemainingMetres
        self.avgKmh = avgKmh
        self.note = note
        self.updatedAt = updatedAt
        self.held = held
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey {
        case phase, kindSymbol, title, subtitle, distanceMetres, limit, speedKmh, opposite, stretchRemainingMetres, avgKmh, note, updatedAt, held, hidden
    }

    /// `held` and `hidden` default to false when absent, so content written before they existed still decodes.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decode(DrivePhase.self, forKey: .phase)
        kindSymbol = try c.decode(String.self, forKey: .kindSymbol)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decode(String.self, forKey: .subtitle)
        distanceMetres = try c.decodeIfPresent(Int.self, forKey: .distanceMetres)
        limit = try c.decodeIfPresent(Int.self, forKey: .limit)
        speedKmh = try c.decodeIfPresent(Int.self, forKey: .speedKmh)
        opposite = try c.decode(Bool.self, forKey: .opposite)
        stretchRemainingMetres = try c.decodeIfPresent(Int.self, forKey: .stretchRemainingMetres)
        avgKmh = try c.decodeIfPresent(Int.self, forKey: .avgKmh)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        held = try c.decodeIfPresent(Bool.self, forKey: .held) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }

    /// The idle card: nothing ahead. English by phone locale, like every other title the core writes.
    public static func watching(at date: Date, locale: Locale = .autoupdatingCurrent) -> DriveContent {
        let title = Phrasing.isEnglish(locale) ? "No radars nearby" : "Sin radares cerca"
        return DriveContent(phase: .watching, kindSymbol: "car.fill", title: title, subtitle: "", updatedAt: date)
    }
}

/// One thing the engine decided on a fix. The whole surface chain (speech, notification, log)
/// reads these; the route vectors assert them. Codable so a vector file can hold the expected events.
public struct AlertEvent: Sendable, Codable, Hashable {
    public enum Kind: Sendable, Codable, Hashable {
        case warn(Level)
        case passed
        case stretchEntered
        /// Carries why the stretch was left, so the log row can be written from the event alone (design 2.5).
        case stretchExited(StretchExitReason)
        case driveEnded
    }

    public let kind: Kind
    /// Nil only for `.driveEnded`.
    public let radar: Radar?
    /// Metres to the gate when the event fired; for a stretch joined between its gates, the metres left to the far gate.
    public let distance: Double?
    /// Fired inside `warnDistance - Thresholds.lateBandM` (late wake-up, GPS warm-up).
    public let late: Bool
    /// Lateral distance from the course line to the gate, logged on every alert so the cone can be tuned from real drives.
    public let crossTrackMetres: Double?
    /// Nil when nothing is said or shown as text (`.passed`, `.driveEnded`).
    public let phrase: Phrase?
    /// The card after this event.
    public let content: DriveContent

    public init(
        kind: Kind,
        radar: Radar? = nil,
        distance: Double? = nil,
        late: Bool = false,
        crossTrackMetres: Double? = nil,
        phrase: Phrase? = nil,
        content: DriveContent
    ) {
        self.kind = kind
        self.radar = radar
        self.distance = distance
        self.late = late
        self.crossTrackMetres = crossTrackMetres
        self.phrase = phrase
        self.content = content
    }
}
