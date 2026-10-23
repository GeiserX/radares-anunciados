// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Phrasing/Phrasing.swift.
// The sentences of design 2.7, es-ES and en, distance rounded to Thresholds.spokenDistanceStepM. Numbers are digits
// ("10 kilómetros"), so a vector expectation stays the same string on both platforms.

package io.github.geiserx.radares.core.phrasing

import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.engine.AlertEvent
import io.github.geiserx.radares.core.engine.Phrase
import io.github.geiserx.radares.core.model.Kind
import io.github.geiserx.radares.core.model.Radar
import io.github.geiserx.radares.core.model.Role
import io.github.geiserx.radares.core.roundHalfAway
import java.math.BigDecimal
import java.math.RoundingMode
import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.util.Locale
import kotlin.math.max

object Phrasing {
    fun make(event: AlertEvent, locale: Locale): Phrase = make(event, locale, null)

    /// `alsoAt` is the distance of a second radar firing on the same fix: one sentence for both (design 2.6).
    fun make(event: AlertEvent, locale: Locale, alsoAt: Double?): Phrase {
        val en = isEnglish(locale)
        val radar = event.radar ?: return Phrase(spoken = "", title = "", body = "")
        val title = kindTitle(radar, locale)
        val distance = roundedDistance(event.distance ?: 0.0)
        val direction = radar.directionText?.let { directionName(it, locale) }
        val limit = radar.maxspeed

        return when (event.kind) {
            is AlertEvent.Kind.Warn -> {
                var spoken = if (en) "$title $distance metres ahead" else "$title a $distance metros"
                if (alsoAt != null) {
                    spoken += if (en) ", and another at ${roundedDistance(alsoAt)}" else ", y otro a ${roundedDistance(alsoAt)}"
                }
                if (direction != null) spoken += if (en) ", towards $direction" else ", sentido $direction"
                spoken += "."
                if (limit != null) spoken += if (en) " Limit $limit." else " Límite $limit."
                Phrase(spoken = spoken, title = "$title ${if (en) "in" else "a"} $distance m", body = body(radar, locale))
            }
            AlertEvent.Kind.StretchEntered -> {
                val length = lengthText(radar.lengthMetres ?: 0.0, locale)
                var spoken: String
                if (radar.role == Role.MOBILE_CORRIDOR) {
                    val road = radar.road?.let { "$it, " } ?: ""
                    spoken = if (en) "Mobile radar stretch, $road$length." else "Tramo de radar móvil, $road$length."
                } else {
                    spoken = if (en) "$title $distance metres ahead, $length" else "$title a $distance metros, $length"
                    if (direction != null) spoken += if (en) ", towards $direction" else ", sentido $direction"
                    spoken += "."
                    if (limit != null) spoken += if (en) " Limit $limit." else " Límite $limit."
                }
                Phrase(spoken = spoken, title = "$title · $length", body = body(radar, locale))
            }
            is AlertEvent.Kind.StretchExited ->
                Phrase(spoken = if (en) "End of section." else "Fin de tramo.", title = if (en) "End of section" else "Fin de tramo", body = subtitle(radar, locale))
            AlertEvent.Kind.Passed, AlertEvent.Kind.DriveEnded ->
                Phrase(spoken = "", title = if (en) "Radar passed" else "Radar superado", body = subtitle(radar, locale))
        }
    }

    /// A stretch joined between its gates: the length left, not the whole length.
    fun makeJoined(event: AlertEvent, remainingMetres: Double, locale: Locale): Phrase {
        val en = isEnglish(locale)
        val radar = event.radar ?: return Phrase(spoken = "", title = "", body = "")
        val title = kindTitle(radar, locale)
        val left = lengthText(remainingMetres, locale)
        val leftText = if (en) "$left left" else "quedan $left"
        var spoken: String
        if (radar.role == Role.MOBILE_CORRIDOR) {
            val road = radar.road?.let { "$it, " } ?: ""
            spoken = "$title, $road$leftText."
        } else {
            spoken = "$title, $leftText"
            val direction = radar.directionText?.let { directionName(it, locale) }
            if (direction != null) spoken += if (en) ", towards $direction" else ", sentido $direction"
            spoken += "."
            val limit = radar.maxspeed
            if (limit != null) spoken += if (en) " Limit $limit." else " Límite $limit."
        }
        return Phrase(spoken = spoken, title = "$title · $leftText", body = body(radar, locale))
    }

    /// English only when the language code is `en`; every other language speaks Spanish.
    fun isEnglish(locale: Locale): Boolean = locale.language == "en"

    /// Distance rounded to the spoken step (half away from zero, like Swift's rounded()), never under one step.
    fun roundedDistance(metres: Double): Int {
        val step = Thresholds.spokenDistanceStepM
        return max(step.toInt(), roundHalfAway(metres / step).toInt() * step.toInt())
    }

