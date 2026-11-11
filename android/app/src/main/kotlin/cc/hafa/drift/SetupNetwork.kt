package cc.hafa.drift

import android.content.Context
import io.hafa.mideakt.DeviceCredentials
import io.hafa.mideakt.DiscoveredDevice
import io.hafa.mideakt.HandshakeRejectedException
import io.hafa.mideakt.MideaClient
import io.hafa.mideakt.Setup
import io.hafa.mideakt.SmartHomeCloud
import io.hafa.mideakt.SmartHomeSession
import java.io.IOException
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/**
 * The real network, reached through [devices], which serializes each LAN step with any other
 * reach and pins it to Wi-Fi.
 */
internal class LiveSetupNetwork(private val context: Context, private val devices: DeviceManager) : SetupNetwork {
    override fun hasLocalNetworkAccess(): Boolean = hasLocalNetworkAccess(context)

    override suspend fun discover(): List<DiscoveredDevice>? =
        devices.onLanForSetup { wifi ->
            runCatching { devices.discoverOn(wifi) }
                .onFailure { SetupLog.error("Search failed", it) }
                .getOrDefault(emptyList())
        }

    override fun cloud(account: CloudAccount): SetupCloud = object : SetupCloud {
        private val cloud = SmartHomeCloud(account.email.trim(), account.password)
        private var session: SmartHomeSession? = null

        override suspend fun login() {
            session = devices.onInternetForSetup { cloud.login() }
        }

        // Only the socket to the AC is held to Wi-Fi, so the key requests can use mobile data
        // when the AC's Wi-Fi has no internet.
        override suspend fun credentials(device: DiscoveredDevice): DeviceCredentials? {
            val signedIn = checkNotNull(session) { "Not signed in" }
            return devices.onWifiSocketsForSetup { wifi ->
                runCatching { Setup.credentials(device, signedIn, wifi.socketFactory) }
                    .onFailure { SetupLog.error("Getting the key for ${device.ip} failed", it) }
                    .getOrElse { error ->
                        throw if (error is IOException && isCloudFailure(error)) {
                            CloudUnreachableException(error)
                        } else {
                            error
                        }
                    }
            }
        }
    }

    override suspend fun check(credentials: DeviceCredentials): CheckResult? = devices.onLanForSetup {
        val outcome = runCatching { MideaClient(credentials).use { it.refresh() } }
        outcome.exceptionOrNull()?.let { SetupLog.error("Key check with ${credentials.ip} failed", it) }
        when {
            outcome.isSuccess -> CheckResult.ANSWERED
            outcome.exceptionOrNull() is HandshakeRejectedException -> CheckResult.REJECTED
            else -> CheckResult.SILENT
        }
    }
}

/**
 * Whether [error] came from a request to Midea's cloud rather than the socket to the AC. mideakt
 * lets both through as plain [IOException]s; only the cloud's go through an HTTP connection.
 */
internal fun isCloudFailure(error: IOException): Boolean =
    generateSequence<Throwable>(error) { it.cause }.any { cause ->
        cause is UnknownHostException || cause is SSLException ||
            cause.stackTrace.any { "URLConnection" in it.className }
    }
