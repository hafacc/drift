package cc.hafa.drift

import io.hafa.mideakt.CloudException
import io.hafa.mideakt.CloudLoginException
import io.hafa.mideakt.DeviceCredentials
import io.hafa.mideakt.DeviceNotInAccountException
import io.hafa.mideakt.DiscoveredDevice
import io.hafa.mideakt.HandshakeRejectedException
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive

/** The Midea account setup signs in to for the AC's key, held only in memory. */
data class CloudAccount(
    /** The account's email address. */
    val email: String = "",
    /** The account's password. */
    val password: String = "",
) {
    /** Whether both fields are filled in. */
    val isComplete: Boolean get() = email.isNotBlank() && password.isNotEmpty()

    override fun toString(): String = "CloudAccount(email=$email)"
}

/** The setup step currently running, worded for the setup screen. */
sealed interface SetupStep {
    /** Searching the network for an AC. */
    data object Searching : SetupStep

    /** Signing in to Midea's cloud. */
    data object SigningIn : SetupStep

    /** Getting the key and checking it with the AC itself, on try [attempt] of [total]. */
    data class Checking(val attempt: Int, val total: Int) : SetupStep

    /** Short progress text for the setup screen. */
    val message: String
        get() = when (this) {
            Searching -> "Searching the network…"
            SigningIn -> "Signing in to Midea's cloud…"
            is Checking -> if (attempt == 1) "Checking the AC…" else "Checking the AC (try $attempt of $total)…"
        }
}

/** A failed setup step: what went wrong and what to do about it. */
data class SetupFailure(
    /** What failed, in plain words. */
    val message: String,
    /** What the user can do next. */
    val hint: String,
    /** Whether trying the same step again later could get past this failure on its own. */
    val retries: Boolean = true,
)

/** Thrown by [SetupFlow] when a step fails. */
class SetupFailedException(val failure: SetupFailure) : Exception(failure.message)

/** What earlier setup attempts got, so a retry doesn't search again. */
data class SetupMemory(
    /** The AC found on the home network. */
    val device: DiscoveredDevice? = null,
)

/** How the AC took a set of credentials. */
enum class CheckResult {
    /** It answered with them. */
    ANSWERED,

    /** It didn't answer: busy, slow, or not there. */
    SILENT,

    /** It turned the key down. */
    REJECTED,
}

/** Thrown by [SetupCloud.credentials] when the request to Midea's cloud didn't get through. */
internal class CloudUnreachableException(cause: IOException) : IOException(cause.message, cause)

/** The network operations setup is built from, kept apart so tests can stand in for them. */
internal interface SetupNetwork {
    /** Whether Drift may use the local network. */
    fun hasLocalNetworkAccess(): Boolean

    /** One search of the home network, or null when the phone isn't on Wi-Fi. */
    suspend fun discover(): List<DiscoveredDevice>?

    /** A fresh connection to Midea's cloud for [account]. */
    fun cloud(account: CloudAccount): SetupCloud

    /** How a version-2 AC takes [credentials], or null when the phone isn't on Wi-Fi. */
    suspend fun check(credentials: DeviceCredentials): CheckResult?
}

/** One connection to Midea's cloud, as setup uses it. */
internal interface SetupCloud {
    /** Sign in, throwing [CloudLoginException] when the cloud refuses the account. */
    suspend fun login()

    /**
     * The version-3 [device]'s credentials, fetched from the cloud and accepted by the AC, or null
     * when the phone isn't on Wi-Fi. Throws [DeviceNotInAccountException], [CloudUnreachableException],
     * another [CloudException], or whatever stopped the AC from taking the key.
     */
    suspend fun credentials(device: DiscoveredDevice): DeviceCredentials?
}

/**
 * First-run setup, one step at a time so the screen can say which step is running and
 * which one failed: find the AC, sign in to Midea's cloud, then get the key and check it with
 * the AC itself, every network step going through [network].
 */
internal class SetupFlow(private val network: SetupNetwork) {
    /**
     * Set up with [account], reusing the AC [memory] says an earlier attempt found, reporting each
     * step to [progress] and each thing learned to [remember].
     */
    suspend fun run(
        account: CloudAccount,
        memory: SetupMemory,
        progress: (SetupStep) -> Unit,
        remember: (SetupMemory) -> Unit,
    ): DeviceCredentials {
        val device = memory.device ?: run {
            progress(SetupStep.Searching)
            discover().also { remember(memory.copy(device = it)) }
        }

        if (device.version < 3) {
            // Version 2 needs no key.
            val credentials = DeviceCredentials(device)
            return checkRepeatedly(
                progress,
                SetupFailure(
                    message = "Found the AC, but it didn't answer.",
                    hint = "Another device may be connected to it. Close the app there.",
                ),
            ) { check(credentials) }
        }

        progress(SetupStep.SigningIn)
        val cloud = network.cloud(account)
        signIn(cloud)
        return checkRepeatedly(
            progress,
            SetupFailure(
                message = "Found the AC and got its key, but the AC didn't answer.",
                hint = "Another device may be connected to it. Close the app there.",
            ),
        ) { fetchAndCheck(cloud, device) }
    }

