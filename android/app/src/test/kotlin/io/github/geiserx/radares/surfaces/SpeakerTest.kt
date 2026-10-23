// SPDX-License-Identifier: GPL-3.0-or-later
//
// A warning that fires before TextToSpeech has bound (an IN_VEHICLE wake starts the drive at once, the first fix can
// warn within a second) is spoken once the engine is ready, not dropped.

package io.github.geiserx.radares.surfaces

import android.content.Context
import android.os.Looper
import android.speech.tts.TextToSpeech
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowTextToSpeech
import java.util.Locale

@RunWith(RobolectricTestRunner::class)
class SpeakerTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val spanish = Locale.forLanguageTag("es-ES")

    @After
    fun tearDown() = ShadowTextToSpeech.reset()

    private fun initialise(speaker: Speaker, status: Int) {
        shadowOf(Looper.getMainLooper()).idle()
        if (speaker.voiceReady == null) {
            shadowOf(ShadowTextToSpeech.getLastTextToSpeechInstance()).onInitListener.onInit(status)
        }
    }

    @Test
    fun aSentenceBeforeInitIsSpokenOnceTheEngineIsReady() {
        ShadowTextToSpeech.addLanguageAvailability(spanish)
        val speaker = Speaker(context, spanish)
        assertNull("queued, not refused", speaker.speak("Radar fijo a 800 metros."))
        initialise(speaker, TextToSpeech.SUCCESS)
        val tts = shadowOf(ShadowTextToSpeech.getLastTextToSpeechInstance())
        assertEquals(listOf("Radar fijo a 800 metros."), tts.spokenTextList)
        assertNull(speaker.speak("Fin de tramo."))
        assertEquals(listOf("Radar fijo a 800 metros.", "Fin de tramo."), tts.spokenTextList)
    }

    @Test
    fun aFailedInitDropsTheQueueAndReportsTheError() {
        val speaker = Speaker(context, spanish)
        speaker.speak("Radar fijo a 800 metros.")
        initialise(speaker, TextToSpeech.ERROR)
        assertEquals(emptyList<String>(), shadowOf(ShadowTextToSpeech.getLastTextToSpeechInstance()).spokenTextList)
        assertEquals(false, speaker.voiceReady)
        assertEquals("TextToSpeech init failed (-1)", speaker.speak("Fin de tramo."))
    }
}
