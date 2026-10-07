// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Each Estado rule with a positive and a negative input (design 6).

import XCTest
@testable import RadaresCore

final class HealthReportTests: XCTestCase {
    /// Inputs that make every row ok, so each test flips one thing.
    func healthy() -> HealthInputs {
        var d = HealthInputs.SessionDiagnostics()
        d.serviceSessionRequired = false
        return HealthInputs(
            now: t0,
            locationAuthorization: .always,
            preciseLocation: true,
            sessionDiagnostics: d,
            sessionTaken: true,
            backgroundLaunches: 3,
            intentLaunches: 1,
            drives: 4,
            lastEventWasWillTerminate: false,
            parkedFenceFlags: [],
            parkedFenceIdentifierPresent: true,
            slcStarted: true,
            lastSlcDelivery: t0.addingTimeInterval(-3600),
            lastDriveEnded: t0.addingTimeInterval(-7200),
            feedFetchedAt: t0.addingTimeInterval(-3600),
            feedFeatureCount: 4500,
            feedConsecutiveFailures: 0,
            backgroundRefresh: .available,
            pendingRefreshRequests: 1,
            lastBgTaskRan: t0.addingTimeInterval(-86_400),
            lowPowerMode: false,
            notificationAuthorization: .authorized,
            timeSensitiveSetting: .enabled,
            activitiesEnabled: true,
            lastActivityStarted: t0.addingTimeInterval(-7000),
            lastDriveStarted: t0.addingTimeInterval(-7100),
            intentStartedDriveLogged: true,
            motionAuthorization: .authorized,
            lastSpeechSetActiveError: nil,
            spanishVoiceAvailable: true,
            protectionVerified: true,
            lastDriveMaxGapSeconds: 2,
            lastDriveHadLateAlert: false
        )
    }

    func row(_ title: String, _ inputs: HealthInputs) -> HealthItem {
        healthReport(inputs).first { $0.title == title }!
    }

    func testAHealthyPhoneIsAllGreenWithThirteenRows() {
        let report = healthReport(healthy())
        XCTAssertEqual(report.count, 13)
        XCTAssertEqual(report.filter { $0.status != .ok }.map(\.title), [])
        XCTAssertEqual(report.map(\.title), [
            HealthTitles.location, HealthTitles.session, HealthTitles.launches, HealthTitles.fence, HealthTitles.slc,
            HealthTitles.feed, HealthTitles.refresh, HealthTitles.notifications, HealthTitles.activity, HealthTitles.motion,
            HealthTitles.voice, HealthTitles.files, HealthTitles.lastDrive,
        ])
    }

    func testLocation() {
        var i = healthy()
        XCTAssertEqual(row(HealthTitles.location, i).status, .ok)
        i.locationAuthorization = .whenInUse
        XCTAssertEqual(row(HealthTitles.location, i).status, .warn)
        XCTAssertEqual(row(HealthTitles.location, i).action, .openSettings)
        i.locationAuthorization = .denied
        XCTAssertEqual(row(HealthTitles.location, i).status, .fail)
        i.locationAuthorization = .always
        i.preciseLocation = false
        XCTAssertEqual(row(HealthTitles.location, i).status, .fail)
    }

    func testSession() {
        var i = healthy()
        XCTAssertEqual(row(HealthTitles.session, i).status, .ok)
        i.sessionTaken = false
        XCTAssertEqual(row(HealthTitles.session, i).status, .warn)
        i.sessionTaken = true
        i.sessionDiagnostics.alwaysAuthorizationDenied = true
        let r = row(HealthTitles.session, i)
        XCTAssertEqual(r.status, .fail)
        XCTAssertTrue(r.detail.contains("Siempre"))
        var j = healthy()
        j.sessionDiagnostics.fullAccuracyDenied = true
        XCTAssertEqual(row(HealthTitles.session, j).status, .fail)
        var k = healthy()
        k.sessionDiagnostics.authorizationRequestInProgress = true
        XCTAssertEqual(row(HealthTitles.session, k).status, .ok, "a request in progress is not a failure")
    }

    func testBackgroundLaunches() {
        var i = healthy()
        XCTAssertEqual(row(HealthTitles.launches, i).status, .ok)
        i.backgroundLaunches = 0
        i.intentLaunches = 0
        XCTAssertEqual(row(HealthTitles.launches, i).status, .warn)
        i.drives = 0
        XCTAssertEqual(row(HealthTitles.launches, i).status, .ok, "no drives, nothing to expect")
        i.lastEventWasWillTerminate = true
        let r = row(HealthTitles.launches, i)
        XCTAssertEqual(r.status, .fail)
        XCTAssertTrue(r.detail.contains("selector"))
    }

    func testParkedFence() {
        var i = healthy()
        XCTAssertEqual(row(HealthTitles.fence, i).status, .ok)
        i.parkedFenceIdentifierPresent = false
        XCTAssertEqual(row(HealthTitles.fence, i).status, .warn)
        i.parkedFenceIdentifierPresent = true
        i.parkedFenceFlags = ["conditionLimitExceeded"]
        XCTAssertEqual(row(HealthTitles.fence, i).status, .fail)
        i.parkedFenceFlags = ["accuracyLimited"]
        XCTAssertEqual(row(HealthTitles.fence, i).status, .ok, "other flags are logged, not red")
    }

