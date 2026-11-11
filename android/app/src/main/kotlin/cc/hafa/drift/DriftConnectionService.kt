package cc.hafa.drift

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Short-lived foreground service that keeps the app process alive for a brief window after
 * the Quick Settings tile is shown or tapped.
 *
 * The DeviceManager's single connection to the AC lives in this process and is shared by
 * the tile, the widget, and the app. The tile's process is otherwise killed the moment the
 * panel closes, taking that socket with it — so the next pull cold-reconnects into a slot
 * the AC hasn't freed yet, which is what wedges. Holding the process alive keeps the one
 * socket warm, so a re-pull or a tap reuses the live session instead of reconnecting; the
 * same warm session serves the app and widget too, so there are never competing sockets.
 *
 * Uses the `shortService` type — a bounded, user-initiated task — so it needs no per-type
 * permission or ongoing-use justification, and it stops itself after [HOLD_MS].
 */
class DriftConnectionService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    // The deadline the current hold runs to; pushed out by each restart so an active user
    // (repeated pulls/taps) keeps the session warm without stacking services.
    @Volatile private var holdUntil = 0L
    @Volatile private var lifecycle: Job? = null
    // The newest start delivered, so the hold only ends if no later start is pending.
    @Volatile private var lastStartId = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            startForegroundCompat()
        } catch (@Suppress("TooGenericExceptionCaught", "SwallowedException") error: Exception) {
            // e.g. a shortService/type/permission problem — give up this start rather than crash.
            stopSelf()
            return START_NOT_STICKY
        }
        holdUntil = SystemClock.elapsedRealtime() + HOLD_MS
        lastStartId = startId
        if (lifecycle == null) {
            lifecycle = scope.launch {
                do {
                    // Poll at least once, so a newer start still being delivered (the reason
                    // a stop below was refused) can push `holdUntil` out before we recheck.
                    do { delay(POLL_MS) } while (SystemClock.elapsedRealtime() < holdUntil)
                    // Hand the AC a clean disconnect while we're still alive: it frees the
                    // unit's single slot promptly, instead of leaving the socket to an abrupt
                    // kernel close when this cached process is later killed. Idle-only, so it
                    // won't cut a reach in flight, or the app's socket between its polls.
                    runCatching { DriftApplication.devices(applicationContext).closeIfIdle() }
                    // Stop only if no newer start is queued. A plain stopSelf() racing a
                    // startForegroundService() whose onStartCommand hasn't run yet tears the
                    // service down before it calls startForeground, and the system then
                    // crashes the whole process — killing the warm socket mid-reach.
                } while (!stopSelfResult(lastStartId))
            }
        }
        return START_NOT_STICKY
    }

    /** shortService safety net: if the platform ever runs us to its own timeout (~minutes,
     *  far past [HOLD_MS]), stop promptly rather than being force-killed. */
    override fun onTimeout(startId: Int) {
        stopSelf()
    }

    override fun onDestroy() {
        lifecycle?.cancel()
        scope.cancel()
        super.onDestroy()
    }

    private fun startForegroundCompat() {
        ensureChannel()
        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_tile)
            .setContentTitle("Drift")
            .setContentText("Keeping the connection ready")
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Connection", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown briefly while Drift keeps the AC connection ready."
                },
            )
        }
    }

    companion object {
        private const val CHANNEL_ID = "drift_connection"
        private const val NOTIFICATION_ID = 1
        // How long to hold the process (and its warm socket) alive after the last tile use.
        private const val HOLD_MS = 30_000L
        private const val POLL_MS = 1_000L

        /** Best-effort: keep the process (and its warm AC socket) alive for a short window.
         *  A no-op if the platform blocks the start (e.g. a passive panel-pull outside the
         *  allowed background-start window on Android 12+) — the caller still reaches
         *  directly, just without the warm hold. */
        fun keepWarm(context: Context) {
            val intent = Intent(context, DriftConnectionService::class.java)
            // A blocked background start (e.g. a passive panel-pull outside the allowed
            // background-start window on Android 12+) is a no-op — the caller still reaches
            // directly, just without the warm hold.
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            }
        }
    }
}
