package cc.hafa.drift

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.SystemClock
import io.hafa.mideakt.ACState
import io.hafa.mideakt.DeviceCredentials
import io.hafa.mideakt.DiscoveredDevice
import io.hafa.mideakt.Discovery
import io.hafa.mideakt.MideaClient
import io.hafa.mideakt.OperationalMode
import io.hafa.mideakt.SetState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.net.Inet4Address
import java.net.InetAddress

/** Outcome of reaching the AC, distinguishing the cases callers must show apart. */
sealed interface Reachability {
    /** Reached the AC; here is its current state. */
    data class Online(override val state: ACState) : Reachability

    /** The AC answered discovery on this network, but we couldn't open a session — its
     *  single TCP connection is taken (by a not-yet-released prior socket). Transient —
     *  distinct from absent. */
    data object Busy : Reachability

    /** The AC isn't reachable on this network at all (not found by discovery). */
    data object Offline : Reachability

    /** The phone isn't on any Wi-Fi network, so the LAN-only AC can't be reached from
     *  here at all — a problem on this side, distinct from [Offline] (on Wi-Fi, but the
     *  AC is absent). No reach is attempted, so the AC's single slot is left untouched. */
    data object NoWifi : Reachability

    /** Android 17+ hasn't granted local network access, so every packet to the AC would be
     *  blocked; no reach is attempted. */
    data object NoLocalNetwork : Reachability

    val state: ACState? get() = (this as? Online)?.state
}

/** A compact, display-only snapshot of the last reading, persisted for hysteresis. */
data class LastState(
    val powerOn: Boolean,
    val targetTemperature: Double,
    val modeName: String,
    val indoorTemperature: Double? = null,
    /** When the reading was taken, in wall-clock milliseconds; null if saved before this was kept. */
    val updatedAtMillis: Long? = null,
)

/**
 * The single owner of the connection to the configured AC, shared by every surface
 * in the app (the foreground UI, the Quick Settings tile, the home widget). The AC
 * accepts exactly one TCP connection at a time, so funnelling all access through one
 * [MideaClient] behind one [Mutex] is what keeps two surfaces from opening competing
 * sockets that collide at the unit.
 *
 * Unlike a throwaway-per-call approach, the connection is **kept open and reused**:
 * the first reach pays a cold connect + auth + warm-up, but subsequent reaches from a
 * still-alive process ride the warm session and answer in a fraction of a second.
 * [MideaClient] self-heals a dropped socket, and the slot is freed after a lull by an
 * idle-release timer, and promptly by the connection service (via [closeIfIdle]) when its
 * keep-warm window ends.
 *
 * A failed op is usually transient — a cold-launched process (e.g. a tile tap) wakes
 * the Wi-Fi radio from power-save and its first TCP connect can be dropped — so we first
 * retry the direct connection to the known address a few times with backoff; that's
 * cheap and reliable, and it's where the AC almost always still is. Only if those retries
 * all fail do we fall back to discovery, in case the address actually moved (different
 * network or DHCP lease): if discovery finds it we point at the new address and retry; if
 * it's still present but unreachable its one slot is taken — [Busy]; if discovery sees
 * nothing across a few rounds it's [Offline]. Discovery is the slow, unreliable path (a
 * broadcast from a freshly-spawned process is easily lost), which is exactly why it's the
 * fallback rather than the gate.
 *
 * Every op blocks on network I/O; callers may invoke from any dispatcher (the manager
 * moves the blocking work to [Dispatchers.IO] itself).
 */
