// SPDX-License-Identifier: GPL-3.0-or-later
//
// Every AlertEvent goes through here to the voice and the notification, the rules of the iOS dispatcher
// (App/Sources/Surfaces/AlertDispatcher.swift):
//   Warn(FULL), StretchEntered   voice + the high-priority notification; one `alert` log row with the sink outcomes
//   Warn(VISUAL)                 the notification without the voice (opposite flow, pacing gap); an `alert` row
//   Passed                       that radar's notification is removed
//   StretchExited                "Fin de tramo" spoken, only when the core phrased it (the far-gate exit)
//   DriveEnded                   nothing here
// A radar of the opposite flow posts silently with ", sentido contrario" in the title. Nothing has to be opened or
// left on screen.

package io.github.geiserx.radares.surfaces

import io.github.geiserx.radares.core.engine.AlertEvent
import io.github.geiserx.radares.core.engine.Level
import io.github.geiserx.radares.core.engine.Phrase
import io.github.geiserx.radares.core.model.Fix
import io.github.geiserx.radares.core.phrasing.Phrasing
import io.github.geiserx.radares.drive.EventSink
import io.github.geiserx.radares.health.AppEvents
import java.util.Locale

class AlertDispatcher(
    private val speaker: SpeechSink,
    private val poster: WarningPoster,
    private val events: AppEvents,
    private val nextPassSeq: () -> Int,
    private val locale: Locale = Locale.getDefault(),
) : EventSink {

    override fun handle(event: AlertEvent, fix: Fix?) {
        when (val kind = event.kind) {
            is AlertEvent.Kind.Warn -> alert(event, kind.level, fix)
            // The level the core meant: an entry with no sentence is a visual row, like a paced point.
            AlertEvent.Kind.StretchEntered -> alert(event, if (event.phrase == null) Level.VISUAL else Level.FULL, fix)
            AlertEvent.Kind.Passed -> event.radar?.let { poster.removeRadar(it.id) }
            is AlertEvent.Kind.StretchExited -> event.phrase?.takeIf { it.spoken.isNotEmpty() }?.let { phrase ->
                val error = speaker.speak(phrase.spoken)
                events.speech(phrase.spoken, error)
            }
            AlertEvent.Kind.DriveEnded -> Unit
        }
    }

    private fun alert(event: AlertEvent, level: Level, fix: Fix?) {
        val phrase = if (level == Level.FULL) event.phrase else null
        val sinks = mutableListOf<AppEvents.Sink>()
        // The banner first: a slow voice engine never holds it back.
        notificationPhrase(event, level, locale)?.let { text ->
            val tag = "${event.radar?.id ?: "radar"}#${nextPassSeq()}"
            val error = poster.post(NotificationText(text.title, text.body), tag, silent = event.content.opposite)
            events.notificationPosted(tag, error)
            sinks += AppEvents.Sink("notification", error == null, error)
        }
        phrase?.takeIf { it.spoken.isNotEmpty() }?.let {
            val error = speaker.speak(it.spoken)
            events.speech(it.spoken, error)
            sinks += AppEvents.Sink("speech", error == null, error)
        }
        val spokenOk = sinks.any { it.sink == "speech" && it.ok }
        events.alert(event, level, fix, sinks, spoken = if (spokenOk) phrase?.spoken else null)
    }

    companion object {
        /**
         * The notification's text. A FULL warning carries the core's phrase. A VISUAL one has no sentence (the engine
         * phrases only what is spoken), so its title and body come from the same Phrasing rules, with
         * ", sentido contrario" in the title when the radar is for the other carriageway. Null when there is no radar.
         */
        fun notificationPhrase(event: AlertEvent, level: Level, locale: Locale): Phrase? {
            if (level == Level.FULL) event.phrase?.let { return it }
            if (event.radar == null) return null
            val made = Phrasing.make(event, locale)
            if (made.title.isEmpty()) return null
            val suffix = if (Phrasing.isEnglish(locale)) ", opposite direction" else ", sentido contrario"
            return Phrase(spoken = "", title = if (event.content.opposite) made.title + suffix else made.title, body = made.body)
        }
    }
}
