// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The CarPlay driving-task scene (design 4.5). It exists so the app's icon is on the CarPlay Home Screen, which is
// what lets iOS 18.4+ mirror the Time Sensitive notification of every warning on the car screen; the warning
// itself still comes from `AlertDispatcher`, with nothing to start and nothing to keep on screen. The one
// template is a `CPInformationTemplate`: the next announced radar from the engine's snapshot (kind, road or name,
// distance rounded as the voice rounds it, limit when published), "Sin radares cerca" while driving with nothing
// ahead, "Esperando a que arranque el viaje" when idle, and an Estado line when a health row is red. It refreshes
// at most once every 10 seconds (driving-task guideline 4) and is never a live countdown. The phone's scene keeps
// working with no CarPlay connected.

import CarPlay
import Foundation
import RadaresCore
import os

/// What the CarPlay screen shows, pure over the engine's snapshot and the Estado report, so a test asserts it.
struct CarPlayContent: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        var label: String
        var detail: String?
    }

    /// The app's name, the same in both languages.
    static let title = "Radares Anunciados"

    var rows: [Row]

    static func make(snapshot: DriveSnapshot?, report: [HealthItem], locale: Locale) -> CarPlayContent {
        let en = Phrasing.isEnglish(locale)
        var rows: [Row] = []
        if let snapshot, let radar = snapshot.next {
            var kind = Phrasing.kindTitle(radar, locale: locale)
            if snapshot.content.opposite { kind += en ? ", opposite direction" : ", sentido contrario" }
            rows.append(Row(label: kind, detail: Phrasing.subtitle(radar, locale: locale)))
            if let remaining = snapshot.stretch?.remainingMetres {
                // Inside a stretch the chord estimate is approximate, and the card says so (design 2.5).
                rows.append(Row(label: en ? "Remaining" : "Quedan", detail: (en ? "approx. " : "aprox. ") + Phrasing.lengthText(remaining, locale: locale)))
            } else if let distance = snapshot.distanceMetres {
                rows.append(Row(label: en ? "Distance" : "Distancia", detail: "\(Phrasing.roundedDistance(distance)) m"))
            }
            if let limit = radar.maxspeed {
                rows.append(Row(label: en ? "Limit" : "Límite", detail: "\(limit) km/h"))
            }
        } else if snapshot != nil {
            rows.append(Row(label: en ? "No radars nearby" : "Sin radares cerca", detail: nil))
        } else {
            rows.append(Row(label: en ? "Waiting for the drive to start" : "Esperando a que arranque el viaje", detail: nil))
        }
        if let failing = report.first(where: { $0.status == .fail }) {
            rows.append(Row(label: en ? "Status" : "Estado", detail: HealthTitles.localized(failing.title, locale: locale)))
        }
        return CarPlayContent(rows: rows)
    }
}

/// At most one refresh of the CarPlay data items every `minimumSeconds`: driving-task guideline 4.
struct CarPlayRefreshThrottle: Sendable {
    static let minimumSeconds: TimeInterval = 10

    private(set) var lastRefreshAt: Date?

    /// True when a refresh is due now; the time is recorded only then.
    mutating func allows(now: Date) -> Bool {
        if let last = lastRefreshAt, now.timeIntervalSince(last) < Self.minimumSeconds {
            return false
        }
        lastRefreshAt = now
        return true
    }
}

/// The scene delegate named in the Info.plist manifest for `CPTemplateApplicationSceneSessionRoleApplication`.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private let logger = Logger(subsystem: "io.github.geiserx.radares", category: "carplay")
    private var interfaceController: CPInterfaceController?
    private var template: CPInformationTemplate?
    private var refresh: Task<Void, Never>?
    private var throttle = CarPlayRefreshThrottle()
    private var shown: CarPlayContent?
    private var ticks = 0

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        // "Probar aviso": the same self-test as the Estado button, so the driver sees the warning reach the car
        // screen once; it changes no setting.
        let selfTest = CPTextButton(title: Phrasing.isEnglish(.autoupdatingCurrent) ? "Test warning" : "Probar aviso", textStyle: .normal) { _ in
            Task { @MainActor in
                guard !AppModel.shared.selfTestRunning else { return }
                await AppModel.shared.runSelfTest()
            }
        }
        let template = CPInformationTemplate(title: CarPlayContent.title, layout: .leading, items: [], actions: [selfTest])
        self.template = template
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
        logger.notice("connected")
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshIfDue(now: Date())
                try? await Task.sleep(for: .seconds(CarPlayRefreshThrottle.minimumSeconds))
            }
        }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        refresh?.cancel()
        refresh = nil
        template = nil
        self.interfaceController = nil
        shown = nil
        logger.notice("disconnected")
    }

    /// One tick: the engine's snapshot every time, the Estado report every sixth tick (a minute), and the items
    /// replaced only when something changed.
    private func refreshIfDue(now: Date) async {
        guard throttle.allows(now: now) else { return }
        let model = AppModel.shared
        if ticks % 6 == 0 {
            await model.reload()
        } else {
            await model.refreshDriveSnapshot()
        }
        ticks += 1
        let content = CarPlayContent.make(snapshot: model.driveSnapshot, report: model.report, locale: .autoupdatingCurrent)
        guard content != shown else { return }
        shown = content
        template?.items = content.rows.map { CPInformationItem(title: $0.label, detail: $0.detail) }
    }
}