class DeviceManager(context: Context) {
    private val appContext = context.applicationContext
    private val store = CredentialStore(appContext)
    private val mutex = Mutex()
    private val connectivity = appContext.getSystemService(ConnectivityManager::class.java)
    // Off-reach work (the idle-release timer); independent of any caller's lifecycle so a
    // caller cancelling its reach (e.g. the widget's fetch budget) doesn't disarm it.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile private var client: MideaClient? = null
    @Volatile private var credentials: DeviceCredentials? = null
    // The current Wi-Fi network, tracked so a reach can pin its sockets to it. Kept
    // fresh by a callback, but a reach also scans synchronously as a fallback in case
    // the callback hasn't fired yet (e.g. a cold tile process's very first reach).
    @Volatile private var wifiNetwork: Network? = null
    // The pending idle-release timer, if the slot is currently held warm. Re-armed after
    // each reach and cancelled when a new one starts; only touched from inside the mutex.
    @Volatile private var idleReleaseJob: Job? = null
    // When the last reach ended, on the elapsed-realtime clock; only touched from inside the mutex.
    @Volatile private var lastReachAt: Long? = null

    private val _wifiAvailable = MutableStateFlow(false)

    /** Whether the phone currently has an active Wi-Fi network. Checked directly (not via
     *  a reach to the AC), so setup — which needs Wi-Fi for its discovery broadcast before
     *  any device, let alone credentials, exists — can gate itself on this. Kept fresh by
     *  a callback, but that depends on Android actually delivering it to this process — a
     *  missed callback (e.g. a cached process the OS is stingy with) would leave this
     *  stale forever, so callers that need an authoritative answer should poll
     *  [isWifiAvailableNow] instead of trusting this alone. */
    val wifiAvailable: StateFlow<Boolean> = _wifiAvailable

    /** Fresh, synchronous check of whether Wi-Fi is active right now, bypassing whatever
     *  [wifiAvailable] currently holds — also re-syncs it to match. */
    fun isWifiAvailableNow(): Boolean =
        (currentWifiNetwork() != null).also { _wifiAvailable.value = it }

