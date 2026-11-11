package cc.hafa.drift

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.service.quicksettings.TileService
import androidx.glance.appwidget.updateAll
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Process-scoped home of the [DeviceManager] — the single owner of the connection to
 * the AC, shared by the UI, the Quick Settings tile, and the home widget. Reach it
 * from any component with [devices].
 *
 * Also keeps the tile and widget in sync as the phone moves between Wi-Fi networks:
 * joining a network triggers one re-sync (the manager rediscovers + refreshes the
 * stored address, then both surfaces repaint), so the controls follow the device
 * across networks and DHCP leases without any continuous background polling.
 */
class DriftApplication : Application() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    // Whether a resync is already running, so overlapping Wi-Fi events collapse into it.
    private val resyncing = AtomicBoolean(false)

    lateinit var deviceManager: DeviceManager
        private set

    /** First-run setup, shared by every screen that shows it. */
    lateinit var setupController: SetupController
        private set

    override fun onCreate() {
        super.onCreate()
        SetupLog.start(filesDir)
        deviceManager = DeviceManager(this)
        setupController = SetupController(this, deviceManager)
        val connectivity = getSystemService(ConnectivityManager::class.java) ?: return
        val wifi = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        connectivity.registerNetworkCallback(
            wifi,
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    // A Wi-Fi flap (join → validate → drop → rejoin) fires onAvailable
                    // repeatedly, and each resync is a full reach that can hold the manager's
                    // mutex for tens of seconds. Collapse overlapping events into the one in
                    // flight; the tile and widget reach on demand anyway, so a skip costs nothing.
                    if (resyncing.compareAndSet(false, true)) {
                        scope.launch {
                            try {
                                resync()
                            } finally {
                                resyncing.set(false)
                            }
                        }
                    }
                }
            },
        )
    }

    private suspend fun resync() {
        if (CredentialStore(this).load() == null) return
        // Relocate + persist the address once; the tile and widget then repaint off
        // the warmed connection instead of each rediscovering.
        deviceManager.refresh()
        DriftWidget().updateAll(this)
        TileService.requestListeningState(
            this,
            ComponentName(this, DriftTileService::class.java),
        )
    }

    companion object {
        fun devices(context: Context): DeviceManager =
            (context.applicationContext as DriftApplication).deviceManager

        /** The process-wide [SetupController]. */
        fun setup(context: Context): SetupController =
            (context.applicationContext as DriftApplication).setupController
    }
}
