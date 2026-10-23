// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The readable name of each feed `source` key, for the Fuentes screen. The attribution under it stays verbatim.

public enum SourceNames {
    /// Every key the feed publishes, from the feed's source modules (radares-anunciados-ha `sources/`).
    public static let names: [String: String] = [
        "barcelona_multas": "Ayuntamiento de Barcelona · multas",
        "dgt": "DGT · radares fijos",
        "dgt_invive": "DGT · tramos y radares móviles",
        "donostia": "Ayuntamiento de Donostia / San Sebastián",
        "donostia_movil": "Ayuntamiento de Donostia / San Sebastián · radar móvil",
        "euskadi": "Euskadi · Tráfico",
        "leon": "Ayuntamiento de León",
        "madrid": "Ayuntamiento de Madrid",
        "madrid_multas": "Ayuntamiento de Madrid · multas",
        "murcia": "Ayuntamiento de Murcia",
        "navarra": "Navarra",
        "osm": "OpenStreetMap",
        "osm_notes": "OpenStreetMap · notas sin confirmar",
        "salamanca": "Ayuntamiento de Salamanca",
        "sct": "Servei Català de Trànsit",
        "sct_remolc": "Servei Català de Trànsit · radares remolque",
    ]

    /// The readable name, or the raw key for a source this build does not know yet.
    public static func displayName(_ source: String) -> String {
        names[source] ?? source
    }
}
