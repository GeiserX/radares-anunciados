// SPDX-License-Identifier: GPL-3.0-or-later
//
// The foreground service of type location that runs while the phone may be in a car (SPEC 8). Started only by
// the wake-ups (transition, fence, boot never starts it), never by a button. Its notification is the minimal
// silent one Android requires for a foreground service, on the "conduccion" channel: no actions, no stop button,
// nothing the driver has to look at. The warnings themselves are separate notifications on "radares".
//
// It hosts the DriveController: fixes at 1 Hz in, engine events out to the dispatcher. It stops itself when the
// probe finds no drive or the drive ends.

package io.github.geiserx.radares.drive

import android.app.Notification
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.DetectedActivity
import io.github.geiserx.radares.R
import io.github.geiserx.radares.RadaresApp
import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.engine.AlertEngine
import io.github.geiserx.radares.core.feed.FeedRefreshPolicy
import io.github.geiserx.radares.surfaces.Notifier
import java.time.Instant
import java.util.concurrent.Executors

class DriveService : LifecycleService() {

    private lateinit var controller: DriveController
    private lateinit var location: LocationSource
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var locationStarted = false

    private val tick = object : Runnable {
        override fun run() {
            controller.onTick()
            if (running == this@DriveService) main.postDelayed(this, 1000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        val graph = RadaresApp.graph(this)
        location = FusedLocationSource(this) { isStationary(this) }
        controller = DriveController(
            clock = Instant::now,
            engineFactory = { resuming ->
                graph.feed.loadIfNeeded()?.let { store ->
                    val ledger = graph.ledger.load().prune(Instant.now())
                    // The stretch belongs to the drive that was inside it: a drive restored after a process death
                    // keeps it, a new drive never does (SPEC 5).
                    AlertEngine(store, if (resuming) ledger else ledger.copy(stretch = null))
                }
            },
            sink = graph.dispatcher,
            events = graph.log,
            ledgerSaver = { ledger -> io.execute { graph.ledger.save(ledger) } },
            armFence = { WakeUps.armFence(this, it) },
            stopService = { main.post { stopSelf() } },
            recentInVehicle = { recentInVehicle(this) },
            onDriveStart = {
                graph.driveOn.value = true
                io.execute { graph.feed.refreshIfNeeded(FeedRefreshPolicy.Trigger.DRIVE_START) }
            },
            records = DriveRecordPrefs(WakeUps.prefs(this)),
        )
        controller.onSnapshot = { snapshot, on ->
            graph.snapshot.value = if (on) snapshot else null
            graph.driveOn.value = on
        }
        running = this
        main.postDelayed(tick, 1000)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        // Within 5 s of startForegroundService, before anything else can fail.
        try {
            startForeground(Notifier.DRIVE_ID, foregroundNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } catch (e: Exception) {
            // Background location revoked (Android 14 refuses the type) or a background-start restriction.
            RadaresApp.graph(this).log.note("foreground start refused: ${e.javaClass.simpleName}: ${e.message}")
            stopSelf()
            return START_NOT_STICKY
        }
        if (!locationStarted) {
            val error = location.start { controller.onFix(it) }
            if (error != null) {
                RadaresApp.graph(this).log.note("location refused: $error")
                stopSelf()
                return START_NOT_STICKY
            }
            locationStarted = true
        }
        // The process died mid-drive (a START_STICKY restart carries no intent, or a wake-up found it gone): the same
        // drive continues from its record. Otherwise a restart with no intent probes again.
        val restored = controller.restore()
        if (restored) {
            graph().driveOn.value = true
            graph().snapshot.value = controller.snapshot
        }
        controller.onWake(Wake.from(intent?.getStringExtra(EXTRA_WAKE)) ?: Wake.Fence)
        return START_STICKY
    }

    override fun onDestroy() {
        if (running == this) running = null
        main.removeCallbacks(tick)
        location.stop()
        RadaresApp.graph(this).driveOn.value = false
        RadaresApp.graph(this).snapshot.value = null
        io.shutdown()
        super.onDestroy()
    }

    private fun graph() = RadaresApp.graph(this)

    private fun foregroundNotification(): Notification =
        NotificationCompat.Builder(this, Notifier.CHANNEL_CONDUCCION)
            .setSmallIcon(R.drawable.ic_stat_radar)
            .setContentTitle(getString(R.string.drive_notification))
            .setSilent(true)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()

    companion object {
        const val EXTRA_WAKE = "wake"

        @Volatile private var running: DriveService? = null

        /** A wake-up that may start a drive: in vehicle, fence exit, self-test. */
        fun start(context: Context, wake: Wake) {
            val intent = Intent(context, DriveService::class.java).putExtra(EXTRA_WAKE, wake.wire)
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (e: Exception) {
                // ForegroundServiceStartNotAllowedException or a SecurityException: Estado shows the permission row red.
                RadaresApp.graph(context).log.note("drive service start refused: ${e.javaClass.simpleName}: ${e.message}")
            }
        }

        /** A transition that only matters to a drive already on (on foot, still): no service is started for it. */
        fun notify(context: Context, wake: Wake) {
            val service = running ?: return
            service.main.post { if (running == service) service.controller.onWake(wake) }
        }

        /** The newest transition is STILL enter with no IN_VEHICLE since: the fixes are stationary. */
        fun isStationary(context: Context): Boolean {
            val last = WakeUps.prefs(context).getString(WakeUps.KEY_LAST_TRANSITION, null) ?: return false
            return last == "${DetectedActivity.STILL}:${ActivityTransition.ACTIVITY_TRANSITION_ENTER}"
        }

        /** An IN_VEHICLE enter in the last Thresholds.motionWindowSeconds starts the drive at once. */
        fun recentInVehicle(context: Context, nowMillis: Long = System.currentTimeMillis()): Boolean {
            val p = WakeUps.prefs(context)
            val last = p.getString(WakeUps.KEY_LAST_TRANSITION, null) ?: return false
            val at = p.getLong(WakeUps.KEY_LAST_TRANSITION_AT, 0)
            return last == "${DetectedActivity.IN_VEHICLE}:${ActivityTransition.ACTIVITY_TRANSITION_ENTER}" &&
                nowMillis - at <= (Thresholds.motionWindowSeconds * 1000).toLong()
        }
    }
}
