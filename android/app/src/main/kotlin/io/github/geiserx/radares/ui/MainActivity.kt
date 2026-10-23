// SPDX-License-Identifier: GPL-3.0-or-later
//
// The one activity: onboarding the first time, then three tabs (Mapa, Estado, Fuentes). Opening it is never
// needed to drive; it is where the driver reads the map, the health rows and the sources.

package io.github.geiserx.radares.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.core.content.edit
import io.github.geiserx.radares.AppGraph
import io.github.geiserx.radares.R
import io.github.geiserx.radares.RadaresApp
import io.github.geiserx.radares.core.feed.FeedRefreshPolicy
import io.github.geiserx.radares.drive.WakeUps
import java.util.concurrent.Executors

class MainActivity : ComponentActivity() {
    private val io = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val graph = RadaresApp.graph(this)
        setContent {
            RadaresTheme {
                var onboarded by remember { mutableStateOf(graph.prefs.getBoolean(AppGraph.KEY_ONBOARDED, false)) }
                if (!onboarded) {
                    Onboarding(onDone = {
                        graph.prefs.edit { putBoolean(AppGraph.KEY_ONBOARDED, true) }
                        WakeUps.register(this)
                        onboarded = true
                    })
                } else {
                    Tabs(graph, onReonboard = {
                        graph.prefs.edit { putBoolean(AppGraph.KEY_ONBOARDED, false) }
                        onboarded = false
                    })
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        val graph = RadaresApp.graph(this)
        // A permission granted in Settings since the last visit: register the wake-ups again.
        WakeUps.register(this)
        io.execute {
            graph.installSnapshotIfNeeded()
            graph.feed.loadIfNeeded()
            graph.feed.refreshIfNeeded(FeedRefreshPolicy.Trigger.FOREGROUND)
        }
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }
}

@Composable
private fun Tabs(graph: AppGraph, onReonboard: () -> Unit) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    val tabs = listOf(
        R.string.tab_map to R.drawable.ic_tab_map,
        R.string.tab_status to R.drawable.ic_tab_status,
        R.string.tab_sources to R.drawable.ic_tab_sources,
    )
    Scaffold(
        bottomBar = {
            NavigationBar {
                tabs.forEachIndexed { i, (label, icon) ->
                    NavigationBarItem(
                        selected = tab == i,
                        onClick = { tab = i },
                        icon = { Icon(painterResource(icon), contentDescription = null) },
                        label = { Text(stringResource(label)) },
                    )
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when (tab) {
                0 -> MapScreen(graph)
                1 -> EstadoScreen(graph, onReonboard)
                else -> FuentesScreen(graph)
            }
        }
    }
}
