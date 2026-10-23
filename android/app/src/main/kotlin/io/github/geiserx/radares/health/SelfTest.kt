// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Autocomprobación" (SPEC 9): a synthetic fixed radar 600 m ahead, pushed through the real engine and the real
// voice and notification. The fixes approach it at 90 km/h, so the engine fires the way it does on the road
// ("Radar fijo a 600 metros, sentido Zaragoza. Límite 90.") and then passes it, which removes the notification.
// Nothing here touches the real feed or the pass ledger.

package io.github.geiserx.radares.health

import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.engine.AlertEngine
import io.github.geiserx.radares.core.engine.AlertEvent
import io.github.geiserx.radares.core.engine.PassLedger
import io.github.geiserx.radares.core.feed.RadarStore
import io.github.geiserx.radares.core.geo.Geo
import io.github.geiserx.radares.core.model.Coordinate
import io.github.geiserx.radares.core.model.Fix
import io.github.geiserx.radares.core.model.Kind
import io.github.geiserx.radares.core.model.Radar
import io.github.geiserx.radares.core.model.Role
import io.github.geiserx.radares.drive.EventSink
import java.time.Instant
import java.util.Locale

object SelfTest {
    /** The A-2 gate the iOS self-test uses. */
    val radarAt = Coordinate(41.30326, -1.94488)

    private const val SPEED_MPS = 25.0
    private const val HEADING = 60.0

    fun radar() = Radar(
        id = "self-test", kind = Kind.FIXED, role = Role.POINT, start = radarAt,
        name = "Radar de prueba", road = "A-2", kmFrom = 202.3, maxspeed = 90, directionText = "ZARAGOZA",
        source = "self-test", attribution = "",
    )

    /**
     * The fixes, 1 Hz at 90 km/h on a straight line through the radar: starting 135 m before the 600 m mark so the
     * engine sees two closing fixes before the warn distance, and ending 100 m past it.
     */
    fun fixes(start: Instant): List<Fix> {
        val first = Thresholds.selfTestDistanceM + 135
        val count = ((first + 100) / SPEED_MPS).toInt() + 1
        return (0 until count).map { i ->
            val along = first - i * SPEED_MPS
            val at = Geo.destination(radarAt, (HEADING + 180) % 360, along)
            Fix(at, start.plusSeconds(i.toLong()), speed = SPEED_MPS, course = HEADING, horizontalAccuracy = 5.0)
        }
    }

    /** The whole approach through a fresh engine: every event with the fix it was decided on, in order. */
    fun events(locale: Locale = Locale.getDefault(), now: Instant = Instant.now()): List<Pair<AlertEvent, Fix>> {
        val engine = AlertEngine(RadarStore(listOf(radar())), PassLedger(), locale = locale)
        return fixes(now).flatMap { fix -> engine.ingest(fix).map { it to fix } }
    }

    /**
     * Sends the events to the real sinks: the warning at once, the pass (which removes the notification) after
     * `hold`, so the banner stays long enough to be seen and heard. Returns the events.
     */
    suspend fun run(sink: EventSink, hold: suspend () -> Unit, locale: Locale = Locale.getDefault()): List<AlertEvent> {
        val all = events(locale)
        for ((event, fix) in all) {
            if (event.kind == AlertEvent.Kind.Passed) hold()
            sink.handle(event, fix)
        }
        return all.map { it.first }
    }
}
