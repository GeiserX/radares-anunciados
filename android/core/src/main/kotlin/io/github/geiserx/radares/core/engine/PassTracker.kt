// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Engine/PassTracker.swift.
// Per radar id: idle -> armed -> fired(level) -> passed -> cooldown -> idle, with the 10 min AND 2 km rule (design 2.6).
// `armed` is transient (this process only); everything from `fired` on lives in the ledger, which the owner persists.

package io.github.geiserx.radares.core.engine

import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.secondsSince
import java.time.Instant

class PassTracker(ledger: PassLedger) {
    sealed class State {
        data object Idle : State()
        data object Armed : State()
        data class Fired(val level: Level) : State()
        data object Passed : State()
        data object Cooldown : State()
    }

    var ledger: PassLedger = ledger
        private set
    private val armed = mutableSetOf<String>()

    fun state(id: String, now: Instant): State {
        val entry = ledger.entry(id)
        if (entry != null) {
            if (entry.cooldownOver(now)) return State.Idle
            val passedAt = entry.passedAt ?: return State.Fired(entry.level)
            return if (now.secondsSince(passedAt) < Thresholds.passedCardSeconds) State.Passed else State.Cooldown
        }
        return if (id in armed) State.Armed else State.Idle
    }

    /// True when the radar may fire now: idle or armed, never fired, passed or cooling down.
    fun canFire(id: String, now: Instant): Boolean = when (state(id, now)) {
        State.Idle, State.Armed -> true
        else -> false
    }

    fun arm(id: String) {
        armed.add(id)
    }

    fun disarm(id: String) {
        armed.remove(id)
    }

    fun fire(id: String, level: Level, now: Instant) {
        armed.remove(id)
        ledger = ledger.upsert(PassLedger.Entry(id = id, firedAt = now, level = level))
    }

    fun markPassed(id: String, now: Instant) {
        val entry = ledger.entry(id) ?: return
        if (entry.passedAt != null) return
        ledger = ledger.upsert(entry.copy(passedAt = now))
    }

    /// Records how far the car is from a fired radar, for the 2 km half of the cooldown.
    fun observe(id: String, distance: Double) {
        val entry = ledger.entry(id) ?: return
        if (!(entry.farthestMetres < Thresholds.cooldownM && distance > entry.farthestMetres)) return
        ledger = ledger.upsert(entry.copy(farthestMetres = distance))
    }

    /// Entries whose cooldown is over are dropped, old ones pruned. Called at drive end, never per fix.
    fun prune(now: Instant) {
        ledger = ledger.copy(entries = ledger.entries.filter { !it.cooldownOver(now) }).prune(now)
    }

    /// Ids fired and not yet passed, for the pass detection.
    val firedIds: List<String> get() = ledger.entries.filter { it.passedAt == null }.map { it.id }
}
