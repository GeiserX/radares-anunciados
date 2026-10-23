// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Health/EventLog.swift.
// Append-only JSONL, rotated at Thresholds.logMaxLines by keeping the newest half, exportable and wipeable (design 6).
// One line per entry, {"event": {...}, "t": ISO 8601} with sorted keys. Writes never throw: a log that cannot be
// written is reported by the health screen through its absence, never by crashing the launch path.

package io.github.geiserx.radares.core.health

import io.github.geiserx.radares.core.Thresholds
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

/// One line of the log: the time and the event.
data class LogEntry(val t: Instant, val event: LogEvent)

class EventLog(val file: File) {
    /// Lines in the file; counted on the first append, then kept.
    private var lineCount: Int? = null

    fun append(e: LogEvent) = append(e, Instant.now())

    fun append(e: LogEvent, at: Instant) {
        try {
            val line = encode(LogEntry(at, e))
            if (lineCount == null) lineCount = countLines()
            if ((lineCount ?: 0) >= Thresholds.logMaxLines) rotate()
            file.parentFile?.mkdirs()
            file.appendText(line + "\n")
            lineCount = (lineCount ?: 0) + 1
        } catch (ex: Exception) {
            // Never throws.
        }
    }

    /// The newest `n` entries, oldest first. Lines that do not decode (an older schema) are skipped.
    fun recent(n: Int): List<LogEntry> {
        if (n <= 0) return emptyList()
        val lines = try {
            file.readLines().filter { it.isNotEmpty() }
        } catch (e: Exception) {
            return emptyList()
        }
        return lines.takeLast(n).mapNotNull { decode(it) }
    }

    /// The whole file, for the share sheet.
    fun export(): ByteArray? = try {
        file.readBytes()
    } catch (e: Exception) {
        null
    }

    /// Number of lines on disk.
    val count: Int get() = lineCount ?: countLines()

    /// Empties the log: the user can wipe the alert rows, which are the only ones with coordinates.
    fun wipe() {
        file.delete()
        lineCount = 0
    }

    /// Keeps the newest half of the lines so a rotation is not a second rotation one line later.
    private fun rotate() {
        val lines = try {
            file.readLines().filter { it.isNotEmpty() }
        } catch (e: Exception) {
            return
        }
        val keep = lines.takeLast(Thresholds.logMaxLines / 2)
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(keep.joinToString("") { it + "\n" })
        if (!tmp.renameTo(file)) {
            file.delete()
            tmp.renameTo(file)
        }
        lineCount = keep.size
    }

    private fun countLines(): Int = try {
        if (!file.exists()) 0 else file.readBytes().count { it == '\n'.code.toByte() }
    } catch (e: Exception) {
        0
    }

    companion object {
        /// Swift's .iso8601 strategy: whole seconds in UTC, "2026-10-07T08:00:01Z".
        private val iso: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'")

        fun encode(entry: LogEntry): String {
            val t = OffsetDateTime.ofInstant(entry.t.truncatedTo(ChronoUnit.SECONDS), ZoneOffset.UTC).format(iso)
            return LogEvent.obj("t" to JsonPrimitive(t), "event" to entry.event.toJson()).toString()
        }

        fun decode(line: String): LogEntry? = try {
            val o = Json.parseToJsonElement(line).jsonObject
            val t = OffsetDateTime.parse(o.getValue("t").jsonPrimitive.content).toInstant()
            LogEvent.fromJson(o.getValue("event"))?.let { LogEntry(t, it) }
        } catch (e: Exception) {
            null
        }
    }
}
