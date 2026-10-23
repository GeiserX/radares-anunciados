// SPDX-License-Identifier: GPL-3.0-or-later
//
// The voice (SPEC 8): TextToSpeech in Spanish (English when the phone is in English), as navigation guidance, with
// transient audio focus that ducks the music and is given back when the sentence ends. The voice is the one
// surface that reaches the driver in every car, whatever Android Auto does with the notification.

package io.github.geiserx.radares.surfaces

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger

/** The voice the dispatcher speaks through; a fake in tests. */
interface SpeechSink {
    /** Queues the sentence; returns null when it was handed to the engine, or the failure text. */
    fun speak(text: String): String?

    /** True when a voice in the app's language is installed and the engine is ready; null while it starts. */
    val voiceReady: Boolean?

    /** Why the voice cannot speak, when it cannot. */
    val lastError: String? get() = null

    fun shutdown() {}
}

class Speaker(context: Context, private val locale: Locale = speechLocale()) : SpeechSink {

    private val audio = context.getSystemService(AudioManager::class.java)
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()
    private val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
        .setAudioAttributes(attributes)
        .setOnAudioFocusChangeListener { }
        .build()
    private val pending = AtomicInteger(0)

    @Volatile private var ready = false
    @Volatile private var languageOk = false

    @Volatile private var error: String? = null
    @Volatile private var settled = false

    /** Sentences that arrived while the engine was still binding (0.5-3 s on a cold process): spoken once it is. */
    private val waiting = mutableListOf<String>()

    override val lastError: String? get() = error

    private val tts: TextToSpeech = TextToSpeech(context.applicationContext) { status ->
        if (status == TextToSpeech.SUCCESS) {
            ready = true
            val result = engine().setLanguage(locale)
            languageOk = result != TextToSpeech.LANG_MISSING_DATA && result != TextToSpeech.LANG_NOT_SUPPORTED
            if (!languageOk) error = "voice missing for ${locale.toLanguageTag()}"
            engine().setAudioAttributes(attributes)
            engine().setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {}
                override fun onDone(utteranceId: String?) = release()
                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String?) = release()
                override fun onError(utteranceId: String?, errorCode: Int) = release()
            })
        } else {
            error = "TextToSpeech init failed ($status)"
        }
        settle()
    }

    /** Marks the engine settled and speaks what waited for it; a failed init drops them (the notification stands). */
    private fun settle() {
        val queued = synchronized(waiting) {
            settled = true
            waiting.toList().also { waiting.clear() }
        }
        if (ready && languageOk) queued.forEach { say(it) }
    }

    private fun engine() = tts

    override val voiceReady: Boolean? get() = if (!settled) null else ready && languageOk

    override fun speak(text: String): String? {
        if (!settled) {
            synchronized(waiting) {
                if (!settled) {
                    waiting += text
                    return null
                }
            }
        }
        if (!ready) return error ?: "TextToSpeech not ready"
        if (!languageOk) return error
        return say(text)
    }

    private fun say(text: String): String? {
        val granted = audio.requestAudioFocus(focus)
        if (granted == AudioManager.AUDIOFOCUS_REQUEST_FAILED) return "audio focus refused"
        pending.incrementAndGet()
        val id = "radar-${System.nanoTime()}"
        // QUEUE_ADD: a stretch entry is queued behind a point's sentence, never cut (SPEC 4).
        val result = tts.speak(text, TextToSpeech.QUEUE_ADD, Bundle(), id)
        if (result != TextToSpeech.SUCCESS) {
            release()
            return "speak failed ($result)"
        }
        return null
    }

    private fun release() {
        if (pending.decrementAndGet() <= 0) {
            pending.set(0)
            audio.abandonAudioFocusRequest(focus)
        }
    }

    override fun shutdown() {
        tts.stop()
        tts.shutdown()
        audio.abandonAudioFocusRequest(focus)
    }

    companion object {
        /** Spanish unless the phone is in English (SPEC 6). */
        fun speechLocale(phone: Locale = Locale.getDefault()): Locale =
            if (phone.language == "en") Locale.forLanguageTag(phone.toLanguageTag()) else Locale.forLanguageTag("es-ES")
    }
}
