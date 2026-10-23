// SPDX-License-Identifier: GPL-3.0-or-later
//
// The twelve Estado rows of the Android app, pure over HealthInputs, ok / amber / red by the core thresholds.
// Each red row says in plain words what to do. Spanish by default, English when the phone is in English.
// The iOS rows (Sesión Siempre, Cambio significativo, CarPlay...) have no Android meaning and are not ported.

package io.github.geiserx.radares.health

import android.app.NotificationManager
import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.health.HealthItem
import io.github.geiserx.radares.core.health.HealthRules
import io.github.geiserx.radares.core.secondsSince
import java.time.Instant

enum class HealthStatus { OK, AMBER, RED }

enum class HealthAction { OPEN_SETTINGS, REFRESH_FEED, OPEN_ONBOARDING, NOTIFICATION_SETTINGS }

data class HealthRow(
    val id: String,
    val status: HealthStatus,
    val title: String,
    val detail: String,
    val action: HealthAction? = null,
)

object HealthIds {
    const val PRECISE = "precise"
    const val ALWAYS = "always"
    const val ACTIVITY = "activity"
    const val NOTIFICATIONS = "notifications"
    const val FENCE = "fence"
    const val TRANSITIONS = "transitions"
    const val FEED = "feed"
    const val REFRESH = "refresh"
    const val VOICE = "voice"
    const val AUTO = "auto"
    const val FILES = "files"
    const val LAST_DRIVE = "lastDrive"
}

fun healthReport(i: HealthInputs, english: Boolean = false): List<HealthRow> {
    val t = Text(english)
    return listOf(
        precise(i, t), always(i, t), activity(i, t), notifications(i, t), fence(i, t), transitions(i, t),
        feed(i, t), refresh(i, t), voice(i, t), auto(i, t), files(i, t), lastDrive(i, t),
    )
}

private class Text(val en: Boolean) {
    operator fun invoke(es: String, en: String) = if (this.en) en else es

    fun age(from: Instant, now: Instant): String = HealthRules.ageText(from, now, en)
}

private fun days(from: Instant?, now: Instant): Double? = from?.let { now.secondsSince(it) / 86_400 }

private fun precise(i: HealthInputs, t: Text): HealthRow {
    val title = t("Ubicación precisa", "Precise location")
    return when {
        i.fineLocation -> HealthRow(HealthIds.PRECISE, HealthStatus.OK, title, t("Concedida", "Granted"))
        i.coarseLocation -> HealthRow(HealthIds.PRECISE, HealthStatus.RED, title,
            t("Solo aproximada: activa «Usar ubicación precisa» en los permisos de la app", "Approximate only: turn on \"Use precise location\" in the app's permissions"),
            HealthAction.OPEN_SETTINGS)
        else -> HealthRow(HealthIds.PRECISE, HealthStatus.RED, title,
            t("Sin permiso de ubicación: la app no puede avisar", "No location permission: the app cannot warn"),
            HealthAction.OPEN_ONBOARDING)
    }
}

private fun always(i: HealthInputs, t: Text): HealthRow {
    val title = t("Ubicación siempre", "Location all the time")
    return if (i.backgroundLocation) {
        HealthRow(HealthIds.ALWAYS, HealthStatus.OK, title, t("Permitida todo el tiempo", "Allowed all the time"))
    } else {
        HealthRow(HealthIds.ALWAYS, HealthStatus.RED, title,
            t("Elige «Permitir todo el tiempo» en Ubicación: sin ello Android no deja empezar el viaje con la pantalla apagada",
                "Choose \"Allow all the time\" under Location: without it Android does not let a drive start with the screen off"),
            HealthAction.OPEN_SETTINGS)
    }
}

