package cc.hafa.drift

import android.util.Log
import java.io.File
import java.time.LocalDateTime

/**
 * Setup's record, for working out why setup failed: in Logcat under the tag
 * `DriftSetup`, and in `setup.log` in the app's files once [start] is called, since the
 * phone's Logcat only keeps the last few minutes. It never holds account passwords, keys
 * or tokens.
 */
internal object SetupLog {
    private const val TAG = "DriftSetup"
    private const val MAX_BYTES = 256 * 1024L

    private var file: File? = null

    /** Also keep the record in [directory]/setup.log, starting it over once it grows large. */
    fun start(directory: File) {
        file = File(directory, "setup.log")
    }

    /** Record one thing setup did or saw. */
    fun info(message: String) {
        Log.i(TAG, message)
        append(message, null)
    }

    /** Record a failure, with the exception behind it when there is one. */
    fun error(message: String, cause: Throwable? = null) {
        Log.w(TAG, message, cause)
        append(message, cause)
    }

    @Synchronized
    private fun append(message: String, cause: Throwable?) {
        val target = file ?: return
        runCatching {
            if (target.length() > MAX_BYTES) target.delete()
            val trace = cause?.let { "\n" + it.stackTraceToString().trimEnd() }.orEmpty()
            target.appendText("${LocalDateTime.now()} $message$trace\n")
        }
    }
}
