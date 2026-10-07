// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ajustes (design 4.4): voice on/off, the "Avisos" master switch, the feed and "Actualizar ahora",
// the log export, the alert history, the sources and the about lines.

import RadaresCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.voiceEnabled) private var voiceEnabled = true
    @AppStorage(SettingsKey.warningsEnabled) private var warningsEnabled = true

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
            } footer: {
                Text("Sin «Avisos» la app no se despierta ni usa el GPS.")
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
