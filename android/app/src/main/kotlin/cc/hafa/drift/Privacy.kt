package cc.hafa.drift

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp

/** The privacy policy on the web, for anyone who wants it outside the app. */
internal const val PRIVACY_URL = "https://drift.hafa.cc/privacy"

/** The privacy policy, one heading and paragraph per section; the site's page says the same. */
private val privacySections = listOf(
    null to "Drift doesn't collect or share any data about you. There are no accounts, ads, analytics, or tracking.",
    "Your air conditioner" to
        "Drift talks to your air conditioner directly over your home Wi-Fi. Its settings and readings stay on " +
        "your phone.",
    "Setup" to
        "Newer air conditioners need a key before Drift can talk to them. During setup you sign in with your " +
        "Midea account, and Drift asks Midea's cloud for that key, sending your Midea email and password and the " +
        "air conditioner's ID. Your email and password go only to Midea, are never saved, and are cleared once " +
        "setup ends. After setup Drift never contacts the cloud.",
    "On your phone" to
        "The key is kept in encrypted storage and is removed when you forget the air conditioner or uninstall " +
        "Drift. It's left out of backups and transfers to a new phone.",
    "Contact" to "support@drift.hafa.cc",
)

/** A new issue on GitHub, for bugs and ideas. */
internal const val FEEDBACK_URL = "https://github.com/hafacc/drift/issues/new"

/** Drift's source code. */
internal const val SOURCE_URL = "https://github.com/hafacc/drift"

/** Quiet "Privacy", "Feedback" and "Source code" buttons; Privacy opens [PrivacyDialog]. */
@Composable
internal fun FooterLinks(modifier: Modifier = Modifier) {
    var showing by rememberSaveable { mutableStateOf(false) }
    val uriHandler = LocalUriHandler.current
    val color = MaterialTheme.colorScheme.onSurfaceVariant
    Row(modifier = modifier) {
        TextButton(onClick = { showing = true }) { Text("Privacy", color = color) }
        TextButton(onClick = { uriHandler.openUri(FEEDBACK_URL) }) { Text("Feedback", color = color) }
        TextButton(onClick = { uriHandler.openUri(SOURCE_URL) }) { Text("Source code", color = color) }
    }
    if (showing) PrivacyDialog(onDismiss = { showing = false })
}

/** The privacy policy in a dialog, with a way to open the web version. */
@Composable
internal fun PrivacyDialog(onDismiss: () -> Unit) {
    val uriHandler = LocalUriHandler.current
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        dismissButton = { TextButton(onClick = { uriHandler.openUri(PRIVACY_URL) }) { Text("View on the web") } },
        title = { Text("Privacy") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                for ((heading, body) in privacySections) {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        if (heading != null) Text(heading, style = MaterialTheme.typography.titleSmall)
                        Text(body, style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
        },
    )
}
