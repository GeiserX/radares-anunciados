// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure driving-state rules (design 3.1): driveFixes at driveSpeedMps start, stationary or pauseSlowSeconds pause,
// a resume within pauseEndMinutes continues, later ends. Time comes from the fixes, never from a clock.

import Foundation

public enum DriveSignal: Sendable, Hashable {
    case none
    case started
    case paused
    case resumed
    case ended
}

public struct DrivingDetector: Sendable {
    public enum Phase: Sendable, Hashable {
        case idle
        case driving
        case paused(since: Date)
    }

    public private(set) var phase: Phase = .idle
    private var fastFixes = 0
    private var slowSince: Date?

    public init() {}

    public mutating func ingest(_ fix: Fix) -> DriveSignal {
        let speed = fix.speed ?? 0
        switch phase {
        case .idle:
            if fix.isStationary {
                fastFixes = 0
                return .none
            }
            guard speed >= Thresholds.driveSpeedMps else { return .none }
            fastFixes += 1
            guard fastFixes >= Thresholds.driveFixes else { return .none }
            phase = .driving
            slowSince = nil
            return .started

        case .driving:
            if fix.isStationary {
                return pause(at: fix.timestamp)
            }
            if speed < Thresholds.pauseSlowSpeedMps {
                let since = slowSince ?? fix.timestamp
                slowSince = since
                if fix.timestamp.timeIntervalSince(since) >= Thresholds.pauseSlowSeconds {
                    return pause(at: fix.timestamp)
                }
            } else {
                slowSince = nil
            }
            return .none

        case .paused(let since):
            guard !fix.isStationary, speed >= Thresholds.resumeSpeedMps else { return .none }
            if fix.timestamp.timeIntervalSince(since) < Thresholds.pauseEndMinutes * 60 {
                phase = .driving
                slowSince = nil
                return .resumed
            }
            phase = .idle
            fastFixes = speed >= Thresholds.driveSpeedMps ? 1 : 0
            slowSince = nil
            return .ended
        }
    }

    private mutating func pause(at date: Date) -> DriveSignal {
        phase = .paused(since: date)
        slowSince = nil
        fastFixes = 0
        return .paused
    }
}
