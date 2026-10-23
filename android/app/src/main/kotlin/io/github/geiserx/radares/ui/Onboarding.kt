// SPDX-License-Identifier: GPL-3.0-or-later
//
// First launch: what the app does, then one screen per permission, each with "Ahora no" (every refusal is
// tolerated; Estado shows what is missing). The background-location screen names the exact option Android shows
// ("Permitir todo el tiempo") through getBackgroundPermissionOptionLabel() and sends the driver to Settings,
// which is the only place Android 11 and later grants it.

package io.github.geiserx.radares.ui

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.geiserx.radares.R

enum class OnboardingStep { WELCOME, LOCATION, BACKGROUND, NOTIFICATIONS, ACTIVITY }

/** The steps this phone needs: the notification permission exists from Android 13. */
fun onboardingSteps(sdk: Int = Build.VERSION.SDK_INT): List<OnboardingStep> =
    OnboardingStep.entries.filter { it != OnboardingStep.NOTIFICATIONS || sdk >= Build.VERSION_CODES.TIRAMISU }

@Composable
fun Onboarding(onDone: () -> Unit) {
    val steps = onboardingSteps()
    var index by rememberSaveable { mutableIntStateOf(0) }
    val next: () -> Unit = {
        if (index + 1 < steps.size) index += 1 else onDone()
    }
    val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { next() }
    val step = steps[index]
    OnboardingStepView(
        step = step,
        backgroundOptionLabel = backgroundOptionLabel(),
        onPrimary = {
            when (step) {
                OnboardingStep.WELCOME -> next()
                OnboardingStep.LOCATION -> request.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
                // From Android 11 this request opens the app's location settings, where the option is chosen.
                OnboardingStep.BACKGROUND -> request.launch(arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION))
                // Only reached on Android 13 and later (onboardingSteps).
                OnboardingStep.NOTIFICATIONS -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    request.launch(arrayOf(Manifest.permission.POST_NOTIFICATIONS))
                } else {
                    next()
                }
                OnboardingStep.ACTIVITY -> request.launch(arrayOf(Manifest.permission.ACTIVITY_RECOGNITION))
            }
        },
        onSkip = next,
    )
}

@Composable
private fun backgroundOptionLabel(): String {
    val context = LocalContext.current
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        context.packageManager.backgroundPermissionOptionLabel.toString()
    } else {
        "Permitir todo el tiempo"
    }
}

@Composable
fun OnboardingStepView(
    step: OnboardingStep,
    backgroundOptionLabel: String,
    onPrimary: () -> Unit,
    onSkip: () -> Unit,
) {
    val (title, body, primary) = when (step) {
        OnboardingStep.WELCOME -> Triple(R.string.onb_welcome_title, stringResource(R.string.onb_welcome_body), R.string.onb_continue)
        OnboardingStep.LOCATION -> Triple(R.string.onb_location_title, stringResource(R.string.onb_location_body), R.string.onb_allow)
        OnboardingStep.BACKGROUND -> Triple(R.string.onb_background_title, stringResource(R.string.onb_background_body, backgroundOptionLabel), R.string.onb_open_settings)
        OnboardingStep.NOTIFICATIONS -> Triple(R.string.onb_notifications_title, stringResource(R.string.onb_notifications_body), R.string.onb_allow)
        OnboardingStep.ACTIVITY -> Triple(R.string.onb_activity_title, stringResource(R.string.onb_activity_body), R.string.onb_allow)
    }
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.padding(24.dp).padding(top = 48.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(stringResource(title), style = MaterialTheme.typography.headlineMedium)
            Text(body, style = MaterialTheme.typography.bodyLarge)
            Button(onClick = onPrimary, modifier = Modifier.fillMaxWidth()) { Text(stringResource(primary)) }
            if (step != OnboardingStep.WELCOME) {
                TextButton(onClick = onSkip, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.onb_not_now)) }
            }
        }
    }
}