    init {
        _wifiAvailable.value = currentWifiNetwork() != null
        connectivity?.registerNetworkCallback(
            NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(),
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    wifiNetwork = network
                    _wifiAvailable.value = true
                }
                override fun onLost(network: Network) {
                    if (wifiNetwork == network) wifiNetwork = null
                    _wifiAvailable.value = currentWifiNetwork() != null
                }
            },
        )
    }

    suspend fun refresh(): Reachability = mutex.withLock { reachLocked { it.refresh() } }

    /** Like [refresh], but skips (returns null) when another op holds the lock — for
     *  a background poll that shouldn't queue behind, or delay, a user action. */
    suspend fun tryRefresh(): Reachability? {
        if (!mutex.tryLock()) return null
        return try {
            reachLocked { it.refresh() }
        } finally {
            mutex.unlock()
        }
    }

    /** Flip power from the first reading, sending that same absolute value on every retry. */
    suspend fun togglePower(): Reachability {
        val beep = store.beepEnabled()
        return mutex.withLock {
            // Chosen once, so a retry after a lost reply doesn't flip power back.
            var desiredPowerOn: Boolean? = null
            reachLocked { client ->
                val powerOn = desiredPowerOn ?: !client.refresh().powerOn
                desiredPowerOn = powerOn
                client.update { state -> state.beep = beep; state.powerOn = powerOn }
            }
        }
    }

    /**
     * Step the setpoint by [delta] degrees from the first reading, sending that same absolute
     * value on every retry; does nothing while the AC is off or in fan-only mode.
     */
    suspend fun stepTemperature(delta: Int): Reachability {
        val beep = store.beepEnabled()
        return mutex.withLock {
            var desiredTarget: Double? = null
            reachLocked { client ->
                val target = desiredTarget ?: run {
                    val reading = client.refresh()
                    if (!reading.powerOn || reading.mode == OperationalMode.FAN_ONLY) return@reachLocked reading
                    (reading.targetTemperature + delta).coerceIn(MIN_TEMPERATURE, MAX_TEMPERATURE)
                }
                desiredTarget = target
                client.update { state -> state.beep = beep; state.targetTemperature = target }
            }
        }
    }

    suspend fun apply(change: (SetState) -> Unit): Reachability {
        val beep = store.beepEnabled()
        return mutex.withLock {
            reachLocked { client -> client.update { state -> state.beep = beep; change(state) } }
        }
    }

    /**
     * Turn the AC's display to [displayOn], toggling only when a fresh reading differs and no
     * earlier try has toggled, so a retry can't undo it.
     */
    suspend fun setDisplay(displayOn: Boolean): Reachability {
        val beep = store.beepEnabled()
        return mutex.withLock {
            // The AC reports its old state for a poll or two after a toggle, so a retry that
            // sees the old state mustn't toggle again.
            var toggled = false
            reachLocked { client ->
                val reading = client.refresh()
                if (reading.displayOn == displayOn || toggled) {
                    reading
                } else {
                    toggled = true
                    client.toggleDisplay(beep)
                }
            }
        }
    }

    /** Adopt a freshly set-up device: point the shared client at it. */
    suspend fun onSetup(creds: DeviceCredentials) = mutex.withLock {
        client?.disconnect()
        credentials = creds
        client = MideaClient(creds, CONNECT_TIMEOUT_MS, READ_TIMEOUT_MS)
    }

    /**
     * Run one of setup's blocking LAN steps with its sockets pinned to Wi-Fi, under the lock
     * every reach takes, so setup and a reach never share the AC's single connection or the
     * process's network binding. [block] gets the Wi-Fi network. Null when the phone isn't on Wi-Fi.
     */
    suspend fun <T> onLanForSetup(block: (Network) -> T): T? = mutex.withLock {
        val wifi = currentWifiNetwork() ?: return@withLock null
        withContext(Dispatchers.IO) { pinnedToWifi(wifi) { withMulticastLock { block(wifi) } } }
    }

    /**
     * Run one of setup's blocking steps that mixes the cloud and the AC under the same lock,
     * left on the default network; [block] gets the Wi-Fi network to make its AC socket on.
     * Null when the phone isn't on Wi-Fi.
     */
    suspend fun <T> onWifiSocketsForSetup(block: (Network) -> T): T? = mutex.withLock {
        val wifi = currentWifiNetwork() ?: return@withLock null
        withContext(Dispatchers.IO) { block(wifi) }
    }

    /**
     * Search [network] for ACs: a broadcast, plus a probe to every other address on its subnet,
     * since some modules answer only a probe sent to their own address. Blocks while it listens.
     */
    fun discoverOn(network: Network): List<DiscoveredDevice> =
        Discovery.discover(unicastTargets = subnetHosts(network))

    /** Every other host address on [network]'s IPv4 subnet, or none when the subnet is large or unknown. */
    private fun subnetHosts(network: Network): List<InetAddress> {
        val link = connectivity?.getLinkProperties(network)?.linkAddresses
            ?.firstOrNull { it.address is Inet4Address } ?: return emptyList()
        val prefix = link.prefixLength
        if (prefix !in MIN_SWEPT_PREFIX..MAX_SWEPT_PREFIX) return emptyList()
        val own = link.address.address.fold(0) { value, byte -> (value shl 8) or (byte.toInt() and 0xFF) }
        val mask = -1 shl (32 - prefix)
        val base = own and mask
        val size = 1 shl (32 - prefix)
        return (1 until size - 1).map { base + it }.filter { it != own }.map { host ->
            InetAddress.getByAddress(ByteArray(4) { index -> (host shr (24 - 8 * index)).toByte() })
        }
    }

    /**
     * Run one of setup's blocking cloud steps under the same lock, left on the default
     * network: the AC's Wi-Fi may have no internet, and Android then routes around it.
     */
    suspend fun <T> onInternetForSetup(block: () -> T): T = mutex.withLock {
        withContext(Dispatchers.IO) { block() }
    }

    /** Forget the device: drop the connection and cached state. */
    suspend fun forget() = mutex.withLock {
        client?.disconnect()
        client = null
        credentials = null
    }

    /** Release the socket (frees the AC's single slot) while keeping the device
     *  configured; the next reach rebuilds and reconnects. Fired by the idle-release timer
     *  after a lull so we don't hold the unit's one connection idle. */
    suspend fun release() = mutex.withLock {
        client?.disconnect()
        client = null
    }

    /**
     * Best-effort clean close of the socket when idle, for the connection service to call as
     * its keep-warm window expires. A proper disconnect while the process is still alive
     * frees the AC's single slot promptly and cleanly, rather than leaving the socket to an
     * abrupt kernel close when this cached process is later killed (which the idle-release
     * timer might never run before). No-op if a reach holds the lock or one ended less than
     * [IDLE_RELEASE_MS] ago, so it won't cut live work or the app's warm socket between its
     * polls. [MideaClient.disconnect] may write a protocol close, so this runs off the main
     * thread.
     */
    suspend fun closeIfIdle() {
        if (!mutex.tryLock()) return
        try {
            val sinceReach = lastReachAt?.let { SystemClock.elapsedRealtime() - it }
            if (sinceReach != null && sinceReach < IDLE_RELEASE_MS) return
            cancelIdleRelease()
            client?.disconnect()
            client = null
        } finally {
            mutex.unlock()
        }
    }

    private suspend fun reachLocked(op: (MideaClient) -> ACState): Reachability {
        // A reach is starting: cancel any pending idle-release so we never drop the slot
        // mid-use, and re-arm it once we're done (finally) so it frees after a lull.
        cancelIdleRelease()
        try {
            val creds = currentCredentials() ?: return Reachability.Offline
            // Without the grant, the AC's TCP connects only time out and every broadcast fails,
            // so don't spend the retry ladder finding that out.
            if (!hasLocalNetworkAccess(appContext)) return Reachability.NoLocalNetwork
            // No Wi-Fi network to pin to: the AC lives on the LAN, so there's nothing here to
            // reach and no point paying for a connect that can't route (and would only poke
            // the AC's single slot for nothing). Report it as a distinct this-side problem
            // rather than the AC being absent, and skip the reach entirely.
            val wifi = currentWifiNetwork() ?: return Reachability.NoWifi
            ensureClient(creds)
            return pinnedToWifi(wifi) { reachViaBoundNetwork(creds, op) }
        } finally {
            lastReachAt = SystemClock.elapsedRealtime()
            armIdleRelease()
        }
    }

    /** A reach is starting, so keep the slot warm: cancel a pending idle-release. */
    private fun cancelIdleRelease() {
        idleReleaseJob?.cancel()
        idleReleaseJob = null
    }

    /**
     * Arm (or re-arm) the idle-release: after [IDLE_RELEASE_MS] with no further reach, drop
     * the socket so the AC's single slot is freed for other controllers. Until then the
     * session is kept warm, so a quick app→tile→widget hop reuses it instead of racing a
     * reconnect against a slot the AC hasn't yet freed — which is what wedges the tile. The
     * next reach cancels this and re-arms it on completion, so the slot is only ever
     * released after a genuine lull, never mid-use. Runs on the manager's own [scope], so a
     * caller cancelling its reach doesn't cancel the pending release.
     */
    private fun armIdleRelease() {
        idleReleaseJob?.cancel()
        idleReleaseJob = scope.launch {
            delay(IDLE_RELEASE_MS)
            release()
        }
    }

    /**
     * Pin every socket [block] opens to the Wi-Fi network for its duration, restoring the
     * prior binding afterwards. The AC lives on the LAN, but an unbound socket follows the
     * process's default network — which Android moves to cellular whenever it decides the
     * Wi-Fi has no internet, exactly what a local-only AC network looks like. Then the LAN
     * connect isn't routable and the discovery broadcast leaves the wrong interface, so
     * both legs of a reach fail and a plainly-reachable AC reads as offline. Binding the
     * process (a coarse but process-global setting — fine here, since the AC is all this
     * app ever talks to over the network) keeps both the direct connect and the broadcast
     * on Wi-Fi. Reaches are serialized by [mutex], so the binding never races another.
     */
    private inline fun <T> pinnedToWifi(wifi: Network, block: () -> T): T {
        val previous = connectivity?.boundNetworkForProcess
        connectivity?.bindProcessToNetwork(wifi)
        return try {
            block()
        } finally {
            connectivity?.bindProcessToNetwork(previous)
        }
    }

    /** The tracked Wi-Fi network, or a synchronous scan for one if the callback that
     *  tracks it hasn't fired yet (a cold process's first reach) — or hasn't fired *at
     *  all* for a network that's since died (a missed onLost, e.g. to a cached/frozen
     *  process), which is why the cache is verified still alive rather than trusted
     *  outright. Null if there's no Wi-Fi at all, in which case a reach returns
     *  [Reachability.NoWifi] without trying. A home network is preferred over a local-only one. */
    @Suppress("DEPRECATION")
    private fun currentWifiNetwork(): Network? {
        val manager = connectivity ?: return null
        fun capabilities(network: Network) = manager.getNetworkCapabilities(network)
        fun isWifi(network: Network) = capabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        fun isHome(network: Network) =
            capabilities(network)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        wifiNetwork?.let { cached ->
            if (isWifi(cached) && isHome(cached)) return cached
            wifiNetwork = null
        }
        val networks = manager.allNetworks.filter(::isWifi)
        return (networks.firstOrNull(::isHome) ?: networks.firstOrNull())?.also { wifiNetwork = it }
    }

    private suspend fun reachViaBoundNetwork(
        creds: DeviceCredentials,
        op: (MideaClient) -> ACState,
    ): Reachability {
        // Step 1 — reach the AC at its last-known address. Most often it's still there
        // and a first miss is transient: a cold-launched process (a tile tap) wakes the
        // Wi-Fi radio from power-save and its first TCP connect can be dropped, or the
        // unit's single socket slot was briefly held by a just-closed connection. Retry
        // the direct connection a few times with backoff before paying for discovery —
        // reconnecting to the known address is cheaper and far more reliable than a
        // broadcast probe from a freshly-spawned process, which is easily lost.
        attempt(op)?.let { return online(it) }
        var backoff = BUSY_BACKOFF_MS
        repeat(BUSY_RETRIES) {
            delay(backoff)
            attempt(op)?.let { return online(it) }
            backoff *= 2
        }

        // Step 2 — the known address never answered. UDP fan-out to discover where it
        // moved (different network or DHCP lease); retry the broadcast a few rounds since
        // a single dropped probe isn't proof of absence. No answer across every round
        // means it really is gone.
        val located = locateWithRetry(creds) ?: return Reachability.Offline

        // Discovery confirms the AC is present — here, or at a new address we now point
        // to. If we still can't open a session its single TCP slot is momentarily held,
        // most often because we just released our own on backgrounding and the unit hasn't
        // freed it yet. Now that we KNOW it's there, first retry the direct connect a couple
        // of times with backoff (cheap — no repeated discovery) to catch a slot that frees
        // quickly.
        if (located != creds) rebuildClient(located)
        var slotBackoff = BUSY_BACKOFF_MS
        repeat(BUSY_RETRIES + 1) { index ->
            attempt(op)?.let { return online(it) }
            if (index < BUSY_RETRIES) {
                delay(slotBackoff)
                slotBackoff *= 2
            }
        }

        // Still no session though the AC is plainly there: the slot is held, and our own
        // rapid reconnects may be re-arming that hold (each SYN looks like a new session the
        // unit has to reject, resetting its lazy-free timer). Stop poking it — rebuild a
        // fresh client so the old socket is fully closed and the unit sees us gone, then
        // wait one long QUIET window with no attempts at all so its free can actually
        // complete, and make a single clean attempt before conceding Busy.
        rebuildClient(located)
        delay(QUIET_GAP_MS)
        attempt(op)?.let { return online(it) }
        return Reachability.Busy
    }

    private suspend fun attempt(op: (MideaClient) -> ACState): ACState? {
        val active = client ?: return null
        return withContext(Dispatchers.IO) {
            runCatching { op(active) }.getOrNull()
        }
    }

    private fun online(state: ACState): Reachability {
        store.saveLastState(state)
        return Reachability.Online(state)
    }

    private fun currentCredentials(): DeviceCredentials? {
        credentials?.let { return it }
        return store.load()?.also { credentials = it }
    }

    private fun ensureClient(creds: DeviceCredentials) {
        if (client == null) client = MideaClient(creds, CONNECT_TIMEOUT_MS, READ_TIMEOUT_MS)
    }

    private fun rebuildClient(creds: DeviceCredentials) {
        client?.disconnect()
        client = MideaClient(creds, CONNECT_TIMEOUT_MS, READ_TIMEOUT_MS)
        credentials = creds
    }

    /**
     * Discover the device, retrying the broadcast a few rounds so a single dropped
     * probe (a cold radio waking from power-save) doesn't read as absent. Returns null
     * only after every round comes up empty — then the AC really isn't on this network.
     */
    private suspend fun locateWithRetry(creds: DeviceCredentials): DeviceCredentials? {
        repeat(LOCATE_ATTEMPTS) { attemptIndex ->
            locate(creds)?.let { return it }
            if (attemptIndex < LOCATE_ATTEMPTS - 1) delay(LOCATE_BACKOFF_MS)
        }
        return null
    }

    /**
     * Discover the device on the current network; if its address changed, persist and
     * return the update. Returns null if it isn't present on this network.
     */
    private suspend fun locate(creds: DeviceCredentials): DeviceCredentials? =
        withContext(Dispatchers.IO) {
            val wifi = currentWifiNetwork()
            val match = withMulticastLock {
                runCatching { if (wifi != null) discoverOn(wifi) else Discovery.discover() }.getOrNull()
                    ?.firstOrNull { it.id == creds.id }
            } ?: return@withContext null
            val moved = creds.copy(ip = match.ip, port = match.port)
            when {
                match.ip == creds.ip && match.port == creds.port -> creds
                // Forgotten, or set up again, while the search listened.
                store.replaceSameDevice(moved) -> moved
                else -> null
            }
        }

    private fun <T> withMulticastLock(block: () -> T): T {
        val wifi = appContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val lock = wifi.createMulticastLock("drift-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
        return try {
            block()
        } finally {
            lock.release()
        }
    }

    private companion object {
        // Snappy ceilings so a stale address fails fast into rediscovery; a warm
        // reused session answers well under these anyway.
        const val CONNECT_TIMEOUT_MS = 2500
        const val READ_TIMEOUT_MS = 3500
        const val BUSY_RETRIES = 2
        // The AC's Wi-Fi module frees its single TCP slot lazily — after a teardown the
        // slot can stay held for a second or more. Sub-second retries all land while it's
        // still occupied, burning the whole ladder inside one second; spacing attempts
        // ~1s/2s apart gives the slot time to free before we concede Busy.
        const val BUSY_BACKOFF_MS = 1_000L
        // One long silent window before the final reconnect when the AC is present but its
        // slot is still held: no connection attempts during it, so the unit's lazy free can
        // finish without our retries re-arming the hold.
        const val QUIET_GAP_MS = 5_000L
        // Keep the socket warm this long after the last reach, then drop it to free the AC's
        // single slot for other controllers. Comfortably above the foreground poll interval
        // (5s) so an active app never thrashes connect/release, yet short enough that a
        // backgrounded app lets go within a minute — and long enough to span an app→tile→
        // widget hop so those reuse the warm session instead of racing a reconnect.
        const val IDLE_RELEASE_MS = 45_000L
        // Discovery broadcast rounds before conceding the AC is absent. The first probe
        // from a cold-woken radio is easily lost, so one empty round isn't conclusive.
        const val LOCATE_ATTEMPTS = 2
        const val LOCATE_BACKOFF_MS = 250L
        // Subnets swept host by host during discovery: from a /22 (about a thousand hosts) down.
        const val MIN_SWEPT_PREFIX = 22
        const val MAX_SWEPT_PREFIX = 30
    }
}
