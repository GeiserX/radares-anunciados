// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure driving-state rules (design 3.1): driveFixes at driveSpeedMps start, stationary or pauseSlowSeconds pause,
// a resume within pauseEndMinutes continues, later ends.

import Foundation

public enum DriveSignal: Sendable, Hashable {
    case none
    case started
    case paused
    case resumed
    case ended
}

public struct DrivingDetector: Sendable {
    public init() {}

    public mutating func ingest(_ fix: Fix) -> DriveSignal {
        fatalError("lane: core")
    }
}
