// SPDX-License-Identifier: GPL-3.0-or-later
//
// The warning notification as Android Auto needs it: on the high-importance "radares" channel, extended with
// CarAppExtender, one per pass, the previous radar's removed, the opposite flow silent.

package io.github.geiserx.radares.surfaces

import android.Manifest
import android.app.Application
import android.app.NotificationManager
import android.content.Context
import androidx.car.app.notification.CarAppExtender
import androidx.core.app.NotificationCompat
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

@RunWith(RobolectricTestRunner::class)
class NotifierTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val nm = context.getSystemService(NotificationManager::class.java)
    private val text = NotificationText("Radar fijo a 800 m", "A-2 km 202,3 · sentido Zaragoza")

    @Before
    fun setUp() {
        shadowOf(context as Application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        Notifier.createChannels(context)
    }

    @Test
    fun theThreeChannelsHaveTheirImportance() {
        assertEquals(NotificationManager.IMPORTANCE_HIGH, nm.getNotificationChannel(Notifier.CHANNEL_RADARES).importance)
        val drive = nm.getNotificationChannel(Notifier.CHANNEL_CONDUCCION)
        assertEquals(NotificationManager.IMPORTANCE_LOW, drive.importance)
        assertNull("the driving channel makes no sound", drive.sound)
        assertEquals(NotificationManager.IMPORTANCE_DEFAULT, nm.getNotificationChannel(Notifier.CHANNEL_ESTADO).importance)
    }

    @Test
    fun aWarningIsExtendedForTheCarOnTheRadarChannel() {
        val n = Notifier(context).builder(text, silent = false).build()
        assertTrue("CarAppExtender is what puts it on the Android Auto screen", CarAppExtender.isExtended(n))
        val car = CarAppExtender(n)
        assertEquals(text.title, car.contentTitle)
        assertEquals(text.body, car.contentText)
        // No CarAppService in this build yet: no tap action on the car banner (the auto lane adds the service).
        assertNull(car.contentIntent)
        assertEquals(Notifier.CHANNEL_RADARES, n.channelId)
        assertEquals(text.title, n.extras.getCharSequence(NotificationCompat.EXTRA_TITLE).toString())
        assertTrue("one banner per post, never re-alerting on an update", n.flags and android.app.Notification.FLAG_ONLY_ALERT_ONCE != 0)
    }

    @Test
    fun theOppositeFlowIsSilent() {
        val loud = Notifier(context).builder(text, silent = false).build()
        val quiet = Notifier(context).builder(text, silent = true).build()
        assertEquals(NotificationCompat.GROUP_ALERT_ALL, NotificationCompat.getGroupAlertBehavior(loud))
        assertEquals(NotificationCompat.GROUP_ALERT_SUMMARY, NotificationCompat.getGroupAlertBehavior(quiet))
    }

    @Test
    fun theNextRadarRemovesThePreviousAndAPassRemovesItsOwn() {
        val notifier = Notifier(context)
        assertNull(notifier.post(text, "dgt-1#1", silent = false))
        assertEquals(listOf("dgt-1#1"), nm.activeNotifications.map { it.tag })
        assertNull(notifier.post(text, "dgt-2#2", silent = false))
        assertEquals(listOf("dgt-2#2"), nm.activeNotifications.map { it.tag })
        notifier.removeRadar("dgt-1")
        assertEquals(1, nm.activeNotifications.size)
        notifier.removeRadar("dgt-2")
        assertEquals(0, nm.activeNotifications.size)
    }

    @Test
    fun withNotificationsOffThePostReportsIt() {
        shadowOf(nm).setNotificationsEnabled(false)
        assertEquals("notifications disabled", Notifier(context).post(text, "x#1", silent = false))
    }
}
