package cc.hafa.drift

import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Quick Settings tile that toggles the AC's power and reflects its state.
 *
 * The AC accepts one TCP connection at a time and frees it lazily, so the tile leans on
 * [DriftConnectionService] to keep the app process — and thus the DeviceManager's single
 * warm socket — alive for a short window whenever the tile is shown or tapped. Every reach
 * then reuses that live session instead of cold-reconnecting into a slot the unit hasn't
 * freed, which is what used to wedge a rapid re-pull (the tile's process is otherwise
 * killed the moment the panel closes, taking the socket with it).
 *
 * The tile only ever shows a confirmed reading, and is tappable only once a live On/Off is
 * confirmed — never a cached guess presented as toggleable.
 */
class DriftTileService : TileService() {

    /** What the tile shows. While a reach is in flight the tile is `CONNECTING` (a wordless
     *  spinner); it then flips exactly once — and only when certain — to a resolved state:
     *  a confirmed `ON`/`OFF`; `BUSY` when the AC is present on the network but its one
     *  connection slot is taken, so we couldn't open a session (present, not gone);
     *  `DISCONNECTED` when it isn't on the network at all; or `NO_WIFI` when the phone has
     *  no Wi-Fi. The connecting → resolved change is the only icon transition. (`NO_DEVICE`
     *  sends the user to the app: not set up yet, or local network access not granted.) */
    private enum class Status { NO_DEVICE, CONNECTING, ON, OFF, DISCONNECTED, NO_WIFI, BUSY }

    private fun devices() = DriftApplication.devices(applicationContext)

    override fun onStartListening() {
        super.onStartListening()
        current = this
        render(Status.CONNECTING)
        if (reachJob?.isActive == true) {
            // A reach (or its retry loop) from an earlier open is still running and paints
            // this tile when it resolves; just stretch the warm hold over this open.
            DriftConnectionService.keepWarm(this)
        } else {
            reach { devices().refresh() }
        }
    }

    override fun onStopListening() {
        super.onStopListening()
        // Only clear if a newer instance hasn't already taken over as `current`. The socket
        // is deliberately NOT closed here — the connection service keeps it warm across the
        // panel close, and the DeviceManager's idle-release frees it after the grace window.
        if (current === this) {
            current = null
            // The system shows its cached copy of the tile the next time the panel opens,
            // until this service is bound and repaints. Leave that copy on the spinner, so a
            // reading from an earlier open is never shown before the new reach replaces it.
            render(Status.CONNECTING)
        }
    }

    override fun onClick() {
        super.onClick()
        reach { devices().togglePower() }
    }

    /**
     * Run one reach: show `CONNECTING`, then resolve once — and only once we're certain — to
     * a confirmed state. While the panel is open, a reach that can't get a live reading
     * (Busy/Disconnected) doesn't settle on that; it keeps the spinner and re-reads gently
     * (bounded, with quiet gaps that won't re-arm the AC's slot hold) so a tile the user
     * pulled down to wait on reconnects rather than flashing "Disconnected". The re-reads
     * live inside the one job, so no second reach can slip in between them, and a tap can't
     * act while one is in flight. Main thread only.
     */
    private fun reach(op: suspend () -> Reachability) {
        if (reachJob?.isActive == true) return
        render(Status.CONNECTING)
        reachJob = scope.launch {
            // The encrypted credential read can take a while on a cold process; keep it off
            // the main thread, where it would hold back every other tile callback.
            val configured = withContext(Dispatchers.IO) { CredentialStore(applicationContext).load() != null }
            if (!configured) {
                current?.render(Status.NO_DEVICE)
                return@launch
            }
            // Keep the process (and its warm socket) alive for a grace window, so this reach
            // — and a follow-up tap or re-pull — reuses the live session instead of
            // reconnecting, and a toggle finishes even if the panel collapses.
            DriftConnectionService.keepWarm(applicationContext)
            var status = resolve(op)
            var retries = 0
            while ((status == Status.BUSY || status == Status.DISCONNECTED) && retries < MAX_RETRIES) {
                delay(RETRY_GAP_MS)
                // Panel closed: stop quietly; the tile was left on the spinner.
                if (current == null) return@launch
                // Re-read rather than repeat `op`: a toggle that timed out may have landed,
                // and sending it again would flip the AC back.
                status = resolve { devices().refresh() }
                retries++
            }
            current?.render(status)
        }
    }

