// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Health/LogEvent.swift.
// Every kind of row in events.jsonl (design 6). The JSON shape is Swift's synthesized Codable for an enum with
// associated values, so a log exported from either phone reads the same: {"caseName": {"label": value, ...}},
// an unlabeled value is "_0", a case without values is {}, and a null optional is left out.
// The iOS-only launch vocabulary (monitor, slc, liveUpdate, bgTask) is kept as-is; Android logs its own wake-ups
// with the same cases (`wakeup` with source "monitor" for the parked fence, `bgTaskRan` for a WorkManager run).

package io.github.geiserx.radares.core.health

import io.github.geiserx.radares.core.engine.Level
import io.github.geiserx.radares.core.model.Coordinate
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/// Which persisted wake-up brought the app back (design 3.1). Android: `monitor` is the parked geofence.
enum class WakeSource(val raw: String) { MONITOR("monitor"), SLC("slc") }

/// Why a drive started.
sealed class DriveReason {
    data object Foreground : DriveReason()
    data object Test : DriveReason()
    data class Wakeup(val source: WakeSource) : DriveReason()
}

/// How the launch reason is known: from the first thing that arrives after launch, never from a launch flag.
enum class LaunchReason(val raw: String) {
    MONITOR_EVENT("monitorEvent"), SLC("slc"), LIVE_UPDATE("liveUpdate"), BG_TASK("bgTask"), SCENE("scene"), UNKNOWN("unknown");

    /// A launch the system did on its own, without the user.
    val isBackgroundLaunch: Boolean get() = this == MONITOR_EVENT || this == SLC || this == LIVE_UPDATE || this == BG_TASK
}

enum class LaunchState(val raw: String) { ACTIVE("active"), INACTIVE("inactive"), BACKGROUND("background") }

enum class LaunchContext(val raw: String) { FOREGROUND("foreground"), BACKGROUND("background") }

enum class ProbeResult(val raw: String) { DRIVING("driving"), IDLE("idle"), TIMEOUT("timeout") }

/// Why a stretch was left (design 2.5).
enum class StretchExitReason(val raw: String) { FAR_GATE("farGate"), DISTANCE("distance"), TIME("time"), DRIVE_END("driveEnd") }

/// One delivery path and whether it took the alert.
data class SinkOutcome(val sink: Sink, val ok: Boolean, val detail: String? = null) {
    enum class Sink(val raw: String) { SPEECH("speech"), NOTIFICATION("notification") }
}

sealed class LogEvent {
    data class Launch(val reason: LaunchReason, val state: LaunchState) : LogEvent()
    data object SessionTaken : LogEvent()
    data class Wakeup(val source: WakeSource, val flags: List<String>) : LogEvent()
    data class Probe(val result: ProbeResult, val motion: Boolean?, val maxSpeedMps: Double?, val seconds: Double) : LogEvent()
    data class DriveStarted(val reason: DriveReason) : LogEvent()
    /// One every Thresholds.fixLogSeconds, not every fix.
    data class FixRow(val speedMps: Double?, val horizontalAccuracy: Double, val isStationary: Boolean) : LogEvent()
    data class Alert(
        val id: String,
        val level: Level,
        val distance: Double,
        val speedMps: Double?,
        val late: Boolean,
        val crossTrackMetres: Double?,
        val suppressedByDirection: Boolean,
        val coordinate: Coordinate,
        val sinks: List<SinkOutcome>,
        /// The sentence spoken for a FULL alert, null for VISUAL: the row is the evidence of what the driver heard.
        val spoken: String? = null,
    ) : LogEvent()
    data class Passed(val id: String) : LogEvent()
    data class StretchEntered(val id: String) : LogEvent()
    data class StretchExited(val id: String, val reason: StretchExitReason) : LogEvent()
    data object DrivePaused : LogEvent()
    data class DriveResumed(val pausedSeconds: Double) : LogEvent()
    data class DriveEnded(val fixes: Int, val maxGapSeconds: Double, val alerts: Int, val firstFixAfterWakeS: Double?, val firstWarnAfterWakeM: Double?) : LogEvent()
    data class FeedChecked(val etag: String?, val notModified: Boolean) : LogEvent()
    data class FeedUpdated(val count: Int, val etag: String?) : LogEvent()
    data class FeedFailed(val error: String) : LogEvent()
    data class BgTaskRan(val expired: Boolean) : LogEvent()
    data class NotificationPosted(val id: String, val error: String?) : LogEvent()
    data class Speech(val route: String, val setActiveError: String?, val finished: Boolean, val launchContext: LaunchContext) : LogEvent()
    data class MonitorEvent(val identifier: String, val state: String, val flags: List<String>) : LogEvent()
    data class ProtectionVerified(val ok: Boolean) : LogEvent()
    /// The process was ended while running; no background launch is possible until something restarts the app.
    data object WillTerminate : LogEvent()

