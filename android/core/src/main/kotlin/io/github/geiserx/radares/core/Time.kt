// SPDX-License-Identifier: GPL-3.0-or-later
// Swift's Date arithmetic on java.time.Instant, and Swift's rounding rule, so the ports read like their sources.

package io.github.geiserx.radares.core

import java.time.Duration
import java.time.Instant

/// Swift `a.timeIntervalSince(b)`: seconds from `earlier` to this instant, fractional.
fun Instant.secondsSince(earlier: Instant): Double = Duration.between(earlier, this).toNanos() / 1e9

/// Swift `date.addingTimeInterval(seconds)`.
fun Instant.plusSeconds(seconds: Double): Instant = plusNanos(Math.round(seconds * 1e9))

/// Swift `Double.rounded()`: half away from zero. kotlin.math.round rounds half to even and must never be used here.
fun roundHalfAway(x: Double): Long = if (x < 0) -Math.round(-x) else Math.round(x)
