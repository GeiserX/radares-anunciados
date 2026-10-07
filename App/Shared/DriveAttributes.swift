// Lane: frozen (orchestrator)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Live Activity's attributes and content (design 2.7). Compiled into the app and the widget extension.
// `ContentState` mirrors `DriveContent` in RadaresCore field by field, with the same names and the same
// `Phase` raw values; the surfaces lane copies one into the other. The widget does not link RadaresCore.

import ActivityKit
import Foundation

public struct DriveAttributes: ActivityAttributes {
    public enum Phase: String, Codable, Hashable, Sendable {
        case watching
        case approaching
        case alert
        case passed
        case insideStretch
        case paused
        case degraded
    }

    /// Far under the 4 KB limit: display values are integers and strings are short.
    public struct ContentState: Codable, Hashable, Sendable {
        public var phase: Phase
        /// SF Symbol name for the kind.
        public var kindSymbol: String
        /// "Radar fijo", "Tramo radar móvil", "Sin radares cerca".
        public var title: String
        /// Road and km, or the name.
        public var subtitle: String
        /// Shown at milestones only (1,000 / 750 / 500 / 250 / 100 m); the voice carries the exact distance.
        public var distanceMetres: Int?
        public var limit: Int?
        public var speedKmh: Int?
        /// "sentido contrario" row.
        public var opposite: Bool
        public var stretchRemainingMetres: Int?
        public var avgKmh: Int?
        /// "Datos de hace 3 días", "Abre la app".
        public var note: String?
        public var updatedAt: Date
        /// Set by the app on every update it sends, increasing: the read-back tells a dropped update from one a
        /// later update of the same second replaced. The widget never reads it.
        public var seq: Int

        public init(
            phase: Phase,
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
            seq: Int = 0
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
            self.seq = seq
        }

        private enum CodingKeys: String, CodingKey {
            case phase, kindSymbol, title, subtitle, distanceMetres, limit, speedKmh, opposite, stretchRemainingMetres, avgKmh, note, updatedAt, seq
        }

        /// A content state written by a build without `seq` (an activity alive across an app update) decodes as 0.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            phase = try c.decode(Phase.self, forKey: .phase)
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
            seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        }
    }

    /// When the drive began. Fixed for the life of the activity.
    public var startedAt: Date

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }
}
