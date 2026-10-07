// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ajustes (design 4.4): voice on/off, the "Avisos" master switch, the feed and "Actualizar ahora",
// the log export, the alert history, the sources and the about lines.

import RadaresCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// The dispatcher keeps the voice setting across launches; this mirrors it for the toggle.
    @State private var voiceEnabled = AlertDispatcher.shared.voiceEnabled
    @AppStorage(SettingsKey.warningsEnabled) private var warningsEnabled = true
    /// "Pausar hoy" (design 3.5): mirrors the coordinator's date, read on appear.
    @State private var pausedToday = false
    @State private var pausedLoaded = false

    var body: some View {
        Form {
            Section {
                Toggle("Avisos", isOn: $warningsEnabled)
                    .onChange(of: warningsEnabled) { _, on in
                        Task { await LocationCoordinator.shared.setWarningsEnabled(on) }
                    }
                Toggle("Voz", isOn: $voiceEnabled)
                    .onChange(of: voiceEnabled) { _, on in
                        AlertDispatcher.shared.voiceEnabled = on
                    }
                Toggle("Pausar hoy", isOn: $pausedToday)
                    .onChange(of: pausedToday) { _, on in
                        guard pausedLoaded else { return }
                        Task { await LocationCoordinator.shared.setPausedToday(on) }
                    }
            } footer: {
                Text("Sin «Avisos» la app no se despierta ni usa el GPS. «Pausar hoy» ignora los despertares hasta mañana (en autobús o tren); abrir la app y «Probar aviso» siguen funcionando.")
            }
            .task {
                pausedToday = await LocationCoordinator.shared.pausedToday
                pausedLoaded = true
            }

            Section("Datos") {
                LabeledContent("Radares", value: model.meta.featureCount.formatted())
                if let fetched = model.meta.fetchedAt {
                    LabeledContent("Actualizados", value: fetched.formatted(.relative(presentation: .named)))
                }
                if let error = model.meta.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button {
                    Task { await model.refreshFeed() }
                } label: {
                    HStack {
                        Text("Actualizar ahora")
                        Spacer()
                        if model.refreshing { ProgressView() }
                    }
                }
                .disabled(model.refreshing)
            }

            Section {
                NavigationLink("Últimos avisos") { AlertsListView() }
                NavigationLink("Fuentes y licencias") { SourcesView() }
                if FileManager.default.fileExists(atPath: AppPaths.events.path) {
                    ShareLink(item: AppPaths.events) {
                        Label("Exportar registro", systemImage: "square.and.arrow.up")
                    }
                }
                Button("Repasar la introducción") { model.showOnboarding = true }
            }

            Section("Acerca de") {
                Text("Respeta siempre los límites.")
                Text("Avisa solo de posiciones publicadas de antemano; nunca detecta radares.")
                    .foregroundStyle(.secondary)
                LabeledContent("Versión", value: Self.version)
            }
        }
        .navigationTitle("Ajustes")
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
