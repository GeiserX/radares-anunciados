// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Feed/SourceNames.swift.
// The readable name of each feed `source` key, for the Fuentes screen. The attribution under it stays verbatim.

package io.github.geiserx.radares.core.feed

object SourceNames {
    /// Every key the feed publishes, from the feed's source modules (radares-anunciados-ha `sources/`).
    val names: Map<String, String> = mapOf(
        "barcelona_multas" to "Ayuntamiento de Barcelona · multas",
        "dgt" to "DGT · radares fijos",
        "dgt_invive" to "DGT · tramos y radares móviles",
        "donostia" to "Ayuntamiento de Donostia / San Sebastián",
        "donostia_movil" to "Ayuntamiento de Donostia / San Sebastián · radar móvil",
        "euskadi" to "Euskadi · Tráfico",
        "leon" to "Ayuntamiento de León",
        "madrid" to "Ayuntamiento de Madrid",
        "madrid_multas" to "Ayuntamiento de Madrid · multas",
        "murcia" to "Ayuntamiento de Murcia",
        "navarra" to "Navarra",
        "osm" to "OpenStreetMap",
        "osm_notes" to "OpenStreetMap · notas sin confirmar",
        "salamanca" to "Ayuntamiento de Salamanca",
        "sct" to "Servei Català de Trànsit",
        "sct_remolc" to "Servei Català de Trànsit · radares remolque",
    )

    /// The readable name, or the raw key for a source this build does not know yet.
    fun displayName(source: String): String = names[source] ?: source
}
