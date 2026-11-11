package cc.hafa.drift

import io.hafa.mideakt.CloudException
import io.hafa.mideakt.CloudLoginException
import io.hafa.mideakt.DeviceCredentials
import io.hafa.mideakt.DeviceNotInAccountException
import io.hafa.mideakt.DiscoveredDevice
import io.hafa.mideakt.HandshakeRejectedException
import java.io.IOException
import java.net.SocketTimeoutException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private val AC = DiscoveredDevice(id = 42L, ip = "10.0.0.5", port = 6444, version = 3, name = "AC", serialNumber = null)
private val TOKEN = byteArrayOf(0xA0.toByte(), 0xA0.toByte())
private val KEY = byteArrayOf(0xB0.toByte(), 0xB0.toByte())
private val ACCOUNT = CloudAccount("me@example.com", "secret")
/** A stand-in network that records each call and answers from scripted results. */
private class FakeNetwork : SetupNetwork {
    val calls = mutableListOf<String>()
    var devicesFound: () -> List<DiscoveredDevice>? = { listOf(AC) }
    var login: () -> Unit = {}
    // The version-3 key fetch and check: credentials, null when off Wi-Fi, or a throw.
    var credentials: (DiscoveredDevice) -> DeviceCredentials? = { DeviceCredentials(it, TOKEN, KEY) }
    var answer: (DeviceCredentials) -> Boolean? = { true }

    override fun hasLocalNetworkAccess(): Boolean = true

    override suspend fun discover(): List<DiscoveredDevice>? {
        calls += "discover"
        return devicesFound()
    }

    override fun cloud(account: CloudAccount): SetupCloud = object : SetupCloud {
        override suspend fun login() {
            calls += "login:${account.email}"
            this@FakeNetwork.login()
        }

        override suspend fun credentials(device: DiscoveredDevice): DeviceCredentials? {
            calls += "credentials:${device.id}"
            return this@FakeNetwork.credentials(device)
        }
    }

    override suspend fun check(credentials: DeviceCredentials): CheckResult? {
        calls += "check:${credentials.id}"
        return when (answer(credentials)) {
            true -> CheckResult.ANSWERED
            false -> CheckResult.SILENT
            null -> null
        }
    }

    /** The calls since the last take, clearing them. */
    fun take(): List<String> = calls.toList().also { calls.clear() }
}

/** A controller on the test's virtual clock, plus every phase it has shown. */
@OptIn(ExperimentalCoroutinesApi::class)
private class Harness(scope: TestScope) {
    val network = FakeNetwork()
    val saved = mutableListOf<DeviceCredentials>()
    val phases = mutableListOf<String>()
    val controller = SetupController(
        flow = SetupFlow(network),
        saved = { saved.lastOrNull() },
        save = { saved += it },
        // In the background scope, so a retry loop a failed assertion leaves running is cancelled
        // when the test ends rather than spun forward in virtual time forever.
        dispatcher = scope.backgroundScope.coroutineContext + StandardTestDispatcher(scope.testScheduler),
        clock = { scope.testScheduler.currentTime },
    )

    init {
        scope.backgroundScope.launch(UnconfinedTestDispatcher(scope.testScheduler)) {
            controller.state.map { label(it.phase) }.distinctUntilChanged().collect { phases += it }
        }
        controller.editAccount { ACCOUNT }
    }

    /** The phases since the last take, clearing them. */
    fun takePhases(): List<String> = phases.toList().also { phases.clear() }

    /** The failure on screen. */
    val failure: SetupFailure? get() = controller.state.value.phase.failure

