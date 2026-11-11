package cc.hafa.drift

import android.content.Context
import android.os.SystemClock
import io.hafa.mideakt.DeviceCredentials
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlin.coroutines.CoroutineContext

/** Where first-run setup stands. */
sealed interface SetupPhase {
    /** Nothing running or waiting. */
    data object Idle : SetupPhase

    /** A setup step is in progress. */
    data class Running(val step: SetupStep) : SetupPhase

    /** The last attempt failed; the next starts on its own at [retryAt] ([SystemClock.elapsedRealtime]). */
    data class Waiting(override val failure: SetupFailure, val retryAt: Long) : SetupPhase

    /** The last attempt failed and nothing will retry it until the user acts. */
    data class Failed(override val failure: SetupFailure) : SetupPhase

    /** The failure being shown, if any. */
    val failure: SetupFailure?
        get() = null
}

/** Everything the setup screen shows. */
data class SetupState(
    /** Where setup stands. */
    val phase: SetupPhase = SetupPhase.Idle,
    /** The Midea account; never saved, and cleared once setup ends. */
    val account: CloudAccount = CloudAccount(),
)

/**
 * Runs first-run setup for every screen that shows it, so the app and the quick controls
 * share one attempt rather than racing two. After the user's first "Set Up", it retries on
 * its own with growing pauses until it succeeds, no setup screen is showing, or a failure
 * comes that retrying can't fix; each retry keeps the AC already found
 * rather than searching again.
 */
class SetupController internal constructor(
    private val flow: SetupFlow,
    private val saved: () -> DeviceCredentials?,
    private val save: suspend (DeviceCredentials) -> Unit,
    dispatcher: CoroutineContext = Dispatchers.Main,
    private val clock: () -> Long = SystemClock::elapsedRealtime,
) {
    /** Set up through the real network, saving to the [CredentialStore] and handing each device to [devices]. */
    constructor(context: Context, devices: DeviceManager) : this(CredentialStore(context), context, devices)

    private constructor(store: CredentialStore, context: Context, devices: DeviceManager) : this(
        flow = SetupFlow(LiveSetupNetwork(context.applicationContext, devices)),
        saved = store::load,
        save = { credentials ->
            store.save(credentials)
            store.saveNickname("")
            devices.onSetup(credentials)
        },
    )

    // A Job in [dispatcher] becomes the parent, so whoever owns it can stop all of setup's work.
    private val scope = CoroutineScope(dispatcher + SupervisorJob(dispatcher[Job]))
    private val _state = MutableStateFlow(SetupState())
    private val _finished = MutableSharedFlow<DeviceCredentials>(extraBufferCapacity = 1)
    private var job: Job? = null
    // Whether automatic setup should run while a setup screen shows; false before the first
    // "Set Up", after a failure retrying can't fix, and once set up.
    private var autoSetup = false
    // What earlier attempts got, so a retry doesn't search again.
    private var memory = SetupMemory()
    private var visibleScreens = 0
    private var pendingPause: Job? = null

    /** What the setup screens show. */
    val state: StateFlow<SetupState> = _state

    /** Each device set up, saved and handed to the [DeviceManager] already. */
    val finished: SharedFlow<DeviceCredentials> = _finished

    /** Start setup with the Midea account, and check the key locally, retrying until it works. */
    fun start() {
        if (saved() != null || !_state.value.account.isComplete) return
        autoSetup = true
        if (job != null) return
        job = scope.launch { retry() }
    }

    /** A setup screen came on-screen: resume automatic setup if it was running. */
    fun resume() {
        visibleScreens += 1
        pendingPause?.cancel()
        pendingPause = null
        if (autoSetup) start()
    }

    /** A setup screen went away: pause automatic setup once none has shown for a moment. */
    fun pause() {
        visibleScreens = maxOf(0, visibleScreens - 1)
        if (visibleScreens > 0 || !autoSetup || pendingPause != null) return
        // A rotation or a hop between the app and the quick controls drops every screen
        // briefly; waiting out that gap keeps the current try and the retry wait going.
        pendingPause = scope.launch {
            delay(PAUSE_GRACE_MS)
            pendingPause = null
            if (visibleScreens == 0 && autoSetup) cancelJob()
        }
    }

    /** Change the Midea account fields. */
    fun editAccount(edit: (CloudAccount) -> CloudAccount) {
        _state.update { it.copy(account = edit(it.account)) }
    }

    /** Stop everything and start over from a blank setup screen, as after forgetting the device. */
    fun reset() {
        job?.cancel()
        job = null
        autoSetup = false
        memory = SetupMemory()
        _state.value = SetupState()
    }

    private suspend fun retry() {
        var failures = 0
        while (true) {
            // Read each attempt, so edits made while a retry waits are used.
            val account = _state.value.account
            SetupLog.info("Setting up")
            try {
                val credentials = flow.run(account, memory, ::progress) { memory = it }
                finish(credentials)
                return
            } catch (error: SetupFailedException) {
                SetupLog.error("Failed: ${error.failure.message} (${error.failure.hint})")
                if (!error.failure.retries) {
                    stop(error.failure)
                    return
                }
                val pause = RETRY_DELAYS_MS[minOf(failures, RETRY_DELAYS_MS.size - 1)]
                failures += 1
                setPhase(SetupPhase.Waiting(error.failure, clock() + pause))
                delay(pause)
            }
        }
    }

    /** End automatic setup on a [failure] that retrying can't fix. */
    private fun stop(failure: SetupFailure) {
        autoSetup = false
        setPhase(SetupPhase.Failed(failure))
        job = null
    }

    private fun progress(step: SetupStep) {
        SetupLog.info("Step: $step")
        setPhase(SetupPhase.Running(step))
    }

    private fun setPhase(phase: SetupPhase) = _state.update { it.copy(phase = phase) }

    /** Stop any attempt or pending retry, leaving its failure on screen. */
    private fun cancelJob() {
        job?.cancel()
        job = null
        _state.update {
            when (val phase = it.phase) {
                is SetupPhase.Running -> it.copy(phase = SetupPhase.Idle)
                is SetupPhase.Waiting -> it.copy(phase = SetupPhase.Failed(phase.failure))
                else -> it
            }
        }
    }

    private suspend fun finish(credentials: DeviceCredentials) {
        job = null
        autoSetup = false
        memory = SetupMemory()
        save(credentials)
        _state.value = SetupState()
        _finished.emit(credentials)
    }

    private companion object {
        // The AC frees its single connection slot lazily, so retries back off rather than
        // keep it busy; the last pause repeats.
        val RETRY_DELAYS_MS = listOf(5_000L, 10_000L, 20_000L, 30_000L)
        const val PAUSE_GRACE_MS = 2_000L
    }
}
