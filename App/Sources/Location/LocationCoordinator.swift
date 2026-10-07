// Lane: location
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The one owner of location state (design 3): idle, probing, driving, paused(since:). Holds the Always
// CLServiceSession as a `let` taken in init, the wake-ups, the motion gate and the drive session.
// `bootstrap(state:)` runs from didFinishLaunching: in the background the stream starts first, then the probe.

import CoreLocation
import RadaresCore
import UIKit
import os

public enum DriveState: Sendable, Hashable {
    case idle
    case probing
    case driving
    case paused(since: Date)
}

public actor LocationCoordinator {
    public static let shared = LocationCoordinator()

    public private(set) var state: DriveState = .idle

    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "location")

    private init() {}

    /// Stub: logs and returns so the skeleton launches in the simulator.
    public func bootstrap(state: UIApplication.State) {
        logger.warning("lane: location: bootstrap not implemented (launch state \(state.rawValue))")
    }

    public func startDrive(reason: DriveReason) {
        fatalError("lane: location")
    }

    public func stopDrive() {
        fatalError("lane: location")
    }

    /// The "Avisos" switch: session, significant change and the fence go together (design 7).
    public func setWarningsEnabled(_ on: Bool) {
        fatalError("lane: location")
    }
}