    private fun label(phase: SetupPhase): String = when (phase) {
        SetupPhase.Idle -> "Idle"
        is SetupPhase.Running -> when (val step = phase.step) {
            is SetupStep.Checking -> "Checking${step.attempt}"
            else -> step.toString()
        }
        is SetupPhase.Waiting -> "Waiting@${phase.retryAt}"
        is SetupPhase.Failed -> "Failed"
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class SetupControllerTest {
    private val signIn = listOf("login:me@example.com")
    private val fetchCall = "credentials:42"
    private val fetchKey = signIn + fetchCall
    private val noKey: (DiscoveredDevice) -> DeviceCredentials? = { throw CloudException("No token/key", null) }
    private val cloudUnreachable: (DiscoveredDevice) -> DeviceCredentials? = {
        throw CloudUnreachableException(IOException("Connection refused"))
    }

    @Test
    fun missingKeyStopsRetrying() = runTest {
        val harness = Harness(this)
        harness.network.credentials = noKey
        harness.controller.start()
        runCurrent()
        assertEquals(listOf("discover") + fetchKey, harness.network.take())
        assertEquals(listOf("Idle", "Searching", "SigningIn", "Checking1", "Failed"), harness.takePhases())
        assertEquals("Midea's cloud didn't return the key.", harness.failure?.message)
        assertEquals(
            "Make sure the AC shows up in the MSmartHome app under this account, then tap Set Up again.",
            harness.failure?.hint,
        )
        advanceTimeBy(120_000)
        runCurrent()
        assertEquals(emptyList<String>(), harness.network.take())
    }

    @Test
    fun keyFetchFailingRepeatedlySearchesOnceAndRetriesFromTheSignIn() = runTest {
        val harness = Harness(this)
        harness.network.credentials = cloudUnreachable
        harness.controller.start()
        runCurrent()
        assertEquals(listOf("discover") + fetchKey, harness.network.take())
        assertEquals(listOf("Idle", "Searching", "SigningIn", "Checking1", "Waiting@5000"), harness.takePhases())
        assertEquals("Couldn't reach Midea's cloud.", harness.failure?.message)

        val pauses = listOf(5_000L, 10_000L, 20_000L, 30_000L, 30_000L, 30_000L)
        pauses.zipWithNext { pause, nextPause ->
            advanceTimeBy(pause - 1)
            runCurrent()
            assertEquals("no retry before the pause ends", emptyList<String>(), harness.network.take())
            advanceTimeBy(1)
            runCurrent()
            assertEquals(fetchKey, harness.network.take())
            assertEquals(
                listOf("SigningIn", "Checking1", "Waiting@${currentTime + nextPause}"),
                harness.takePhases(),
            )
        }
        harness.controller.reset()
    }

    @Test
    fun acNotAnsweringRetriesTheCheckWithOneSignIn() = runTest {
        val harness = Harness(this)
        var fetches = 0
        // Times out through both full checks of three tries each, then answers.
        harness.network.credentials = { device ->
            fetches += 1
            if (fetches > 6) DeviceCredentials(device, TOKEN, KEY) else throw SocketTimeoutException("Read timed out")
        }
        harness.controller.start()
        val check = listOf(fetchCall)

        runCurrent()
        assertEquals(listOf("discover") + fetchKey, harness.network.take())
        advanceTimeBy(2_000)
        runCurrent()
        assertEquals(check, harness.network.take())
        advanceTimeBy(5_000)
        runCurrent()
        assertEquals(check, harness.network.take())
        assertEquals(
            listOf("Idle", "Searching", "SigningIn", "Checking1", "Checking2", "Checking3", "Waiting@12000"),
            harness.takePhases(),
        )
        assertEquals("Found the AC and got its key, but the AC didn't answer.", harness.failure?.message)

        advanceTimeBy(5_000)
        runCurrent()
        assertEquals(fetchKey, harness.network.take())
        advanceTimeBy(7_000)
        runCurrent()
        assertEquals(check + check, harness.network.take())
        assertEquals(
            listOf("SigningIn", "Checking1", "Checking2", "Checking3", "Waiting@29000"),
            harness.takePhases(),
        )

        advanceTimeBy(10_000)
        runCurrent()
        assertEquals(fetchKey, harness.network.take())
        assertEquals(listOf("SigningIn", "Checking1", "Idle"), harness.takePhases())
        val saved = harness.saved.single()
        assertTrue(saved.token.contentEquals(TOKEN) && saved.key.contentEquals(KEY))
        assertEquals(SetupState(), harness.controller.state.value)

        advanceTimeBy(120_000)
        runCurrent()
        assertEquals(emptyList<String>(), harness.network.take())
    }

    @Test
    fun failedSearchSearchesAgain() = runTest {
        val harness = Harness(this)
        var searches = 0
        harness.network.devicesFound = { if (++searches > 4) listOf(AC) else emptyList() }
        harness.controller.start()

        runCurrent()
        assertEquals(listOf("discover", "discover"), harness.network.take())
        assertEquals(listOf("Idle", "Searching", "Waiting@5000"), harness.takePhases())
        advanceTimeBy(5_000)
        runCurrent()
        assertEquals(listOf("discover", "discover"), harness.network.take())
        assertEquals(listOf("Searching", "Waiting@15000"), harness.takePhases())
        advanceTimeBy(10_000)
        runCurrent()
        assertEquals(listOf("discover") + fetchKey, harness.network.take())
        assertEquals(listOf("Searching", "SigningIn", "Checking1", "Idle"), harness.takePhases())
        assertEquals(1, harness.saved.size)
    }

    @Test
    fun failedSearchThenFailedKeyFetchResumesAtTheSignIn() = runTest {
        val harness = Harness(this)
        var searches = 0
        harness.network.devicesFound = { if (++searches > 2) listOf(AC) else emptyList() }
        harness.network.credentials = cloudUnreachable
        harness.controller.start()

        runCurrent()
        assertEquals(listOf("discover", "discover"), harness.network.take())
        advanceTimeBy(5_000)
        runCurrent()
        assertEquals(listOf("discover") + fetchKey, harness.network.take())
        advanceTimeBy(10_000)
        runCurrent()
        assertEquals(fetchKey, harness.network.take())
        harness.controller.reset()
    }

    @Test
    fun pauseWithinTheGraceKeepsTheRetryGoing() = runTest {
        val harness = Harness(this)
        harness.network.credentials = cloudUnreachable
        harness.controller.resume()
        harness.controller.start()
        runCurrent()
        assertEquals(listOf("discover") + fetchKey, harness.network.take())

        // A rotation: the screen goes away and comes back within the grace.
        advanceTimeBy(1_000)
        harness.controller.pause()
        advanceTimeBy(1_999)
        harness.controller.resume()
        runCurrent()
        advanceTimeBy(2_001)
        runCurrent()
        assertEquals(fetchKey, harness.network.take())
        harness.controller.reset()
    }

    @Test
    fun pausePastTheGraceStopsAndResumeRetriesTheFailedStep() = runTest {
        val harness = Harness(this)
        harness.network.credentials = cloudUnreachable
        harness.controller.resume()
        harness.controller.start()
        runCurrent()
        harness.network.take()
        harness.takePhases()

        harness.controller.pause()
        advanceTimeBy(1_999)
        runCurrent()
        assertTrue(harness.controller.state.value.phase is SetupPhase.Waiting)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(listOf("Failed"), harness.takePhases())
        advanceTimeBy(120_000)
        runCurrent()
        assertEquals(emptyList<String>(), harness.network.take())

        harness.controller.resume()
        runCurrent()
        assertEquals(fetchKey, harness.network.take())
        assertEquals(listOf("SigningIn", "Checking1", "Waiting@${currentTime + 5_000}"), harness.takePhases())
        harness.controller.reset()
    }

    @Test
    fun resumeBeforeTheFirstStartDoesNothing() = runTest {
        val harness = Harness(this)
        harness.controller.resume()
        harness.controller.pause()
        harness.controller.resume()
        advanceTimeBy(10_000)
        runCurrent()
        assertEquals(emptyList<String>(), harness.network.take())
        assertEquals(listOf("Idle"), harness.takePhases())
    }

    @Test
    fun secondStartNeverStartsASecondLoop() = runTest {
        val harness = Harness(this)
        harness.network.credentials = cloudUnreachable
        harness.controller.start()
        harness.controller.start()
        runCurrent()
        assertEquals(listOf("discover") + fetchKey, harness.network.take())

        // Pressed again while waiting: the one loop keeps its schedule.
        advanceTimeBy(1_000)
        harness.controller.start()
        runCurrent()
        assertEquals(emptyList<String>(), harness.network.take())
        advanceTimeBy(4_000)
        runCurrent()
        assertEquals(fetchKey, harness.network.take())
        advanceTimeBy(10_000)
        runCurrent()
        assertEquals(fetchKey, harness.network.take())
        harness.controller.reset()
    }

    @Test
    fun resetClearsEverything() = runTest {
        val harness = Harness(this)
        harness.network.credentials = cloudUnreachable
        harness.controller.start()
        runCurrent()
        harness.network.take()

        harness.controller.reset()
        assertEquals(SetupState(), harness.controller.state.value)
        advanceTimeBy(120_000)
        runCurrent()
        assertEquals(emptyList<String>(), harness.network.take())

        // The fields are cleared too, and the AC found before is forgotten, so setup searches again.
        harness.controller.editAccount { ACCOUNT }
        harness.controller.start()
        runCurrent()
        assertEquals(listOf("discover") + fetchKey, harness.network.take())
        harness.controller.reset()
    }

    @Test
    fun startDoesNothingOnceSetUp() = runTest {
        val harness = Harness(this)
        harness.saved += DeviceCredentials(AC, TOKEN, KEY)
        harness.controller.start()
        runCurrent()
        assertEquals(emptyList<String>(), harness.network.take())
        assertNull(harness.controller.state.value.phase.failure)
    }

    @Test
    fun refusedMideaSignInStops() = runTest {
        val harness = Harness(this)
        harness.network.login = { throw CloudLoginException("Wrong password", 3102) }
        harness.controller.start()
        runCurrent()

        assertEquals(listOf("discover") + signIn, harness.network.take())
        assertEquals("Midea didn't accept that email and password.", harness.failure?.message)
        assertTrue(harness.controller.state.value.phase is SetupPhase.Failed)
        advanceTimeBy(120_000)
        runCurrent()
        assertEquals(emptyList<String>(), harness.network.take())

        // Pressed again with the right password, the search isn't repeated.
        harness.network.login = {}
        harness.controller.start()
        runCurrent()
        assertEquals(fetchKey, harness.network.take())
    }

    @Test
    fun acNotInTheAccountStops() = runTest {
        val harness = Harness(this)
        harness.network.credentials = { throw DeviceNotInAccountException("You have no permissions") }
        harness.controller.start()
        runCurrent()

        assertEquals(listOf("discover") + fetchKey, harness.network.take())
        assertEquals("This AC isn't in that Midea account.", harness.failure?.message)
        assertTrue(harness.controller.state.value.phase is SetupPhase.Failed)
    }

    @Test
    fun acTurningDownTheKeyStops() = runTest {
        val harness = Harness(this)
        harness.network.credentials = { throw HandshakeRejectedException("device rejected the token") }
        harness.controller.start()
        runCurrent()

        assertEquals(listOf("discover") + fetchKey, harness.network.take())
        assertEquals(listOf("Idle", "Searching", "SigningIn", "Checking1", "Failed"), harness.takePhases())
        assertEquals("The AC turned down the key from Midea's cloud.", harness.failure?.message)
        advanceTimeBy(120_000)
        runCurrent()
        assertEquals(emptyList<String>(), harness.network.take())
    }

    @Test
    fun failedSignInRetriesLater() = runTest {
        val harness = Harness(this)
        harness.network.login = { throw IllegalStateException("Unexpected reply") }
        harness.controller.start()
        runCurrent()

        assertEquals(listOf("discover") + signIn, harness.network.take())
        assertEquals(listOf("Idle", "Searching", "SigningIn", "Waiting@5000"), harness.takePhases())
        assertEquals("Couldn't sign in to Midea's cloud.", harness.failure?.message)
        harness.network.login = {}
        advanceTimeBy(5_000)
        runCurrent()
        assertEquals(fetchKey, harness.network.take())
        assertEquals(1, harness.saved.size)
    }

    @Test
    fun unreachableCloudStopsTheChecksAndRetriesLater() = runTest {
        val harness = Harness(this)
        harness.network.credentials = { throw CloudUnreachableException(IOException("Connection refused")) }
        harness.controller.start()
        runCurrent()

        assertEquals(listOf("discover") + fetchKey, harness.network.take())
        assertEquals(listOf("Idle", "Searching", "SigningIn", "Checking1", "Waiting@5000"), harness.takePhases())
        assertEquals("Couldn't reach Midea's cloud.", harness.failure?.message)
        harness.network.credentials = { DeviceCredentials(it, TOKEN, KEY) }
        advanceTimeBy(5_000)
        runCurrent()
        assertEquals(fetchKey, harness.network.take())
        assertEquals(1, harness.saved.size)
    }

    @Test
    fun offWifiDuringTheCheckFails() = runTest {
        val harness = Harness(this)
        harness.network.credentials = { null }
        harness.controller.start()
        runCurrent()

        assertEquals(listOf("discover") + fetchKey, harness.network.take())
        assertEquals("This phone isn't on Wi-Fi.", harness.failure?.message)
        harness.controller.reset()
    }

    @Test
    fun version2AcIsCheckedWithoutSigningIn() = runTest {
        val harness = Harness(this)
        harness.network.devicesFound = { listOf(AC.copy(version = 2)) }
        harness.controller.start()
        runCurrent()

        assertEquals(listOf("discover", "check:42"), harness.network.take())
        assertEquals(listOf("Idle", "Searching", "Checking1", "Idle"), harness.takePhases())
        assertEquals(2, harness.saved.single().version)
    }
}
