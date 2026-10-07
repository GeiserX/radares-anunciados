// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Últimos avisos" (design 4.4): the alert rows of the last Thresholds.alertHistoryHours from the log, with time,
// kind, road, distance, speed, level and which surfaces took each one.

import RadaresCore
import SwiftUI

struct AlertsListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.recentAlerts.isEmpty {
                Text("Ningún aviso en las últimas 24 horas.").foregroundStyle(.secondary)
            }
            ForEach(model.recentAlerts, id: \.self) { entry in
                if case let .alert(id, level, distance, speed, late, _, suppressed, _, sinks, _) = entry.event {
                    AlertRow(
                        time: entry.t,
                        radar: model.store?.radar(id: id),
                        fallbackName: id,
                        level: level,
                        distance: distance,
                        speedMps: speed,
                        late: late,
                        suppressedByDirection: suppressed,
                        sinks: sinks
                    )
                }
            }
        }
        .navigationTitle("Últimos avisos")
        .refreshable { await model.reload() }
    }
}

private struct AlertRow: View {
    let time: Date
    let radar: Radar?
    let fallbackName: String
    let level: Level
    let distance: Double
    let speedMps: Double?
    let late: Bool
    let suppressedByDirection: Bool
    let sinks: [SinkOutcome]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(time.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                if let radar {
                    Text(radar.kind.label).font(.headline)
                } else {
                    Text(fallbackName).font(.headline).lineLimit(1)
                }
                Spacer()
                Text(level == .full ? "Voz" : "Solo pantalla")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(level == .full ? .green : .orange)
            }
            if let radar {
                Text(radar.road ?? radar.name).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("\(Int(distance.rounded())) m")
                if let speedMps {
                    Text("\(Int((speedMps * 3.6).rounded())) km/h")
                }
                if late { Text("tarde").foregroundStyle(.orange) }
                if suppressedByDirection { Text("sentido contrario").foregroundStyle(.secondary) }
            }
            .font(.subheadline)
            .monospacedDigit()
            if !sinks.isEmpty {
                Text(sinks.map { "\($0.sink.label): \($0.ok ? String(localized: "sí") : String(localized: "no"))" }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(sinks.allSatisfy(\.ok) ? Color.secondary : Color.red)
            }
        }
    }
}

extension SinkOutcome.Sink {
    var label: String {
        switch self {
        case .speech: String(localized: "voz")
        case .activity: String(localized: "tarjeta")
        case .notification: String(localized: "notificación")
        }
    }
}
