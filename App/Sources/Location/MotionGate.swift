// Lane: location
// SPDX-License-Identifier: GPL-3.0-or-later
//
// queryActivityStarting over the last Thresholds.motionWindowSeconds, positive-only (design 3.1, step 1): true means
// a sample said automotive with at least medium confidence; false means nothing automotive in the window; nil means
// Core Motion is unavailable, denied, or the query failed. Core Motion reports activities with a delay of up to
// several minutes, so a negative never shortens or suppresses the probe. The gate only shortens the driving case.
//
// The first query from a process whose authorization is not determined shows the system prompt, which only works
// in the foreground: onboarding calls `requestAccess()` there (design 7, screen 2). A background probe with the
// prompt still pending gets an error and falls through to the speed probe, which is the designed behaviour.

import CoreMotion
import Foundation
import RadaresCore

/// What the motion store said about the window: automotive and walking are independent (a window can hold both).
public struct MotionSummary: Sendable, Hashable {
    /// At least one sample with `automotive == true` and confidence at least medium.
    public var automotive: Bool
    /// At least one sample with `walking == true` or `running == true` and confidence at least medium.
    public var walking: Bool
    public var samples: Int

    public init(automotive: Bool, walking: Bool, samples: Int) {
        self.automotive = automotive
        self.walking = walking
        self.samples = samples
    }
}

public struct MotionGate: Sendable {
    public init() {}

    /// `CMMotionActivityManager.authorizationStatus()` mapped for the Estado row "Movimiento".
    public static var authorization: HealthInputs.MotionAuthorization {
        switch CMMotionActivityManager.authorizationStatus() {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .notDetermined
        }
    }

    /// The frozen signature (design 9): automotive in the last `window` seconds, nil when unavailable or denied.
    public func recentAutomotive(window: TimeInterval) async -> Bool? {
        await recentActivity(window: window)?.automotive
    }

    /// Automotive and walking in the last `window` seconds; nil when unavailable, denied or on a query error.
    public func recentActivity(window: TimeInterval) async -> MotionSummary? {
        guard CMMotionActivityManager.isActivityAvailable() else { return nil }
        switch CMMotionActivityManager.authorizationStatus() {
        case .denied, .restricted:
            return nil
        case .notDetermined, .authorized:
            break
        @unknown default:
            return nil
        }
        let end = Date()
        return await Self.query(from: end.addingTimeInterval(-window), to: end)
    }

    /// Runs one query so the system shows the Core Motion prompt. Foreground only; returns the resulting status.
    public func requestAccess() async -> HealthInputs.MotionAuthorization {
        guard CMMotionActivityManager.isActivityAvailable() else { return Self.authorization }
        let end = Date()
        _ = await Self.query(from: end.addingTimeInterval(-60), to: end)
        return Self.authorization
    }

    private static func query(from start: Date, to end: Date) async -> MotionSummary? {
        let manager = CMMotionActivityManager()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<MotionSummary?, Never>) in
            manager.queryActivityStarting(from: start, to: end, to: .main) { activities, error in
                guard error == nil, let activities else {
                    continuation.resume(returning: nil)
                    return
                }
                var automotive = false
                var walking = false
                for activity in activities where activity.confidence != .low {
                    if activity.automotive { automotive = true }
                    if activity.walking || activity.running { walking = true }
                }
                continuation.resume(returning: MotionSummary(automotive: automotive, walking: walking, samples: activities.count))
            }
        }
        // The handler captures nothing but the continuation, so the manager must be kept alive across the await:
        // a released manager cancels its query and the handler never runs.
        withExtendedLifetime(manager) {}
        return result
    }
}
