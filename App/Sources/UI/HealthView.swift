// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Estado (design 6): one row per link of the chain from healthReport(_:), each red or amber row with its button,
// the "Probar aviso" self-test, and the last background launch, the proof the wake-up chain is intact.

import RadaresCore
import SwiftUI

struct HealthView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(model.report) { item in
                    HealthRow(item: item)
                }
            } footer: {
                if let date = model.lastBackgroundLaunch {
                    Text("Último arranque en segundo plano: \(date.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Aún no hay arranques en segundo plano.")
                }
            }

            Section {
                Button {
                    Task { await model.runSelfTest() }
                } label: {
                    HStack {
                        Label("Probar aviso", systemImage: "speaker.wave.2.fill")
                        Spacer()
                        if model.selfTestRunning { ProgressView() }
                    }
                }
                .disabled(model.selfTestRunning)
                switch model.selfTest {
                case let .warned(spoken):
                    Label(spoken.isEmpty ? String(localized: "Aviso enviado") : spoken, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .silent:
                    Label("El motor no avisó: la app no funciona bien.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                case nil:
                    EmptyView()
                }
            } footer: {
                Text("Pone un radar fijo de prueba a 600 m delante y lo pasa por el mismo camino que un aviso real: voz, pantalla del coche y notificación.")
            }
        }
        .navigationTitle("Estado")
        .refreshable { await model.reload() }
    }
}

struct HealthRow: View {
    @Environment(AppModel.self) private var model
    let item: HealthItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.status.symbol)
                .foregroundStyle(item.status.color)
                .accessibilityLabel(item.status.label)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                }
                if let action = item.action, item.status != .ok {
                    Button(action.title) { model.perform(action) }
                        .buttonStyle(.borderless)
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

extension HealthItem.Action {
    var title: LocalizedStringKey {
        switch self {
        case .openSettings: "Abrir Ajustes"
        case .refreshFeed: "Actualizar ahora"
        case .showAutomationRecipe: "Ver cómo se configura"
        case .openOnboarding: "Repasar la introducción"
        }
    }
}

/// The Shortcuts automation that starts the drive when the iPhone connects to CarPlay (design 4.2, 7).
struct AutomationRecipeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Para que la pantalla del coche se encienda sola:").font(.headline)
            Text("1. Abre Atajos y ve a Automatización.")
            Text("2. Pulsa + y elige CarPlay.")
            Text("3. Marca Conecta y Ejecutar inmediatamente.")
            Text("4. Añade la acción «Iniciar aviso de radares».")
            Text("También puedes añadir el control «Conducir» al Centro de control o al botón de acción, o simplemente abrir la app antes de salir.")
                .foregroundStyle(.secondary)
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
