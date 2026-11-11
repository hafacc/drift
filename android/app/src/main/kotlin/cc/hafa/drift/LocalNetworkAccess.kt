package cc.hafa.drift

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LifecycleResumeEffect

// Only ever checked or requested on Android 17+, where the platform defines it.
@SuppressLint("InlinedApi")
private const val PERMISSION = Manifest.permission.ACCESS_LOCAL_NETWORK

/** Whether the app may talk to devices on the local network — always true before Android 17. */
fun hasLocalNetworkAccess(context: Context): Boolean =
    Build.VERSION.SDK_INT < Build.VERSION_CODES.CINNAMON_BUN ||
        context.checkSelfPermission(PERMISSION) == PackageManager.PERMISSION_GRANTED

/** A screen's live view of the local network grant, with a way to ask for it. */
class LocalNetworkAccess internal constructor(private val context: Context, private val onGranted: () -> Unit) {
    /** Whether local network access is currently granted. */
    var granted by mutableStateOf(hasLocalNetworkAccess(context))
        private set

    internal lateinit var launcher: ActivityResultLauncher<String>

    /** Ask for access: the system prompt while it can still show, else the app's settings page. */
    fun request() {
        if (context.findActivity()?.shouldShowRequestPermissionRationale(PERMISSION) == true) {
            launcher.launch(PERMISSION)
        } else {
            // The prompt was declined for good, so only Settings can grant it now.
            context.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")),
            )
        }
    }

    internal fun recheck() {
        val now = hasLocalNetworkAccess(context)
        val turnedOn = now && !granted
        granted = now
        if (turnedOn) onGranted()
    }
}

/**
 * Tracks the Android 17 local network grant that all LAN traffic to the AC needs, prompting
 * for it once when the screen first shows. A user who has declined once isn't prompted
 * again on their own; [LocalNetworkAccess.request] asks. Rechecked on resume so a grant made
 * in Settings is picked up; [onGranted] runs whenever access turns on.
 */
@Composable
fun rememberLocalNetworkAccess(onGranted: () -> Unit = {}): LocalNetworkAccess {
    val context = LocalContext.current
    val latestOnGranted by rememberUpdatedState(onGranted)
    val access = remember { LocalNetworkAccess(context) { latestOnGranted() } }
    access.launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        access.recheck()
    }
    var prompted by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        // Without a rationale flag the prompt either has never been shown (so show it) or was
        // declined for good (so the launch returns at once without any UI).
        val declinedOnce = context.findActivity()?.shouldShowRequestPermissionRationale(PERMISSION) != false
        if (!access.granted && !prompted && !declinedOnce) {
            prompted = true
            access.launcher.launch(PERMISSION)
        }
    }
    LifecycleResumeEffect(Unit) {
        access.recheck()
        onPauseOrDispose { }
    }
    return access
}

internal tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
