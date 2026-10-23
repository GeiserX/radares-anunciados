// SPDX-License-Identifier: GPL-3.0-or-later
//
// One theme, dark: the app is read in a car, often at night.

package io.github.geiserx.radares.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val Amber = Color(0xFFFFB300)
val Red = Color(0xFFE53935)
val Green = Color(0xFF43A047)

private val scheme = darkColorScheme(
    primary = Color(0xFFFFB300),
    onPrimary = Color(0xFF1B1B1B),
    secondary = Color(0xFF90CAF9),
    background = Color(0xFF121212),
    surface = Color(0xFF1E1E1E),
    surfaceVariant = Color(0xFF2A2A2A),
    onBackground = Color(0xFFECECEC),
    onSurface = Color(0xFFECECEC),
    onSurfaceVariant = Color(0xFFBDBDBD),
)

@Composable
fun RadaresTheme(content: @Composable () -> Unit) = MaterialTheme(colorScheme = scheme, content = content)
