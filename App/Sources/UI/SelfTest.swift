// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Probar aviso" (design 6): a synthetic fixed radar Thresholds.selfTestDistanceM ahead on the current heading (due
// north when stopped or unknown), driven through the real AlertEngine and the real AlertDispatcher. The engine
// decides from fixes exactly as on the road, so an engine or phrasing regression fails this test for the same
// reason a real warning would. It runs in the foreground, so the Live Activity is started for it.

import CoreLocation
import Foundation
import RadaresCore
import os

@MainActor
enum SelfTest {
    enum Outcome: Equatable {
        /// The engine warned and the dispatcher took the event; the spoken sentence is shown.
        case warned(spoken: String)
        /// The engine stayed silent on a radar it must warn about.
        case silent
    }

    /// Speed of the synthetic approach, m/s (90 km/h): warn distance 625 m, so the radar is in range at 600 m.
    static let speedMps: Double = 25
    /// Metres between synthetic fixes (one second apart at speedMps).
    static let stepM: Double = 25

    static func run(now: Date = Date()) async -> Outcome {
        let logger = Logger(subsystem: "io.github.geiserx.radares", category: "selftest")
        let location = CLLocationManager().location
        let here = location.map { Coordinate($0.coordinate) } ?? Coordinate(latitude: 40.4168, longitude: -3.7038)
        let heading: Double = if let location, location.course >= 0, location.speed >= Thresholds.courseMinSpeedMps {
            location.course
        } else {
            0
        }

        let radar = Radar(
            id: "selftest-\(Int(now.timeIntervalSince1970))",
            kind: .fixed,
            role: .point,
            start: destination(from: here, bearing: heading, metres: Thresholds.selfTestDistanceM),
            name: "Prueba",
            source: "selftest",
            attribution: "Prueba de la app"
        )
        let engine = AlertEngine(store: RadarStore(radars: [radar]), ledger: PassLedger(), now: { now })

        var startedActivity = false
        if !LaunchFlags.noLiveActivity, DriveActivityController.shared.current == nil {
            do {
                try DriveActivityController.shared.start(content: .watching(at: now))
                startedActivity = true
            } catch {
                logger.error("Live Activity: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Approach from 200 m behind the phone up to the phone: the radar goes from 800 m to 600 m ahead.
        let behind = [200.0, 175, 150, 125, 100, 75, 50, 25, 0]
        var warning: AlertEvent?
        for (index, back) in behind.enumerated() {
            let fix = Fix(
                coordinate: destination(from: here, bearing: heading + 180, metres: back),
                timestamp: now.addingTimeInterval(Double(index - behind.count + 1)),
                speed: speedMps,
                course: heading,
                horizontalAccuracy: 5
            )
            let events = engine.ingest(fix)
            if let warn = events.first(where: { if case .warn(.full) = $0.kind { true } else { false } }) {
                warning = warn
                await AlertDispatcher.shared.handle(warn)
                break
            }
        }

        if startedActivity {
            // A test card should not outlive the test when no drive is running.
            Task {
                try? await Task.sleep(for: .seconds(30))
                if await LocationCoordinator.shared.state == .idle {
                    await DriveActivityController.shared.end()
                }
            }
        }
        guard let warning else {
            logger.error("self-test: the engine did not warn")
            return .silent
        }
        return .warned(spoken: warning.phrase?.spoken ?? "")
    }

    /// The point `metres` away from `start` on `bearing` (degrees), on a sphere: plenty for a few hundred metres.
    static func destination(from start: Coordinate, bearing: Double, metres: Double) -> Coordinate {
        let radius = 6_371_008.8
        let delta = metres / radius
        let theta = bearing * .pi / 180
        let lat1 = start.latitude * .pi / 180
        let lon1 = start.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(delta) + cos(lat1) * sin(delta) * cos(theta))
        let lon2 = lon1 + atan2(sin(theta) * sin(delta) * cos(lat1), cos(delta) - sin(lat1) * sin(lat2))
        return Coordinate(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }
}