    private suspend fun resolve(op: suspend () -> Reachability): Status =
        withContext(Dispatchers.IO) {
            // Backstop deadline so a pile-up on the manager's mutex (e.g. a Wi-Fi resync)
            // can't pin the spinner for minutes; the ladder resolves well under this.
            when (val result = withTimeoutOrNull(REACH_BUDGET_MS) { op() }) {
                is Reachability.Online -> if (result.state.powerOn) Status.ON else Status.OFF
                // Present on the network but its one slot is taken (most often by our own
                // just-closed socket): it's THERE, not gone — "In use", not Disconnected.
                is Reachability.Busy -> Status.BUSY
                // Discovery found nothing on the network at all: genuinely absent.
                is Reachability.Offline -> Status.DISCONNECTED
                // Phone isn't on Wi-Fi — a this-side problem, shown apart from Disconnected.
                is Reachability.NoWifi -> Status.NO_WIFI
                // Only the app can ask for the grant, so point there like an unconfigured tile.
                is Reachability.NoLocalNetwork -> Status.NO_DEVICE
                // Ran out of time mid-reach; discovery had already found it present, so
                // it's present-but-busy too — BUSY, not Disconnected.
                null -> Status.BUSY
            }
        }

    // Returns whether the paint landed: `false` when no tile is bound (`qsTile` null); `true`
    // once `updateTile()` has run.
    // One function by design: it maps the whole Status enum onto the tile's fields in one
    // place, so the several state/icon/label whens branch on the same value together.
    @Suppress("CyclomaticComplexMethod")
    private fun render(status: Status): Boolean {
        val tile = qsTile ?: return false
        // Only a confirmed live On/Off is interactive; every other status is unavailable,
        // which greys the tile and blocks taps — so we never present an un-actionable state
        // as tappable.
        tile.state = when (status) {
            Status.ON -> Tile.STATE_ACTIVE
            Status.OFF -> Tile.STATE_INACTIVE
            else -> Tile.STATE_UNAVAILABLE
        }
        // The sync spinner marks a reach in progress; otherwise the AC icon. (Quick
        // Settings won't animate a vector, so the swap is static.)
        val iconRes = if (status == Status.CONNECTING) R.drawable.ic_tile_sync else R.drawable.ic_tile
        tile.icon = Icon.createWithResource(this, iconRes)
        val detail = when (status) {
            Status.NO_DEVICE -> "Set up in app"
            // Blank rather than null: with no subtitle, Quick Settings fills in its own
            // "Unavailable" under the spinner, which reads as a failure while still connecting.
            Status.CONNECTING -> " "
            Status.ON -> "On"
            Status.OFF -> "Off"
            Status.NO_WIFI -> "No Wi-Fi"
            // Present on the network but its one slot is taken.
            Status.BUSY -> "In use"
            Status.DISCONNECTED -> "Disconnected"
        }
        // Subtitle (API 29+) carries the nuance under a stable "Drift" label; older
        // releases have no subtitle, so fold it into the label instead.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.label = "Drift"
            tile.subtitle = detail
        } else {
            tile.label = when (status) {
                Status.ON -> "Drift On"
                Status.OFF -> "Drift Off"
                Status.CONNECTING -> "Drift"
                else -> "Drift — $detail"
            }
        }
        tile.updateTile()
        return true
    }

    companion object {
        // Process-lifetime, so a tap's toggle (and the retry loop) still finishes if the
        // panel collapses and the service instance is torn down mid-flight. Main-dispatched
        // so `reachJob` and `current` are only touched on the main thread.
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        // The reach (with its retries) in flight, if any; one at a time per process.
        private var reachJob: Job? = null
        // The currently-bound tile instance (or null when no panel is showing it), so a
        // reach's result repaints the live tile even if the instance that started it was
        // torn down, and so the retry loop stops once the panel closes. Written on the main
        // thread in onStart/onStopListening.
        private var current: DriftTileService? = null
        // Backstop deadline for a single reach.
        private const val REACH_BUDGET_MS = 30_000L
        // Gentle bounded retry while the panel is open: wait out a busy/held slot instead of
        // showing Disconnected. Gaps are long enough not to re-arm the AC's slot hold.
        private const val MAX_RETRIES = 5
        private const val RETRY_GAP_MS = 4_000L
    }
}