    private suspend fun discover(): DiscoveredDevice {
        // A search right after the local network grant, or from a radio waking from power-save,
        // is easily lost, so one empty round isn't conclusive.
        repeat(DISCOVERY_ROUNDS) {
            currentCoroutineContext().ensureActive()
            requireLan()
            val found = network.discover() ?: fail(noWifi())
            found.minByOrNull { it.id }?.let { return it }
        }
        fail(
            SetupFailure(
                message = "Couldn't find an AC on this network.",
                hint = "Make sure this phone is on the AC's Wi-Fi.",
            ),
        )
    }

    // The broad catch tells a refused sign-in apart from every way of not reaching the cloud.
    @Suppress("TooGenericExceptionCaught")
    private suspend fun signIn(cloud: SetupCloud) {
        val failure = try {
            cloud.login()
            null
        } catch (refused: CloudLoginException) {
            SetupFailure(
                message = "Midea didn't accept that email and password.",
                hint = "Midea said: ${refused.message} (${refused.code}). Check them, then tap Set Up again.",
                retries = false,
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: IOException) {
            unreachable()
        } catch (_: Exception) {
            SetupFailure(
                message = "Couldn't sign in to Midea's cloud.",
                hint = "Try again later.",
            )
        }
        if (failure != null) fail(failure)
    }

    /** The version-2 AC's [credentials] if it answers with them, or null if it doesn't. */
    private suspend fun check(credentials: DeviceCredentials): DeviceCredentials? =
        when (network.check(credentials) ?: fail(noWifi())) {
            CheckResult.ANSWERED -> credentials
            CheckResult.REJECTED -> {
                SetupLog.info("The AC turned down the key")
                null
            }
            CheckResult.SILENT -> null
        }

    // The broad catch treats every other error as the AC not answering.
    /** The version-3 [device]'s credentials from [cloud] once the AC takes them, or null if it doesn't. */
    @Suppress("TooGenericExceptionCaught")
    private suspend fun fetchAndCheck(cloud: SetupCloud, device: DiscoveredDevice): DeviceCredentials? =
        try {
            cloud.credentials(device)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: DeviceNotInAccountException) {
            fail(
                SetupFailure(
                    message = "This AC isn't in that Midea account.",
                    hint = "Sign in with the account the AC was set up in, then tap Set Up again.",
                    retries = false,
                ),
            )
        } catch (_: HandshakeRejectedException) {
            fail(
                SetupFailure(
                    message = "The AC turned down the key from Midea's cloud.",
                    hint = "Make sure the AC is in this Midea account, then tap Set Up again.",
                    retries = false,
                ),
            )
        } catch (_: CloudUnreachableException) {
            fail(unreachable())
        } catch (_: CloudException) {
            fail(noKey())
        } catch (_: Exception) {
            return null
        } ?: fail(noWifi())

    /**
     * Run [attempt] a few times with growing pauses until it returns credentials the AC answered
     * with, failing with [failure] if it never does.
     */
    private suspend fun checkRepeatedly(
        progress: (SetupStep) -> Unit,
        failure: SetupFailure,
        attempt: suspend () -> DeviceCredentials?,
    ): DeviceCredentials {
        val attempts = CHECK_DELAYS_MS.size + 1
        for (number in 1..attempts) {
            progress(SetupStep.Checking(number, attempts))
            requireLan()
            attempt()?.let { credentials ->
                SetupLog.info("The AC accepted the key")
                return credentials
            }
            if (number < attempts) delay(CHECK_DELAYS_MS[number - 1])
        }
        fail(failure)
    }

    private fun requireLan() {
        if (!network.hasLocalNetworkAccess()) {
            fail(
                SetupFailure(
                    message = "Drift isn't allowed on the local network.",
                    hint = "Allow local network access, then Drift can reach the AC.",
                ),
            )
        }
    }

    private fun noWifi() = SetupFailure(
        message = "This phone isn't on Wi-Fi.",
        hint = "Join the AC's Wi-Fi network.",
    )

    private fun unreachable() = SetupFailure(
        message = "Couldn't reach Midea's cloud.",
        hint = "Check this phone's internet connection.",
    )

    private fun noKey() = SetupFailure(
        message = "Midea's cloud didn't return the key.",
        hint = "Make sure the AC shows up in the MSmartHome app under this account, then tap Set Up again.",
        retries = false,
    )

    private fun fail(failure: SetupFailure): Nothing = throw SetupFailedException(failure)

    internal companion object {
        // The AC serves one client at a time and frees its slot lazily, so a busy AC gets a
        // few spaced-out tries rather than a quick burst.
        val CHECK_DELAYS_MS = listOf(2_000L, 5_000L)
        const val DISCOVERY_ROUNDS = 2
    }
}