private fun activity(i: HealthInputs, t: Text): HealthRow {
    val title = t("Reconocimiento de actividad", "Physical activity")
    return if (i.activityRecognition) {
        HealthRow(HealthIds.ACTIVITY, HealthStatus.OK, title, t("Permitido", "Allowed"))
    } else {
        HealthRow(HealthIds.ACTIVITY, HealthStatus.AMBER, title,
            t("Sin permiso de actividad física: solo despierta la valla y el aviso llega más tarde",
                "No physical activity permission: only the fence wakes the app and the warning comes later"),
            HealthAction.OPEN_SETTINGS)
    }
}

private fun notifications(i: HealthInputs, t: Text): HealthRow {
    val title = t("Notificaciones", "Notifications")
    return when {
        !i.notificationsEnabled -> HealthRow(HealthIds.NOTIFICATIONS, HealthStatus.RED, title,
            t("Notificaciones desactivadas: solo avisa la voz", "Notifications off: only the voice warns"),
            HealthAction.NOTIFICATION_SETTINGS)
        (i.radarChannelImportance ?: NotificationManager.IMPORTANCE_HIGH) < NotificationManager.IMPORTANCE_HIGH ->
            HealthRow(HealthIds.NOTIFICATIONS, HealthStatus.AMBER, title,
                t("El canal «Avisos de radar» no es emergente: el aviso no aparece encima", "The \"Radar warnings\" channel does not pop up: the warning does not show on top"),
                HealthAction.NOTIFICATION_SETTINGS)
        else -> HealthRow(HealthIds.NOTIFICATIONS, HealthStatus.OK, title, t("Permitidas, emergentes", "Allowed, pop on screen"))
    }
}

private fun fence(i: HealthInputs, t: Text): HealthRow {
    val title = t("Valla de aparcamiento", "Parked fence")
    return when (val r = i.fenceResult) {
        null -> HealthRow(HealthIds.FENCE, HealthStatus.AMBER, title,
            t("Sin valla todavía: se pone al acabar el primer viaje", "No fence yet: it is set when the first drive ends"))
        "ok" -> HealthRow(HealthIds.FENCE, HealthStatus.OK, title, t("Valla registrada", "Fence registered"))
        else -> HealthRow(HealthIds.FENCE, HealthStatus.RED, title, t("La valla falló: $r", "The fence failed: $r"), HealthAction.OPEN_SETTINGS)
    }
}

private fun transitions(i: HealthInputs, t: Text): HealthRow {
    val title = t("Transiciones", "Transitions")
    return when (val r = i.transitionsResult) {
        null -> HealthRow(HealthIds.TRANSITIONS, HealthStatus.AMBER, title, t("Sin registrar todavía", "Not registered yet"), HealthAction.OPEN_ONBOARDING)
        "ok" -> HealthRow(HealthIds.TRANSITIONS, HealthStatus.OK, title, t("Registradas: en coche, a pie, parado", "Registered: in a vehicle, on foot, still"))
        else -> HealthRow(HealthIds.TRANSITIONS, HealthStatus.RED, title, t("No registradas: $r", "Not registered: $r"), HealthAction.OPEN_SETTINGS)
    }
}

private fun feed(i: HealthInputs, t: Text): HealthRow =
    HealthRules.feed(i.feedFetchedAt, i.feedFeatureCount, i.feedConsecutiveFailures, i.now, t.en).toRow(HealthIds.FEED)

private fun refresh(i: HealthInputs, t: Text): HealthRow {
    val title = t("Actualización en segundo plano", "Background refresh")
    if (i.backgroundRestricted) {
        return HealthRow(HealthIds.REFRESH, HealthStatus.RED, title,
            t("Batería restringida para la app: Android no la deja trabajar en segundo plano", "Battery restricted for the app: Android does not let it work in the background"),
            HealthAction.OPEN_SETTINGS)
    }
    if (!i.refreshScheduled) {
        return HealthRow(HealthIds.REFRESH, HealthStatus.RED, title, t("Actualización periódica no programada", "Periodic refresh not scheduled"))
    }
    val age = days(i.lastRefreshRun, i.now)
    if (age == null || age > Thresholds.bgRefreshSilentDays) {
        val silent = Thresholds.bgRefreshSilentDays.toInt()
        return HealthRow(HealthIds.REFRESH, HealthStatus.AMBER, title, t("Sin ejecución en $silent días", "No run in $silent days"))
    }
    return HealthRow(HealthIds.REFRESH, HealthStatus.OK, title,
        t("Última ejecución ${t.age(i.lastRefreshRun!!, i.now)}", "Last run ${t.age(i.lastRefreshRun!!, i.now)}"))
}