    /// "Radar fijo", "Tramo de radar móvil"...; the card title and the first words of every sentence.
    fun kindTitle(radar: Radar, locale: Locale): String {
        val en = isEnglish(locale)
        return when (radar.kind) {
            Kind.FIXED -> if (en) "Fixed speed camera" else "Radar fijo"
            Kind.SECTION -> if (en) "Average speed camera" else "Radar de tramo"
            Kind.STRETCH -> if (radar.role == Role.MOBILE_CORRIDOR) {
                if (en) "Mobile radar stretch" else "Tramo de radar móvil"
            } else {
                if (en) "Average speed section" else "Radar de tramo"
            }
            Kind.MOBILE_ANNOUNCED -> if (en) "Announced mobile speed camera" else "Radar móvil anunciado"
            Kind.MOBILE_RECURRING -> if (en) "Usual mobile radar" else "Radar móvil habitual"
            Kind.TRAILER -> if (en) "Trailer speed camera" else "Radar en remolque"
            Kind.REPORTED -> if (en) "Unconfirmed report" else "Radar sin confirmar"
        }
    }

    /// Road and km when the feed has them ("A-2 km 202,3"), else the name.
    fun subtitle(radar: Radar, locale: Locale): String {
        val road = radar.road
        val km = radar.kmFrom
        if (road != null && km != null) return "$road km ${formatKm(km, locale)}"
        if (road != null) return road
        return radar.name
    }

    /// The notification body: subtitle plus the limit or the direction. The direction is left out when the subtitle
    /// already names it: a DGT name reads "Radar fijo A-2 km 202.3 (sentido ZARAGOZA)".
    fun body(radar: Radar, locale: Locale): String {
        val en = isEnglish(locale)
        val sub = subtitle(radar, locale)
        val parts = mutableListOf(sub)
        radar.maxspeed?.let { parts.add(if (en) "limit $it km/h" else "límite $it km/h") }
        radar.directionText?.takeUnless { sub.contains(it, ignoreCase = true) }?.let {
            parts.add(if (en) "towards ${directionName(it, locale)}" else "sentido ${directionName(it, locale)}")
        }
        return parts.joinToString(" · ")
    }

    /// "ZARAGOZA" -> "Zaragoza", "VITORIA-GASTEIZ" -> "Vitoria-Gasteiz", "L'HOSPITALET" -> "L'hospitalet".
    /// Foundation's `capitalized(with:)`, checked on macOS 2026-10-23: a letter starts a word at the start of the
    /// string and after whitespace or punctuation, but not after a letter, a digit, a combining mark, '_', ''' or '’'
    /// ("2ND ROAD" -> "2nd Road", "A-2KM" -> "A-2km", "MADRID_SUR" -> "Madrid_sur", "N.SRA.DEL" -> "N.Sra.Del").
    fun directionName(raw: String, locale: Locale): String {
        val lower = raw.lowercase(locale)
        val out = StringBuilder(lower.length)
        var wordStart = true
        var i = 0
        while (i < lower.length) {
            val cp = lower.codePointAt(i)
            if (wordStart && Character.isLetter(cp)) {
                out.appendCodePoint(Character.toTitleCase(cp))
            } else {
                out.appendCodePoint(cp)
            }
            wordStart = !continuesWord(cp)
            i += Character.charCount(cp)
        }
        return out.toString()
    }

    private fun continuesWord(cp: Int): Boolean {
        if (Character.isLetterOrDigit(cp)) return true
        if (cp == '_'.code || cp == '\''.code || cp == '’'.code) return true
        return when (Character.getType(cp)) {
            Character.NON_SPACING_MARK.toInt(), Character.COMBINING_SPACING_MARK.toInt(), Character.ENCLOSING_MARK.toInt() -> true
            else -> false
        }
    }

    /// "10 kilómetros", "1 kilómetro", "800 metros".
    fun lengthText(metres: Double, locale: Locale): String {
        val en = isEnglish(locale)
        if (metres >= 950) {
            val km = max(1, roundHalfAway(metres / 1000).toInt())
            if (km == 1) return if (en) "1 kilometre" else "1 kilómetro"
            return if (en) "$km kilometres" else "$km kilómetros"
        }
        return if (en) "${roundedDistance(metres)} metres" else "${roundedDistance(metres)} metros"
    }

    /// Foundation's NumberFormatter with 0...1 fraction digits and no grouping: it rounds half to even on the shortest
    /// decimal form of the double (4.25 -> "4,2", 4.35 -> "4,4", 0.05 -> "0", 2.55 -> "2,6"), checked on macOS.
    /// BigDecimal.valueOf takes that shortest form; DecimalFormat on the raw double would round the binary value
    /// (4.35 is 4.34999... in binary) and String.format("%.1f") rounds half up. Both would drift from iOS.
    fun formatKm(km: Double, locale: Locale): String {
        val rounded = BigDecimal.valueOf(km).setScale(1, RoundingMode.HALF_EVEN)
        val f = DecimalFormat("0.#", DecimalFormatSymbols.getInstance(locale))
        f.isGroupingUsed = false
        return f.format(rounded)
    }
}
