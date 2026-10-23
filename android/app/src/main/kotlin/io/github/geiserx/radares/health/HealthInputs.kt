// SPDX-License-Identifier: GPL-3.0-or-later
//
// Everything the twelve Android Estado rows read, collected by HealthCollector from the system and the log.
// Every field has a default so a test sets only what its row reads.

package io.github.geiserx.radares.health

import java.time.Instant

data class HealthInputs(
    val now: Instant = Instant.now(),
    // Ubicación precisa
    val fineLocation: Boolean = false,
    val coarseLocation: Boolean = false,
    // Ubicación siempre
    val backgroundLocation: Boolean = false,
    // Reconocimiento de actividad
    val activityRecognition: Boolean = false,
    // Notificaciones
    val notificationsEnabled: Boolean = false,
    /** NotificationManager importance of the "radares" channel; null when the channel does not exist. */
    val radarChannelImportance: Int? = null,
    // Valla de aparcamiento: "ok", an error text, or null when never registered.
    val fenceResult: String? = null,
    // Transiciones: "ok", an error text, or null when never registered.
    val transitionsResult: String? = null,
    // Datos
    val feedFetchedAt: Instant? = null,
    val feedFeatureCount: Int = 0,
    val feedConsecutiveFailures: Int = 0,
    // Actualización en segundo plano
    val refreshScheduled: Boolean = false,
    val lastRefreshRun: Instant? = null,
    val backgroundRestricted: Boolean = false,
    // Voz
    val voiceReady: Boolean? = null,
    val voiceError: String? = null,
    // Android Auto
    val carHostConnected: Boolean = false,
    // Archivos
    val filesWritable: Boolean? = null,
    // Último viaje
    val lastDriveMaxGapSeconds: Double? = null,
    val lastDriveHadLateAlert: Boolean = false,
)
