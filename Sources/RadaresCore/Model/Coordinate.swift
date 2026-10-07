// Lane: frozen (orchestrator)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A WGS84 position. The only geographic type in the core, so no Core Location type crosses into the alert maths.
public struct Coordinate: Sendable, Codable, Hashable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}
