// Lane: frozen (orchestrator)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the engine knows right now, for the in-app "next radar" card, the map and a Live Activity
/// requested mid-drive (`RootView.onAppear` while driving). Read, never mutated, by the surfaces and app lanes.
public struct DriveSnapshot: Sendable, Codable, Hashable {
    /// The stretch the car is inside, if any (design 2.5).
    public struct StretchState: Sendable, Codable, Hashable {
        public var radar: Radar
        public var enteredAt: Date
        /// The gate the car came in through.
        public var entryGate: Coordinate
        /// Chord minus the projection of the car onto it, "aprox.".
        public var remainingMetres: Double?
        /// Average-speed sections only: path length since entry over elapsed time, km/h.
        public var avgKmh: Double?
        /// The speed at entry, for the silent time exit; kept so a relaunch mid-stretch restores it.
        public var entrySpeedMps: Double?
        /// Where the car was at entry (the warn distance before the gate): after a relaunch the path driven since
        /// is estimated from here.
        public var entryCoordinate: Coordinate?

        public init(radar: Radar, enteredAt: Date, entryGate: Coordinate, remainingMetres: Double? = nil, avgKmh: Double? = nil, entrySpeedMps: Double? = nil, entryCoordinate: Coordinate? = nil) {
            self.radar = radar
            self.enteredAt = enteredAt
            self.entryGate = entryGate
            self.remainingMetres = remainingMetres
            self.avgKmh = avgKmh
            self.entrySpeedMps = entrySpeedMps
            self.entryCoordinate = entryCoordinate
        }
    }

    /// A radar shown as "sentido contrario" or demoted by pacing: on the card, never spoken.
    public struct VisualRow: Sendable, Codable, Hashable {
        public var radar: Radar
        public var distanceMetres: Double
        public var opposite: Bool

        public init(radar: Radar, distanceMetres: Double, opposite: Bool) {
            self.radar = radar
            self.distanceMetres = distanceMetres
            self.opposite = opposite
        }
    }

    /// The radar the card is about: the one fired or armed ahead, else the nearest candidate ("cerca").
    public var next: Radar?
    public var distanceMetres: Double?
    /// The speed the warn distance was computed from (median of the last valid speeds), m/s.
    public var speedMps: Double?
    /// The course in use, degrees; nil means nothing fires and the card shows the nearest radar as "cerca".
    public var courseDegrees: Double?
    public var stretch: StretchState?
    public var visualRows: [VisualRow]
    public var lastFix: Fix?
    /// The card as it stands.
    public var content: DriveContent

    public init(
        next: Radar? = nil,
        distanceMetres: Double? = nil,
        speedMps: Double? = nil,
        courseDegrees: Double? = nil,
        stretch: StretchState? = nil,
        visualRows: [VisualRow] = [],
        lastFix: Fix? = nil,
        content: DriveContent
    ) {
        self.next = next
        self.distanceMetres = distanceMetres
        self.speedMps = speedMps
        self.courseDegrees = courseDegrees
        self.stretch = stretch
        self.visualRows = visualRows
        self.lastFix = lastFix
        self.content = content
    }

    /// Before the first fix.
    public static func empty(at date: Date, locale: Locale = .autoupdatingCurrent) -> DriveSnapshot {
        DriveSnapshot(content: .watching(at: date, locale: locale))
    }
}
