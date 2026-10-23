// SPDX-License-Identifier: GPL-3.0-or-later
//
// Every onboarding screen renders, each permission screen can be skipped, the background screen names the
// option Android shows, and none tells the driver to open the app before driving.

package io.github.geiserx.radares.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "es")
class OnboardingTest {
    @get:Rule val compose = createComposeRule()

    private val titles = mapOf(
        OnboardingStep.WELCOME to "Avisos de radares publicados",
        OnboardingStep.LOCATION to "Ubicación precisa",
        OnboardingStep.BACKGROUND to "Ubicación todo el tiempo",
        OnboardingStep.NOTIFICATIONS to "Notificaciones",
        OnboardingStep.ACTIVITY to "Actividad física",
    )

    @Test
    fun everyStepRendersAndCanBeSkipped() {
        var step by mutableStateOf(OnboardingStep.WELCOME)
        var skipped = 0
        var primary = 0
        compose.setContent {
            RadaresTheme { OnboardingStepView(step, "Permitir todo el tiempo", onPrimary = { primary++ }, onSkip = { skipped++ }) }
        }
        for (s in OnboardingStep.entries) {
            step = s
            compose.waitForIdle()
            compose.onNodeWithText(titles.getValue(s)).assertExists()
            listOf("abre la app", "antes de conducir", "iniciar", "detener").forEach {
                compose.onNodeWithText(it, substring = true, ignoreCase = true).assertDoesNotExist()
            }
            if (s == OnboardingStep.WELCOME) {
                compose.onNodeWithText("Ahora no").assertDoesNotExist()
                compose.onNodeWithText("Continuar").performClick()
            } else {
                val before = skipped
                compose.onNodeWithText("Ahora no").performClick()
                assertEquals("$s can be refused", before + 1, skipped)
            }
        }
        assertEquals(1, primary)
    }

    @Test
    fun theBackgroundStepNamesTheOptionAndLeadsToSettings() {
        compose.setContent {
            RadaresTheme { OnboardingStepView(OnboardingStep.BACKGROUND, "Permitir todo el tiempo", onPrimary = {}, onSkip = {}) }
        }
        compose.onNodeWithText("«Permitir todo el tiempo»", substring = true).assertExists()
        compose.onNodeWithText("Abrir ajustes").assertExists()
    }

    @Test
    fun theNotificationStepExistsFromAndroid13Only() {
        assertEquals(false, OnboardingStep.NOTIFICATIONS in onboardingSteps(sdk = 32))
        assertEquals(true, OnboardingStep.NOTIFICATIONS in onboardingSteps(sdk = 33))
    }
}
