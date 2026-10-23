// SPDX-License-Identifier: GPL-3.0-or-later
//
// The warning notification, the visual surface of every warning (SPEC 6). One code path for the phone and the car:
// every radar notification is extended with CarAppExtender and posted through CarNotificationManager, which is
// what Android Auto needs before it draws a heads-up banner on the car screen (docs/ANDROID-AUTO.md). With no car
// connected the same call lands on the phone.
//
// Ids: tag `<radarId>#<passSeq>`, int id RADAR_ID. A later pass of the same radar is a new tag, so a new banner.
// The previous radar's notification is removed when the next one posts, and a radar's own when it is passed.

package io.github.geiserx.radares.surfaces

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import androidx.car.app.notification.CarAppExtender
import androidx.car.app.notification.CarNotificationManager
import androidx.car.app.notification.CarPendingIntent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.github.geiserx.radares.R
import io.github.geiserx.radares.ui.MainActivity

/** What a warning notification says. */
data class NotificationText(val title: String, val body: String)

/** The surface the dispatcher posts to; a fake in tests. */
interface WarningPoster {
    /** Posts one warning; returns null on success or the failure text. */
    fun post(text: NotificationText, tag: String, silent: Boolean): String?

    /** Removes every notification of this radar (any pass). */
    fun removeRadar(radarId: String)
}

class Notifier(private val context: Context) : WarningPoster {

    private val cars = CarNotificationManager.from(context)
    private val system = context.getSystemService(NotificationManager::class.java)

    override fun post(text: NotificationText, tag: String, silent: Boolean): String? {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return "notifications disabled"
        return try {
            removeOtherRadars(keep = tag)
            cars.notify(tag, RADAR_ID, builder(text, silent))
            null
        } catch (e: SecurityException) {
            "SecurityException: ${e.message}"
        } catch (e: RuntimeException) {
            "${e.javaClass.simpleName}: ${e.message}"
        }
    }

    override fun removeRadar(radarId: String) {
        activeRadarTags().filter { it.substringBeforeLast('#') == radarId }.forEach { cars.cancel(it, RADAR_ID) }
    }

    /** The builder, public for the test that checks the car extender and the channel. */
    fun builder(text: NotificationText, silent: Boolean): NotificationCompat.Builder {
        val car = CarAppExtender.Builder()
            .setContentTitle(text.title)
            .setContentText(text.body)
            .setSmallIcon(R.drawable.ic_stat_radar)
            .apply { carAppIntent()?.let(::setContentIntent) }
            .build()
        return NotificationCompat.Builder(context, CHANNEL_RADARES)
            .setSmallIcon(R.drawable.ic_stat_radar)
            .setContentTitle(text.title)
            .setContentText(text.body)
            .setCategory(NotificationCompat.CATEGORY_NAVIGATION)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setSilent(silent)
            .setAutoCancel(true)
            .setContentIntent(phoneIntent())
            .extend(car)
    }

    private fun removeOtherRadars(keep: String) {
        activeRadarTags().filter { it != keep }.forEach { cars.cancel(it, RADAR_ID) }
    }

    private fun activeRadarTags(): List<String> =
        system.activeNotifications.filter { it.id == RADAR_ID && it.tag != null }.map { it.tag }

    private fun phoneIntent(): PendingIntent = PendingIntent.getActivity(
        context, 0,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /**
     * Opens the car screen when the banner is tapped on Android Auto. CarPendingIntent accepts only a CarAppService
     * declared in the manifest, so with no car service in the build the banner simply has no tap action.
     */
    private fun carAppIntent(): PendingIntent? {
        val intent = Intent(Intent.ACTION_VIEW).setComponent(ComponentName(context, CAR_APP_SERVICE))
        if (context.packageManager.resolveService(intent, 0) == null) return null
        return CarPendingIntent.getCarApp(context, 0, intent, 0)
    }

    companion object {
        const val CHANNEL_RADARES = "radares"
        const val CHANNEL_CONDUCCION = "conduccion"
        const val CHANNEL_ESTADO = "estado"
        const val RADAR_ID = 1
        const val DRIVE_ID = 2
        const val HEALTH_ID = 3
        const val CAR_APP_SERVICE = "io.github.geiserx.radares.car.RadaresCarAppService"

        /** The three channels, created at every launch (creating an existing channel changes nothing). */
        fun createChannels(context: Context) {
            val nm = context.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_RADARES, context.getString(R.string.channel_radares), NotificationManager.IMPORTANCE_HIGH).apply {
                    description = context.getString(R.string.channel_radares_desc)
                    lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                },
            )
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_CONDUCCION, context.getString(R.string.channel_conduccion), NotificationManager.IMPORTANCE_LOW).apply {
                    description = context.getString(R.string.channel_conduccion_desc)
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                },
            )
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ESTADO, context.getString(R.string.channel_estado), NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = context.getString(R.string.channel_estado_desc)
                },
            )
        }
    }
}
