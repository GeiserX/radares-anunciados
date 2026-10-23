// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the car screen reads from the phone app: the newest known position and the radar store. An interface so
// the screen can be tested with fixed values.

package io.github.geiserx.radares.car

import io.github.geiserx.radares.core.feed.RadarStore
import io.github.geiserx.radares.core.model.Coordinate

interface CarData {
    /** The last fix of the current drive, else the last position the phone knows; null when none. */
    fun position(): Coordinate?

    /** The decoded feed, or null before the first load. */
    fun store(): RadarStore?

    /** Whether the app holds fine location, which the host needs to draw the car's own position on the map. */
    fun locationPermitted(): Boolean
}
