// SPDX-License-Identifier: GPL-3.0-or-later
//
// Everything the app shares, built by hand once per process: files, log, feed, voice, notifications, the drive
// state the screens read. No DI framework: constructors take what they need.

package io.github.geiserx.radares

import android.content.Context
import androidx.core.content.edit
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import io.github.geiserx.radares.core.engine.DriveSnapshot
import io.github.geiserx.radares.core.engine.PassLedgerFile
import io.github.geiserx.radares.feed.FeedClient
import io.github.geiserx.radares.feed.FeedRepository
import io.github.geiserx.radares.feed.FeedStore
import io.github.geiserx.radares.health.AppLog
import io.github.geiserx.radares.surfaces.AlertDispatcher
import io.github.geiserx.radares.surfaces.Notifier
import io.github.geiserx.radares.surfaces.Speaker
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.File

class AppGraph(val context: Context) {
    val prefs = context.getSharedPreferences("radares", Context.MODE_PRIVATE)
    val files = FeedStore(context.filesDir)
    val log = AppLog(File(context.filesDir, "events.jsonl")) {
        ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
    }
    val feed = FeedRepository(files, FeedClient(), log)
    val ledger = PassLedgerFile(File(context.filesDir, "passes.json"))
    val notifier = Notifier(context)
    val speaker: Speaker by lazy { Speaker(context) }
    val dispatcher: AlertDispatcher by lazy { AlertDispatcher(speaker, notifier, log, ::nextPassSeq) }

    /** The card the map and the car screen show; null outside a drive. */
    val snapshot = MutableStateFlow<DriveSnapshot?>(null)

    /** True while a drive is on (driving or paused). */
    val driveOn = MutableStateFlow(false)

    /** Set by the car screen's session while Android Auto shows the app (auto lane); read by the Estado row. */
    val carHostConnected = MutableStateFlow(false)

    /** `<radarId>#<passSeq>`: unique per pass, so a later pass of the same radar is a new banner. */
    fun nextPassSeq(): Int {
        val seq = prefs.getInt(KEY_PASS_SEQ, 0) + 1
        prefs.edit { putInt(KEY_PASS_SEQ, seq) }
        return seq
    }

    /** Copies the bundled snapshot on first launch (assets/feed-snapshot.*, copied from the iOS app at build time). */
    fun installSnapshotIfNeeded() {
        runCatching {
            val copied = feed.exclusive {
                files.copySnapshotIfNeeded(
                    snapshot = { context.assets.open("feed-snapshot.geojson") },
                    date = { context.assets.open("feed-snapshot.date").bufferedReader().use { it.readText() } },
                )
            }
            if (copied) log.note("snapshot copied")
        }.onFailure { log.feedFailed("snapshot copy: ${it.message}") }
    }

    companion object {
        const val KEY_PASS_SEQ = "surfaces.passSeq"
        const val KEY_ONBOARDED = "onboarded"
        const val KEY_HEALTH_NOTICE_AT = "health.noticeAt"
        const val KEY_LAST_REFRESH_RUN = "refresh.lastRun"
    }
}
