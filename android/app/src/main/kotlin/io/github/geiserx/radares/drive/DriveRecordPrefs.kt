// SPDX-License-Identifier: GPL-3.0-or-later
//
// The drive record in SharedPreferences, so a drive outlives the process (SPEC 4, 5). Written on drive start, pause,
// resume and once a minute while fixes arrive; cleared at drive end. `commit()`: the write lands before a kill.

package io.github.geiserx.radares.drive

import android.content.SharedPreferences
import androidx.core.content.edit
import io.github.geiserx.radares.core.model.Coordinate
import java.time.Instant

class DriveRecordPrefs(private val prefs: SharedPreferences) : DriveRecordStore {

    override fun load(): DriveRecord? {
        val started = prefs.getLong(STARTED, 0L).takeIf { it > 0 } ?: return null
        val seen = prefs.getLong(SEEN, 0L).takeIf { it > 0 } ?: return null
        val last = if (prefs.contains(LAT) && prefs.contains(LON)) {
            Coordinate(Double.fromBits(prefs.getLong(LAT, 0L)), Double.fromBits(prefs.getLong(LON, 0L)))
        } else {
            null
        }
        return DriveRecord(
            startedAt = Instant.ofEpochMilli(started),
            wakeAt = prefs.getLong(WAKE, 0L).takeIf { it > 0 }?.let(Instant::ofEpochMilli),
            pausedSince = prefs.getLong(PAUSED, 0L).takeIf { it > 0 }?.let(Instant::ofEpochMilli),
            seenAt = Instant.ofEpochMilli(seen),
            last = last,
        )
    }

    override fun save(record: DriveRecord) {
        prefs.edit(commit = true) {
            putLong(STARTED, record.startedAt.toEpochMilli())
            putLong(SEEN, record.seenAt.toEpochMilli())
            putLong(WAKE, record.wakeAt?.toEpochMilli() ?: 0L)
            putLong(PAUSED, record.pausedSince?.toEpochMilli() ?: 0L)
            if (record.last != null) {
                putLong(LAT, record.last.latitude.toRawBits())
                putLong(LON, record.last.longitude.toRawBits())
            } else {
                remove(LAT)
                remove(LON)
            }
        }
    }

    override fun clear() {
        prefs.edit(commit = true) { listOf(STARTED, SEEN, WAKE, PAUSED, LAT, LON).forEach { remove(it) } }
    }

    private companion object {
        const val STARTED = "drive.startedAt"
        const val SEEN = "drive.seenAt"
        const val WAKE = "drive.wakeAt"
        const val PAUSED = "drive.pausedSince"
        const val LAT = "drive.lastLat"
        const val LON = "drive.lastLon"
    }
}
