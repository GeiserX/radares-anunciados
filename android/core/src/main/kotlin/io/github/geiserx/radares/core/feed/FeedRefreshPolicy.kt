// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Feed/FeedRefreshPolicy.swift.
// When to ask for the feed (design 5.2): foreground 6 h, background 6 h, drive start 24 h, manual always.
// Staleness never disables alerts; this only decides whether to spend a request.

package io.github.geiserx.radares.core.feed

import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.secondsSince
import java.time.Instant

object FeedRefreshPolicy {
    enum class Trigger { FOREGROUND, BACKGROUND, DRIVE_START, MANUAL }

    /// Hours the feed may be old before `trigger` asks for it again; null means always.
    fun maxAgeHours(trigger: Trigger): Double? = when (trigger) {
        Trigger.FOREGROUND -> Thresholds.refreshForegroundHours
        Trigger.BACKGROUND -> Thresholds.refreshBackgroundHours
        Trigger.DRIVE_START -> Thresholds.refreshDriveStartHours
        Trigger.MANUAL -> null
    }

    fun shouldRefresh(meta: FeedMeta, now: Instant, trigger: Trigger): Boolean {
        val hours = maxAgeHours(trigger) ?: return true
        val fetchedAt = meta.fetchedAt ?: return true
        return now.secondsSince(fetchedAt) >= hours * 3600
    }
}
