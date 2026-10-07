// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The pieces of the app's launch path and health collection that run without the system: the location launch key
// as the one background-wake rule, and the session diagnostics merged with what the authorization status proves.

import RadaresCore
import UIKit
import XCTest
@testable import RadaresAnunciados

final class HealthMonitorTests: XCTestCase {
    func testOnlyTheLocationLaunchKeyMakesABackgroundWake() {
        XCTAssertFalse(AppDelegate.launchedForLocation(nil))
        XCTAssertFalse(AppDelegate.launchedForLocation([:]))
        XCTAssertFalse(AppDelegate.launchedForLocation([UIApplication.LaunchOptionsKey(rawValue: "UIApplicationLaunchOptionsSourceApplicationKey"): "x"]))
        XCTAssertTrue(AppDelegate.launchedForLocation([UIApplication.LaunchOptionsKey(rawValue: "UIApplicationLaunchOptionsLocationKey"): true]))
    }

    func testStatusDerivedFlagsStandInUntilTheSessionReports() {
        let quiet = HealthInputs.SessionDiagnostics()
        let whenInUse = HealthMonitor.merge(quiet, authorization: .whenInUse, precise: true, servicesEnabled: true)
        XCTAssertTrue(whenInUse.alwaysAuthorizationDenied)
        XCTAssertFalse(whenInUse.authorizationDenied)
        XCTAssertFalse(whenInUse.fullAccuracyDenied)

        let always = HealthMonitor.merge(quiet, authorization: .always, precise: true, servicesEnabled: true)
        XCTAssertEqual(always, quiet, "nothing to add when Always is granted and the session is quiet")

        let reduced = HealthMonitor.merge(quiet, authorization: .always, precise: false, servicesEnabled: false)
        XCTAssertTrue(reduced.fullAccuracyDenied)
        XCTAssertTrue(reduced.authorizationDeniedGlobally)

        var reported = HealthInputs.SessionDiagnostics()
        reported.insufficientlyInUse = true
        let kept = HealthMonitor.merge(reported, authorization: .always, precise: true, servicesEnabled: true)
        XCTAssertTrue(kept.insufficientlyInUse, "a flag the session reported is never cleared by the status")
    }
}
