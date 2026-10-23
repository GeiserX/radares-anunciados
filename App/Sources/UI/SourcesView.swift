// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fuentes (design 8): every source's attributions verbatim with its link and count, the database licence, the
// OpenStreetMap and DGT credits, and the app's own licence.

import RadaresCore
import SwiftUI

struct SourcesView: View {
    @Environment(AppModel.self) private var model

    private struct Source: Identifiable {
        let id: String
        let attributions: [String]
        let url: URL?
        let count: Int
    }

    private var sources: [Source] {
        guard let store = model.store else { return [] }
        // One row per source with its total count; each distinct attribution string once, the most used first.
        let groups = Dictionary(grouping: store.all, by: \.source)
        return groups.map { source, radars in
            let counts = Dictionary(grouping: radars, by: \.attribution).mapValues(\.count)
            let attributions = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
            return Source(id: source, attributions: attributions, url: radars.compactMap(\.url).first, count: radars.count)
        }
        .sorted { ($0.count, $1.id) > ($1.count, $0.id) }
    }

    var body: some View {
        List {
            Section {
                ForEach(sources) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(source.id).font(.headline)
                            Spacer()
                            Text(source.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ForEach(source.attributions, id: \.self) { Text($0).font(.subheadline) }
                        if let url = source.url {
                            Link(url.host() ?? url.absoluteString, destination: url).font(.caption)
                        }
                    }
                }
            } header: {
                Text("Fuentes del archivo")
            } footer: {
                Text("Cada radar conserva la fuente y la atribución que publica el archivo.")
            }

            Section("Licencias") {
                Text("Base de datos: Open Database License (ODbL) 1.0.")
                Text("© OpenStreetMap contributors")
                Text("Datos: DGT (CC BY 4.0)")
                Text("App: GPL-3.0-or-later")
                Link("github.com/GeiserX/radares-anunciados", destination: URL(string: "https://github.com/GeiserX/radares-anunciados")!)
                Link("Archivo de radares: radares-anunciados-ha", destination: URL(string: "https://github.com/GeiserX/radares-anunciados-ha")!)
            }
        }
        .navigationTitle("Fuentes")
    }
}
