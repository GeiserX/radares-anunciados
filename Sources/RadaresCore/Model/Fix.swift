// Lane: frozen (orchestrator)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One position sample, platform-neutral. The location lane builds it from a `CLLocationUpdate`;
/// the route vectors in the tests carry arrays of them. One per second while driving.
public struct Fix: Sendable, Codable, Hashable {
    public var coordinate: Coordinate
    public var timestamp: Date
    /// Metres per second; nil when the platform marks the speed invalid (negative speed or speed accuracy).
    public var speed: Double?
    /// Degrees 0..<360; nil when the platform marks the course invalid (negative course or course accuracy).
    public var course: Double?
    /// Metres, the platform's horizontal accuracy radius.
    public var horizontalAccuracy: Double
    /// The platform says the device is not moving and may suspend updates.
    public var isStationary: Bool

    public init(
        coordinate: Coordinate,
        timestamp: Date,
        speed: Double? = nil,
        course: Double? = nil,
        horizontalAccuracy: Double,
        isStationary: Bool = false
    ) {
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
        self.isStationary = isStationary
    }
}
