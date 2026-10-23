// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Model/Coordinate.swift.

package io.github.geiserx.radares.core.model

import kotlinx.serialization.Serializable

/// A WGS84 position. The only geographic type in the core, so no platform location type crosses into the alert maths.
@Serializable
data class Coordinate(val latitude: Double, val longitude: Double)