    func testSignificantChange() {
        var i = healthy()
        XCTAssertEqual(row(HealthTitles.slc, i).status, .ok)
        i.slcStarted = false
        XCTAssertEqual(row(HealthTitles.slc, i).status, .fail)
        i.slcStarted = true
        i.lastSlcDelivery = t0.addingTimeInterval(-15 * 86_400)
        XCTAssertEqual(row(HealthTitles.slc, i).status, .fail, "15 days silent while drives happened")
        i.lastDriveEnded = t0.addingTimeInterval(-20 * 86_400)
        XCTAssertEqual(row(HealthTitles.slc, i).status, .ok, "no recent drive, no expectation")
        i.lastSlcDelivery = nil
        XCTAssertEqual(row(HealthTitles.slc, i).status, .ok)
    }

    func testFeed() {
        var i = healthy()
        XCTAssertEqual(row(HealthTitles.feed, i).status, .ok)
        i.feedFetchedAt = t0.addingTimeInterval(-3 * 86_400)
        XCTAssertEqual(row(HealthTitles.feed, i).status, .warn)
        i.feedFetchedAt = t0.addingTimeInterval(-8 * 86_400)
        XCTAssertEqual(row(HealthTitles.feed, i).status, .fail)
        XCTAssertEqual(row(HealthTitles.feed, i).action, .refreshFeed)
        i = healthy()
        i.feedFeatureCount = 1999
        XCTAssertEqual(row(HealthTitles.feed, i).status, .fail)
        i = healthy()
        i.feedConsecutiveFailures = 3
        XCTAssertEqual(row(HealthTitles.feed, i).status, .fail)
        i.feedConsecutiveFailures = 2
        XCTAssertEqual(row(HealthTitles.feed, i).status, .ok)
        i.feedFetchedAt = nil
        XCTAssertEqual(row(HealthTitles.feed, i).status, .fail)
    }

    func testBackgroundRefresh() {
        var i = healthy()
        XCTAssertEqual(row(HealthTitles.refresh, i).status, .ok)
        i.backgroundRefresh = .denied
        XCTAssertEqual(row(HealthTitles.refresh, i).status, .fail)
        i.backgroundRefresh = .restricted
        XCTAssertEqual(row(HealthTitles.refresh, i).status, .warn)
        i = healthy()
        i.lowPowerMode = true
        XCTAssertEqual(row(HealthTitles.refresh, i).status, .warn)
        i = healthy()
        i.lastBgTaskRan = t0.addingTimeInterval(-4 * 86_400)
        XCTAssertEqual(row(HealthTitles.refresh, i).status, .warn)
        i.lastBgTaskRan = nil
        XCTAssertEqual(row(HealthTitles.refresh, i).status, .warn)
    }

    func testNotifications() {
        var i = healthy()
        XCTAssertEqual(row(HealthTitles.notifications, i).status, .ok)
        i.timeSensitiveSetting = .disabled
        XCTAssertEqual(row(HealthTitles.notifications, i).status, .warn)
        i.notificationAuthorization = .denied
        XCTAssertEqual(row(HealthTitles.notifications, i).status, .fail)
        i.notificationAuthorization = .provisional
        XCTAssertEqual(row(HealthTitles.notifications, i).status, .fail, "provisional is quiet delivery, not what the driver needs")
    }

    func testCarScreen() {
        var i = healthy()
        XCTAssertEqual(row(HealthTitles.activity, i).status, .ok)
        i.activitiesEnabled = false
        XCTAssertEqual(row(HealthTitles.activity, i).status, .fail)
        i = healthy()
        i.intentStartedDriveLogged = false
        let r = row(HealthTitles.activity, i)
        XCTAssertEqual(r.status, .warn)
        XCTAssertEqual(r.detail, "Automatización no probada")
        XCTAssertEqual(r.action, .showAutomationRecipe)
        i = healthy()
        i.lastActivityStarted = t0.addingTimeInterval(-90_000)
        XCTAssertEqual(row(HealthTitles.activity, i).status, .warn, "the last drive had no card")
    }

    func testMotion() {
        var i = healthy()
        XCTAssertEqual(row(HealthTitles.motion, i).status, .ok)
        i.motionAuthorization = .denied
        XCTAssertEqual(row(HealthTitles.motion, i).status, .warn)
        i.motionAuthorization = .notDetermined
        XCTAssertEqual(row(HealthTitles.motion, i).status, .warn)
        XCTAssertEqual(row(HealthTitles.motion, i).action, .openOnboarding)
    }

    func testVoice() {
        var i = healthy()
        XCTAssertEqual(row(HealthTitles.voice, i).status, .ok)
        i.lastSpeechSetActiveError = "cannotStartPlaying"
        let r = row(HealthTitles.voice, i)
        XCTAssertEqual(r.status, .fail)
        XCTAssertTrue(r.detail.contains("cannotStartPlaying"))
        i = healthy()
        i.spanishVoiceAvailable = false
        XCTAssertEqual(row(HealthTitles.voice, i).status, .fail)
    }

    func testFiles() {
        var i = healthy()
        XCTAssertEqual(row(HealthTitles.files, i).status, .ok)
        i.protectionVerified = nil
        XCTAssertEqual(row(HealthTitles.files, i).status, .warn)
        i.protectionVerified = false
        XCTAssertEqual(row(HealthTitles.files, i).status, .fail)
    }

    func testLastDrive() {
        var i = healthy()
        XCTAssertEqual(row(HealthTitles.lastDrive, i).status, .ok)
        i.lastDriveMaxGapSeconds = 11
        XCTAssertEqual(row(HealthTitles.lastDrive, i).status, .warn)
        i.lastDriveMaxGapSeconds = 10
        XCTAssertEqual(row(HealthTitles.lastDrive, i).status, .ok)
        i.lastDriveHadLateAlert = true
        XCTAssertEqual(row(HealthTitles.lastDrive, i).status, .warn)
        i.lastDriveMaxGapSeconds = nil
        XCTAssertEqual(row(HealthTitles.lastDrive, i).status, .ok, "no drive yet")
    }
}