    /// `{"caseName": {...}}` with Swift's key names.
    fun toJson(): JsonObject {
        val (name, fields) = when (this) {
            is Launch -> "launch" to obj("reason" to str(reason.raw), "state" to str(state.raw))
            SessionTaken -> "sessionTaken" to obj()
            is Wakeup -> "wakeup" to obj("source" to str(source.raw), "flags" to strs(flags))
            is Probe -> "probe" to obj("result" to str(result.raw), "motion" to motion?.let { JsonPrimitive(it) }, "maxSpeedMps" to num(maxSpeedMps), "seconds" to num(seconds))
            is DriveStarted -> "driveStarted" to obj("reason" to driveReason(reason))
            is FixRow -> "fix" to obj("speedMps" to num(speedMps), "horizontalAccuracy" to num(horizontalAccuracy), "isStationary" to JsonPrimitive(isStationary))
            is Alert -> "alert" to obj(
                "id" to str(id), "level" to str(level.raw), "distance" to num(distance), "speedMps" to num(speedMps),
                "late" to JsonPrimitive(late), "crossTrackMetres" to num(crossTrackMetres),
                "suppressedByDirection" to JsonPrimitive(suppressedByDirection),
                "coordinate" to obj("latitude" to num(coordinate.latitude), "longitude" to num(coordinate.longitude)),
                "sinks" to JsonArray(sinks.map { obj("sink" to str(it.sink.raw), "ok" to JsonPrimitive(it.ok), "detail" to it.detail?.let { str(it) }) }),
                "spoken" to spoken?.let { str(it) },
            )
            is Passed -> "passed" to obj("id" to str(id))
            is StretchEntered -> "stretchEntered" to obj("id" to str(id))
            is StretchExited -> "stretchExited" to obj("id" to str(id), "reason" to str(reason.raw))
            DrivePaused -> "drivePaused" to obj()
            is DriveResumed -> "driveResumed" to obj("pausedSeconds" to num(pausedSeconds))
            is DriveEnded -> "driveEnded" to obj(
                "fixes" to JsonPrimitive(fixes), "maxGapSeconds" to num(maxGapSeconds), "alerts" to JsonPrimitive(alerts),
                "firstFixAfterWakeS" to num(firstFixAfterWakeS), "firstWarnAfterWakeM" to num(firstWarnAfterWakeM),
            )
            is FeedChecked -> "feedChecked" to obj("etag" to etag?.let { str(it) }, "notModified" to JsonPrimitive(notModified))
            is FeedUpdated -> "feedUpdated" to obj("count" to JsonPrimitive(count), "etag" to etag?.let { str(it) })
            is FeedFailed -> "feedFailed" to obj("error" to str(error))
            is BgTaskRan -> "bgTaskRan" to obj("expired" to JsonPrimitive(expired))
            is NotificationPosted -> "notificationPosted" to obj("id" to str(id), "error" to error?.let { str(it) })
            is Speech -> "speech" to obj("route" to str(route), "setActiveError" to setActiveError?.let { str(it) }, "finished" to JsonPrimitive(finished), "launchContext" to str(launchContext.raw))
            is MonitorEvent -> "monitorEvent" to obj("identifier" to str(identifier), "state" to str(state), "flags" to strs(flags))
            is ProtectionVerified -> "protectionVerified" to obj("ok" to JsonPrimitive(ok))
            WillTerminate -> "willTerminate" to obj()
        }
        return obj(name to fields)
    }

