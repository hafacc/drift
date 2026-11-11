package cc.hafa.drift

import android.app.Application
import androidx.glance.appwidget.updateAll
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.hafa.mideakt.ACState
import io.hafa.mideakt.DeviceCredentials
import io.hafa.mideakt.SetState
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** Whether we currently have a live connection to the AC. */
enum class Connection { Connecting, Connected, Disconnected, NoWifi }

data class UiState(
    val needsSetup: Boolean = false,
    val discoveredName: String = "",
    val serialNumber: String? = null,
    val nickname: String = "",
    val state: ACState? = null,
    val targetOverride: Double? = null,
    val beepEnabled: Boolean = true,
    val busy: Boolean = false,
    // Set while a refresh from [DeviceViewModel.refresh] runs, for the pull-to-refresh indicator.
    val refreshing: Boolean = false,
    val connection: Connection = Connection.Connecting,
    // Optimistic default so setup's Wi-Fi gate doesn't flash disabled before the
    // manager's first real reading lands.
    val wifiAvailable: Boolean = true,
) {
    val displayName: String
        get() = nickname.ifBlank { discoveredName.ifBlank { "AC" } }

    /** Shown setpoint: the pending (optimistic) value while adjusting, else live. */
    val displayedTarget: Double?
        get() = targetOverride ?: state?.targetTemperature
}

/**
 * Drives the foreground UI. All device I/O goes through the shared [DeviceManager], so
 * the app, tile, and widget never open competing connections to the AC's single slot.
 * The manager serializes access; the poll loop skips (tryRefresh) when an action holds
 * it, so a user tap is never delayed by a poll. Temperature changes are debounced.
 */
class DeviceViewModel(application: Application) : AndroidViewModel(application) {
    private val store = CredentialStore(application)
    private val devices = DriftApplication.devices(application)
    private var credentials = store.load()
    private var temperatureJob: Job? = null
    private var pollJob: Job? = null
    private var beep = store.beepEnabled()
    private val setupController = DriftApplication.setup(application)
    // Whether this view model's screen is on-screen, so a device set up meanwhile starts polling.
    private var foreground = false

    private val _ui = MutableStateFlow(
        UiState(
            needsSetup = credentials == null,
            discoveredName = credentials?.name ?: "",
            serialNumber = credentials?.serialNumber,
            nickname = store.nickname(),
            beepEnabled = beep,
        ),
    )
    val ui: StateFlow<UiState> = _ui

    /** First-run setup's progress, shared with every other setup screen. */
    val setup: StateFlow<SetupState> = setupController.state

    init {
        // Independent of any device/reach, so this is live even pre-setup: gates the
        // Setup button on Wi-Fi being up (setup's discovery broadcast needs it). This
        // callback-driven flow is the live signal while a screen is actually on-screen and
        // this process isn't frozen; see refreshWifiStatus for the complementary one-shot
        // recheck that covers the case where a callback got missed while backgrounded.
        viewModelScope.launch {
            devices.wifiAvailable.collect { available -> _ui.update { it.copy(wifiAvailable = available) } }
        }
        viewModelScope.launch { setupController.finished.collect(::adopt) }
    }

    /** One-shot, synchronous recheck of Wi-Fi status — call this when a setup screen
     *  becomes visible (e.g. on resume), rather than trusting [DeviceManager.wifiAvailable]
     *  alone: that's callback-driven, and a cached/frozen process can miss the callback
     *  for a Wi-Fi change that happened while it wasn't looking, leaving it stale with no
     *  self-correction until something explicitly asks again. */
    fun refreshWifiStatus() {
        _ui.update { it.copy(wifiAvailable = devices.isWifiAvailableNow()) }
    }

    /** Poll while the app is in the foreground; release the connection otherwise. */
    fun startPolling() {
        foreground = true
        if (pollJob != null || credentials == null) return
        pollJob = viewModelScope.launch {
            while (isActive) {
                devices.tryRefresh()?.let { applyPoll(it) }
                delay(POLL_INTERVAL_MS)
            }
        }
    }

    fun stopPolling() {
        foreground = false
        cancelPolling()
        // Don't release the socket here. The DeviceManager's idle-release timer frees the
        // AC's slot after a short grace instead, so a quick background→tile hop reuses the
        // warm session rather than racing a reconnect against a slot the unit hasn't freed.
    }

    /** Start setup with the Midea account: the user's tap. */
    fun setup() = setupController.start()

    /** Change the Midea account fields. */
    fun editAccount(edit: (CloudAccount) -> CloudAccount) = setupController.editAccount(edit)

    /** A setup screen came on-screen: resume automatic setup if it was running. */
    fun resumeSetup() = setupController.resume()

    /** A setup screen went away: pause automatic setup once none is showing. */
    fun pauseSetup() = setupController.pause()

