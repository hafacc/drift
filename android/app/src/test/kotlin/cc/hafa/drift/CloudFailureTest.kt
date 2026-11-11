package cc.hafa.drift

import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudFailureTest {
    // A port nothing listens on, so both kinds of connection are refused the same way.
    private val closedPort = ServerSocket(0).use { it.localPort }

    private fun failure(block: () -> Unit): IOException =
        try {
            block()
            throw AssertionError("expected an IOException")
        } catch (error: IOException) {
            error
        }

    @Test
    fun refusedHttpRequestIsACloudFailure() {
        val error = failure {
            val connection = URI("http://127.0.0.1:$closedPort/").toURL().openConnection() as HttpURLConnection
            connection.connectTimeout = 2_000
            connection.responseCode
        }
        assertTrue(isCloudFailure(error))
        assertTrue(isCloudFailure(CloudUnreachableException(error)))
    }

    @Test
    fun refusedSocketIsNotACloudFailure() {
        val error = failure { Socket().use { it.connect(InetSocketAddress("127.0.0.1", closedPort), 2_000) } }
        assertFalse(isCloudFailure(error))
    }
}