    companion object {
        /// The inverse of toJson; null for a row this build does not know (an older or newer schema).
        fun fromJson(e: JsonElement): LogEvent? = try {
            val o = e.jsonObject
            val (name, v) = o.entries.single()
            val f = v.jsonObject
            fun s(k: String) = f.getValue(k).jsonPrimitive.content
            fun sOpt(k: String) = f[k]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content
            fun d(k: String) = f.getValue(k).jsonPrimitive.double
            fun dOpt(k: String) = f[k]?.takeIf { it !is JsonNull }?.jsonPrimitive?.double
            fun b(k: String) = f.getValue(k).jsonPrimitive.boolean
            fun i(k: String) = f.getValue(k).jsonPrimitive.int
            fun list(k: String) = f.getValue(k).jsonArray.map { it.jsonPrimitive.content }
            when (name) {
                "launch" -> Launch(LaunchReason.entries.first { it.raw == s("reason") }, LaunchState.entries.first { it.raw == s("state") })
                "sessionTaken" -> SessionTaken
                "wakeup" -> Wakeup(WakeSource.entries.first { it.raw == s("source") }, list("flags"))
                "probe" -> Probe(ProbeResult.entries.first { it.raw == s("result") }, f["motion"]?.takeIf { it !is JsonNull }?.jsonPrimitive?.boolean, dOpt("maxSpeedMps"), d("seconds"))
                "driveStarted" -> DriveStarted(parseDriveReason(f.getValue("reason").jsonObject))
                "fix" -> FixRow(dOpt("speedMps"), d("horizontalAccuracy"), b("isStationary"))
                "alert" -> {
                    val c = f.getValue("coordinate").jsonObject
                    Alert(
                        id = s("id"), level = Level.entries.first { it.raw == s("level") }, distance = d("distance"),
                        speedMps = dOpt("speedMps"), late = b("late"), crossTrackMetres = dOpt("crossTrackMetres"),
                        suppressedByDirection = b("suppressedByDirection"),
                        coordinate = Coordinate(c.getValue("latitude").jsonPrimitive.double, c.getValue("longitude").jsonPrimitive.double),
                        sinks = f.getValue("sinks").jsonArray.map { sink ->
                            val so = sink.jsonObject
                            SinkOutcome(
                                SinkOutcome.Sink.entries.first { it.raw == so.getValue("sink").jsonPrimitive.content },
                                so.getValue("ok").jsonPrimitive.boolean,
                                so["detail"]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content,
                            )
                        },
                        spoken = sOpt("spoken"),
                    )
                }
                "passed" -> Passed(s("id"))
                "stretchEntered" -> StretchEntered(s("id"))
                "stretchExited" -> StretchExited(s("id"), StretchExitReason.entries.first { it.raw == s("reason") })
                "drivePaused" -> DrivePaused
                "driveResumed" -> DriveResumed(d("pausedSeconds"))
                "driveEnded" -> DriveEnded(i("fixes"), d("maxGapSeconds"), i("alerts"), dOpt("firstFixAfterWakeS"), dOpt("firstWarnAfterWakeM"))
                "feedChecked" -> FeedChecked(sOpt("etag"), b("notModified"))
                "feedUpdated" -> FeedUpdated(i("count"), sOpt("etag"))
                "feedFailed" -> FeedFailed(s("error"))
                "bgTaskRan" -> BgTaskRan(b("expired"))
                "notificationPosted" -> NotificationPosted(s("id"), sOpt("error"))
                "speech" -> Speech(s("route"), sOpt("setActiveError"), b("finished"), LaunchContext.entries.first { it.raw == s("launchContext") })
                "monitorEvent" -> MonitorEvent(s("identifier"), s("state"), list("flags"))
                "protectionVerified" -> ProtectionVerified(b("ok"))
                "willTerminate" -> WillTerminate
                else -> null
            }
        } catch (e: Exception) {
            null
        }

        private fun driveReason(r: DriveReason): JsonObject = when (r) {
            DriveReason.Foreground -> obj("foreground" to obj())
            DriveReason.Test -> obj("test" to obj())
            is DriveReason.Wakeup -> obj("wakeup" to obj("_0" to str(r.source.raw)))
        }

        private fun parseDriveReason(o: JsonObject): DriveReason {
            val (name, v) = o.entries.single()
            return when (name) {
                "foreground" -> DriveReason.Foreground
                "test" -> DriveReason.Test
                "wakeup" -> DriveReason.Wakeup(WakeSource.entries.first { it.raw == v.jsonObject.getValue("_0").jsonPrimitive.content })
                else -> throw IllegalArgumentException(name)
            }
        }

        /// Keys sorted like JSONEncoder's .sortedKeys; null values left out like encodeIfPresent.
        internal fun obj(vararg pairs: Pair<String, JsonElement?>): JsonObject =
            JsonObject(pairs.filter { it.second != null }.sortedBy { it.first }.associate { it.first to it.second!! })

        private fun str(s: String) = JsonPrimitive(s)
        private fun strs(l: List<String>) = JsonArray(l.map { JsonPrimitive(it) })

        /// Swift's JSONEncoder writes a whole Double without ".0" (25, not 25.0).
        private fun num(d: Double?): JsonPrimitive? = d?.let { if (it.isFinite() && it == Math.rint(it) && Math.abs(it) < 1e15) JsonPrimitive(it.toLong()) else JsonPrimitive(it) }
    }
}