    /** Read the AC again, marking the page as refreshing until it answers. */
    fun refresh() {
        viewModelScope.launch {
            _ui.update { it.copy(busy = true, refreshing = true) }
            try {
                applyReach(devices.refresh())
            } finally {
                _ui.update { it.copy(refreshing = false) }
            }
        }
    }

    fun apply(change: (SetState) -> Unit) = launchAction { devices.apply(change) }
    /** Flip the AC's display from the shown reading. */
    fun toggleDisplay() {
        val displayOn = !(_ui.value.state?.displayOn ?: return)
        launchAction { devices.setDisplay(displayOn) }
    }

    fun setBeep(enabled: Boolean) {
        beep = enabled
        store.saveBeep(enabled)
        _ui.update { it.copy(beepEnabled = enabled) }
    }

    /** Optimistically adjust the setpoint now; send the result after a pause. */
    fun adjustTemperature(delta: Int) {
        val current = _ui.value.displayedTarget ?: return
        setTemperature(current + delta)
    }

    /** Like [adjustTemperature], but to an absolute setpoint (e.g. dragged on the dial). */
    fun setTemperature(requested: Double) {
        val target = requested.coerceIn(MIN_TEMPERATURE, MAX_TEMPERATURE)
        if (target == _ui.value.displayedTarget) return
        _ui.update { it.copy(targetOverride = target) }
        temperatureJob?.cancel()
        temperatureJob = viewModelScope.launch {
            delay(600)
            applyReach(devices.apply { it.targetTemperature = target })
            // Only clear if a newer adjustment hasn't superseded this one.
            if (_ui.value.targetOverride == target) _ui.update { it.copy(targetOverride = null) }
        }
    }

    fun setNickname(nickname: String) {
        store.saveNickname(nickname)
        _ui.update { it.copy(nickname = nickname) }
    }

    /** Disconnect and forget the device: delete its credentials and return to setup,
     *  then repaint the widget so it stops showing a stale reading. */
    fun forget() {
        cancelPolling()
        store.clear()
        credentials = null
        setupController.reset()
        _ui.value = UiState(needsSetup = true, beepEnabled = beep)
        viewModelScope.launch {
            devices.forget()
            DriftWidget().updateAll(getApplication())
        }
    }

    /** Show a device just set up here or on another screen, which has already saved it. */
    private fun adopt(device: DeviceCredentials) {
        credentials = device
        _ui.update {
            it.copy(
                needsSetup = false, discoveredName = device.name, serialNumber = device.serialNumber, nickname = "",
            )
        }
        if (foreground) startPolling()
        refresh()
    }

    private fun cancelPolling() {
        pollJob?.cancel()
        pollJob = null
    }

    /** Run a user-initiated op: show busy, then reflect the reachability result. */
    private fun launchAction(operation: suspend () -> Reachability) {
        viewModelScope.launch {
            _ui.update { it.copy(busy = true) }
            applyReach(operation())
        }
    }

    private fun applyReach(reach: Reachability) {
        _ui.update {
            when (reach) {
                is Reachability.Online ->
                    it.copy(state = reach.state, busy = false, connection = Connection.Connected)
                is Reachability.NoWifi ->
                    it.copy(busy = false, connection = Connection.NoWifi)
                else ->
                    it.copy(busy = false, connection = Connection.Disconnected)
            }
        }
        // A user action just changed (or confirmed) the state — repaint the widget off
        // the manager's freshly-saved LastState, mirroring the macOS reloadWidget path,
        // so it doesn't sit stale for up to the 30-min system update period.
        if (reach is Reachability.Online) repaintWidget()
    }

    /** A background poll: update connection/state without touching the busy flag. */
    private fun applyPoll(reach: Reachability) {
        val changed = reach is Reachability.Online && reach.state != _ui.value.state
        _ui.update {
            when (reach) {
                is Reachability.Online -> it.copy(state = reach.state, connection = Connection.Connected)
                is Reachability.NoWifi -> it.copy(connection = Connection.NoWifi)
                else -> it.copy(connection = Connection.Disconnected)
            }
        }
        // Only nudge the widget when the glanceable state actually moved (e.g. someone
        // toggled the unit elsewhere) — not every poll tick.
        if (changed) repaintWidget()
    }

    private fun repaintWidget() {
        viewModelScope.launch { DriftWidget().updateAll(getApplication()) }
    }

    private companion object {
        const val POLL_INTERVAL_MS = 5000L
    }
}

// Selectable setpoint range, shared by the app's dial and the widget's steppers. The floor
// matches the protocol library's own clamp (mideakt SetState.encode coerces to 17–30);
// offering 16 in the UI only to have the device snap back to 17 is a lie, so the ends are
// kept in agreement here.
const val MIN_TEMPERATURE = 17.0
const val MAX_TEMPERATURE = 30.0
