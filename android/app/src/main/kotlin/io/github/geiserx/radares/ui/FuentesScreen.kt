// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fuentes (SPEC 11): every source in the feed with its attributions verbatim, its link and its count; the licences;
// the Google Play services dependency; the legal line.

package io.github.geiserx.radares.ui

import android.content.Intent
import androidx.core.net.toUri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.geiserx.radares.AppGraph
import io.github.geiserx.radares.R
import io.github.geiserx.radares.core.feed.SourceNames
import io.github.geiserx.radares.core.model.Radar

/** One row per source with its total count and each distinct attribution once, the most radars first. */
data class SourceRow(val source: String, val attributions: List<String>, val url: String?, val count: Int)

fun sourceRows(radars: List<Radar>): List<SourceRow> =
    radars.groupBy { it.source }
        .map { (source, list) ->
            val attributions = list.groupingBy { it.attribution }.eachCount().entries
                .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
                .map { it.key }
            SourceRow(source, attributions, list.firstNotNullOfOrNull { it.url }, list.size)
        }
        .sortedWith(compareByDescending<SourceRow> { it.count }.thenBy { it.source })

@Composable
fun FuentesScreen(graph: AppGraph) {
    val store by graph.feed.store.collectAsState()
    val rows = remember(store) { sourceRows(store?.all.orEmpty()) }
    LazyColumn(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Header(stringResource(R.string.sources_header)) }
        items(rows, key = { it.source }) { row ->
            Column(Modifier.padding(vertical = 4.dp)) {
                Row(Modifier.fillMaxWidth()) {
                    Text(SourceNames.displayName(row.source), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                    Text(pluralStringResource(R.plurals.sources_count, row.count, row.count), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                row.attributions.forEach { Text(it, style = MaterialTheme.typography.bodyMedium) }
                row.url?.let { Link(it.toUri().host ?: it, it) }
            }
            HorizontalDivider()
        }
        item { Text(stringResource(R.string.sources_footer), style = MaterialTheme.typography.bodySmall) }
        item { Header(stringResource(R.string.sources_licences)) }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(stringResource(R.string.sources_odbl))
                Text(stringResource(R.string.sources_osm))
                Text(stringResource(R.string.sources_dgt))
                Text(stringResource(R.string.sources_app))
                Link("github.com/GeiserX/radares-anunciados", "https://github.com/GeiserX/radares-anunciados")
                Link(stringResource(R.string.sources_feed_repo), "https://github.com/GeiserX/radares-anunciados-ha")
                Text(stringResource(R.string.sources_play), style = MaterialTheme.typography.bodySmall)
                Text(stringResource(R.string.sources_legal), style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun Header(text: String) =
    Text(text, style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(top = 16.dp, bottom = 4.dp))

@Composable
private fun Link(label: String, url: String) {
    val context = LocalContext.current
    Text(
        label,
        color = MaterialTheme.colorScheme.secondary,
        modifier = Modifier.clickable { context.startActivity(Intent(Intent.ACTION_VIEW, url.toUri())) },
    )
}
