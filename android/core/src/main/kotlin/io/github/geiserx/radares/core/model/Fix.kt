// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Model/Fix.swift.

package io.github.geiserx.radares.core.model

import java.time.Instant

/// One position sample, platform-neutral. The location service builds it from a fused `Location`; the route vectors
/// in the tests carry arrays of them. One per second while driving.
data class Fix(
    val coordinate: Coordinate,
    val timestamp: Instant,
    /// Metres per second; null when the platform marks the speed invalid.
    val speed: Double? = null,
    /// Degrees 0..<360; null when the platform marks the course invalid.
    val course: Double? = null,
    /// Metres, the platform's horizontal accuracy radius.
    val horizontalAccuracy: Double,
    /// The platform says the device is not moving.
    val isStationary: Boolean = false,
)
