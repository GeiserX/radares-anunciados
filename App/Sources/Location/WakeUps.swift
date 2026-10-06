// Lane: location
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The two system-persisted wake-ups (design 3.1): CLMonitor "radares.wake" with the parked condition
// (assuming .satisfied, so the first .unsatisfied is the exit) and the significant-change manager with its delegate.

import CoreLocation
import RadaresCore

public actor WakeUps {
    public static let monitorName = "radares.wake"
    public static let parkedIdentifier = "parked"

    public init() {}

    /// Recreate the monitor by name, start iterating its events, start significant change. Every launch.
    public func start() {
        fatalError("lane: location")
    }

    /// Move the parked fence to `center` (remove + add).
    public func rearmFence(at center: Coordinate) {
        fatalError("lane: location")
    }

    public func stop() {
        fatalError("lane: location")
    }
}
