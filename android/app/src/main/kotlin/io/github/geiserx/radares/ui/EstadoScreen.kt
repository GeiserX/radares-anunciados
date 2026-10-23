// SPDX-License-Identifier: GPL-3.0-or-later
//
// Estado: the twelve rows (ok / amber / red, a fix button on the ones the driver can fix), and four actions:
// Actualizar datos, Autocomprobación, Exportar registro (the share sheet), Borrar registro.

package io.github.geiserx.radares.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import io.github.geiserx.radares.AppGraph
import io.github.geiserx.radares.BuildConfig
import io.github.geiserx.radares.R
import io.github.geiserx.radares.health.HealthAction
import io.github.geiserx.radares.health.HealthCollector
import io.github.geiserx.radares.health.HealthRow
import io.github.geiserx.radares.health.HealthStatus
import io.github.geiserx.radares.health.SelfTest
import io.github.geiserx.radares.health.healthReport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

@Composable
fun EstadoScreen(graph: AppGraph, onReonboard: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var rows by remember { mutableStateOf<List<HealthRow>>(emptyList()) }
    var reload by remember { mutableIntStateOf(0) }
    val english = LocalConfiguration.current.locales[0].language == "en"
    val refreshing = stringResource(R.string.status_refreshing)
    val selfTestRunning = stringResource(R.string.status_self_test_running)
    val wiped = stringResource(R.string.status_wiped)

    LaunchedEffect(reload) {
        while (true) {
            rows = withContext(Dispatchers.IO) { healthReport(HealthCollector(context, graph).collect(), english) }
            delay(5_000)
        }
    }

    fun refreshFeed() {
        Toast.makeText(context, refreshing, Toast.LENGTH_SHORT).show()
        scope.launch {
            withContext(Dispatchers.IO) { graph.feed.refresh() }
            reload++
        }
    }

    LazyColumn(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items(rows, key = { it.id }) { row ->
            HealthRowView(row) {
                when (row.action) {
                    HealthAction.OPEN_SETTINGS -> openAppSettings(context)
                    HealthAction.NOTIFICATION_SETTINGS -> context.startActivity(
                        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName),
                    )
                    HealthAction.REFRESH_FEED -> refreshFeed()
                    HealthAction.OPEN_ONBOARDING -> onReonboard()
                    null -> Unit
                }
            }
            HorizontalDivider()
        }
        item {
            Column(Modifier.padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = ::refreshFeed, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.status_refresh)) }
                Button(onClick = {
                    Toast.makeText(context, selfTestRunning, Toast.LENGTH_LONG).show()
                    scope.launch { SelfTest.run(graph.dispatcher, hold = { delay(4_000) }) }
                }, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.status_self_test)) }
                OutlinedButton(onClick = { exportLog(context, graph) }, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.status_export))
                }
                OutlinedButton(onClick = {
                    graph.log.wipe()
                    Toast.makeText(context, wiped, Toast.LENGTH_SHORT).show()
                }, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.status_wipe)) }
                Text(
                    stringResource(R.string.status_version, BuildConfig.VERSION_NAME),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun HealthRowView(row: HealthRow, onAction: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        val color = when (row.status) {
            HealthStatus.OK -> Green
            HealthStatus.AMBER -> Amber
            HealthStatus.RED -> Red
        }
        Box(Modifier.size(12.dp).background(color, CircleShape))
        Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
            Text(row.title, style = MaterialTheme.typography.titleMedium)
            Text(row.detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (row.action != null && row.status != HealthStatus.OK) {
            TextButton(onClick = onAction) { Text(stringResource(R.string.status_fix)) }
        }
    }
}

private fun openAppSettings(context: Context) = context.startActivity(
    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)),
)

/** The log as a file through the share sheet (it can be hundreds of KB, too big for an intent extra). */
private fun exportLog(context: Context, graph: AppGraph) {
    val data = graph.log.export() ?: ByteArray(0)
    val dir = File(context.cacheDir, "export").apply { mkdirs() }
    val file = File(dir, "radares-events.jsonl").apply { writeBytes(data) }
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.export", file)
    val send = Intent(Intent.ACTION_SEND)
        .setType("application/jsonl")
        .putExtra(Intent.EXTRA_STREAM, uri)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(send, null))
}
