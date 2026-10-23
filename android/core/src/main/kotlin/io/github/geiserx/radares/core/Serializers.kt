// SPDX-License-Identifier: GPL-3.0-or-later
// Instants as ISO 8601 strings in every file the core writes (passes.json, feed.meta.json), like Swift's .iso8601.

package io.github.geiserx.radares.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.time.Instant
import java.time.OffsetDateTime

object InstantSerializer : KSerializer<Instant> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("Instant", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeString(value.toString())
    override fun deserialize(decoder: Decoder): Instant = parseIso(decoder.decodeString())

    /// "2026-10-07T10:00:01+02:00" or "2026-10-07T08:00:01Z".
    fun parseIso(raw: String): Instant = OffsetDateTime.parse(raw).toInstant()
}