private fun voice(i: HealthInputs, t: Text): HealthRow {
    val title = t("Voz", "Voice")
    return when (i.voiceReady) {
        true -> HealthRow(HealthIds.VOICE, HealthStatus.OK, title, t("Voz lista", "Voice ready"))
        false -> HealthRow(HealthIds.VOICE, HealthStatus.RED, title,
            t("Voz en español no disponible: instálala en Ajustes › Texto a voz (${i.voiceError ?: "sin detalle"})",
                "Spanish voice not available: install it in Settings › Text-to-speech (${i.voiceError ?: "no detail"})"),
            HealthAction.OPEN_SETTINGS)
        null -> HealthRow(HealthIds.VOICE, HealthStatus.AMBER, title, t("Voz sin comprobar todavía", "Voice not checked yet"))
    }
}

/** Never red: the voice and the phone's notification warn without the car screen. */
private fun auto(i: HealthInputs, t: Text): HealthRow {
    val title = "Android Auto"
    val bannerReady = i.notificationsEnabled && (i.radarChannelImportance ?: NotificationManager.IMPORTANCE_HIGH) >= NotificationManager.IMPORTANCE_HIGH
    return when {
        !bannerReady -> HealthRow(HealthIds.AUTO, if (i.carHostConnected) HealthStatus.AMBER else HealthStatus.OK, title,
            t("Sin notificación emergente no hay aviso en la pantalla del coche; la voz sigue avisando",
                "Without a pop-up notification there is no warning on the car screen; the voice still warns"),
            HealthAction.NOTIFICATION_SETTINGS)
        i.carHostConnected -> HealthRow(HealthIds.AUTO, HealthStatus.OK, title,
            t("Conectado: el aviso sale también en la pantalla del coche", "Connected: the warning also shows on the car screen"))
        else -> HealthRow(HealthIds.AUTO, HealthStatus.OK, title,
            t("Aviso listo para la pantalla del coche (aún no conectado)", "Warning ready for the car screen (not connected yet)"))
    }
}

private fun files(i: HealthInputs, t: Text): HealthRow {
    val title = t("Archivos", "Files")
    return when (i.filesWritable) {
        true -> HealthRow(HealthIds.FILES, HealthStatus.OK, title, t("Legibles y escribibles", "Readable and writable"))
        false -> HealthRow(HealthIds.FILES, HealthStatus.RED, title, t("No se pueden escribir los archivos de la app", "The app's files cannot be written"))
        null -> HealthRow(HealthIds.FILES, HealthStatus.AMBER, title, t("Sin comprobar todavía", "Not checked yet"))
    }
}

private fun lastDrive(i: HealthInputs, t: Text): HealthRow =
    HealthRules.lastDrive(i.lastDriveMaxGapSeconds, i.lastDriveHadLateAlert, t.en).toRow(HealthIds.LAST_DRIVE)

/** A core row (feed, last drive: the rules both apps share) as an Android row. */
private fun HealthItem.toRow(id: String) = HealthRow(
    id = id,
    status = when (status) {
        HealthItem.Status.OK -> HealthStatus.OK
        HealthItem.Status.WARN -> HealthStatus.AMBER
        HealthItem.Status.FAIL -> HealthStatus.RED
    },
    title = title,
    detail = detail,
    action = when (action) {
        HealthItem.Action.OPEN_SETTINGS -> HealthAction.OPEN_SETTINGS
        HealthItem.Action.REFRESH_FEED -> HealthAction.REFRESH_FEED
        HealthItem.Action.OPEN_ONBOARDING -> HealthAction.OPEN_ONBOARDING
        null -> null
    },
)
