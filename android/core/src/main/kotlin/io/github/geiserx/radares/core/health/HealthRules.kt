// SPDX-License-Identifier: GPL-3.0-or-later
// The platform-neutral part of Sources/RadaresCore/Health/HealthReport.swift and HealthInputs.swift: the Status of a
// row and the two rules that read only the core's own data (the feed age and the last drive). The iOS rows read iOS
// permissions and are not ported; the Android app builds its own rows from these and from Android's permissions.

package io.github.geiserx.radares.core.health

import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.secondsSince
import java.time.Instant

/// One row of the Estado screen.
data class HealthItem(val status: Status, val title: String, val detail: String, val action: Action? = null) {
    enum class Status { OK, WARN, FAIL }
    enum class Action { OPEN_SETTINGS, REFRESH_FEED, OPEN_ONBOARDING }
}

object HealthRules {
    /// "Datos": red with no feed, older than feedStaleFailDays, too few features or feedFailStreak failures in a row;
    /// amber older than feedStaleWarnDays; else ok. Same order as feedRow in HealthReport.swift.
    fun feed(fetchedAt: Instant?, featureCount: Int, consecutiveFailures: Int, now: Instant, english: Boolean = false): HealthItem {
        val title = if (english) "Data" else "Datos"
        fun l(es: String, en: String) = if (english) en else es
        if (fetchedAt == null) return HealthItem(HealthItem.Status.FAIL, title, l("Sin datos descargados", "No data downloaded"), HealthItem.Action.REFRESH_FEED)
        val age = now.secondsSince(fetchedAt) / 86_400
        val days = age.toInt()
        if (age > Thresholds.feedStaleFailDays) {
            return HealthItem(HealthItem.Status.FAIL, title, l("Datos de hace $days días", "Data from $days days ago"), HealthItem.Action.REFRESH_FEED)
        }
        if (featureCount < Thresholds.feedMinFeatures) {
            return HealthItem(
                HealthItem.Status.FAIL, title,
                l("Solo $featureCount radares, se esperan al menos ${Thresholds.feedMinFeatures}", "Only $featureCount radars, at least ${Thresholds.feedMinFeatures} expected"),
                HealthItem.Action.REFRESH_FEED,
            )
        }
        if (consecutiveFailures >= Thresholds.feedFailStreak) {
            return HealthItem(HealthItem.Status.FAIL, title, l("$consecutiveFailures descargas seguidas fallidas", "$consecutiveFailures downloads failed in a row"), HealthItem.Action.REFRESH_FEED)
        }
        if (age > Thresholds.feedStaleWarnDays) {
            return HealthItem(HealthItem.Status.WARN, title, l("Datos de hace $days días", "Data from $days days ago"), HealthItem.Action.REFRESH_FEED)
        }
        return HealthItem(HealthItem.Status.OK, title, l("$featureCount radares, ${ageText(fetchedAt, now, english)}", "$featureCount radars, ${ageText(fetchedAt, now, english)}"))
    }

    /// "Último viaje": amber when fixes came more than maxGapWarnSeconds apart (the system held the app back) or a
    /// warning was late; ok otherwise, and ok before the first drive.
    fun lastDrive(maxGapSeconds: Double?, hadLateAlert: Boolean, english: Boolean = false): HealthItem {
        val title = if (english) "Last drive" else "Último viaje"
        fun l(es: String, en: String) = if (english) en else es
        val gap = maxGapSeconds ?: return HealthItem(HealthItem.Status.OK, title, l("Sin viajes todavía", "No drives yet"))
        val s = gap.toInt()
        if (gap > Thresholds.maxGapWarnSeconds) {
            return HealthItem(HealthItem.Status.WARN, title, l("Hueco de $s s entre posiciones: el sistema frenó la app", "A $s s gap between positions: the system held the app back"))
        }
        if (hadLateAlert) {
            return HealthItem(HealthItem.Status.WARN, title, l("Un aviso llegó tarde (despertar tardío o GPS frío)", "A warning came late (late wake-up or cold GPS)"))
        }
        return HealthItem(HealthItem.Status.OK, title, l("Posiciones cada $s s como máximo, sin avisos tardíos", "Positions at most $s s apart, no late warnings"))
    }

    fun ageText(from: Instant, now: Instant, english: Boolean): String {
        val hours = now.secondsSince(from) / 3600
        if (hours < 1) return if (english) "less than an hour ago" else "hace menos de una hora"
        if (hours < 48) return if (english) "${hours.toInt()} h ago" else "hace ${hours.toInt()} h"
        return if (english) "${(hours / 24).toInt()} days ago" else "hace ${(hours / 24).toInt()} días"
    }
}
