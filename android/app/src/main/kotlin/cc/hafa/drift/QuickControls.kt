package cc.hafa.drift

import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import io.hafa.mideakt.FanSpeed
import io.hafa.mideakt.OperationalMode

/**
 * Long-pressing the Quick Settings tile lands here instead of the full app: a small card
 * over a dimmed backdrop with just the controls worth a quick reach — power, temperature,
 * mode, and fan speed — so the tile flow doesn't drop the user into a full-screen activity.
 * Tapping the backdrop (or Back) dismisses it like a dialog.
 */
class QuickControlsActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            DriftTheme {
                QuickControlsModal(viewModel(), onDismiss = ::finish)
            }
        }
    }
}

@Composable
private fun QuickControlsModal(viewModel: DeviceViewModel, onDismiss: () -> Unit) {
    val ui by viewModel.ui.collectAsState()
    val setup by viewModel.setup.collectAsState()
    val context = LocalContext.current
    val localNetwork = rememberLocalNetworkAccess(onGranted = viewModel::refresh)
    LaunchedEffect(Unit) {
        viewModel.refresh()
        viewModel.refreshWifiStatus()
    }
    Box(
        modifier = Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.scrim.copy(alpha = 0.5f))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onDismiss,
            ),
        contentAlignment = Alignment.Center,
    ) {
        QuickControlsCard(
            ui = ui,
            actions = ControlActions(
                onNickname = viewModel::setNickname,
                onApply = viewModel::apply,
                onAdjustTemp = viewModel::adjustTemperature,
                onSetTemp = viewModel::setTemperature,
                onToggleDisplay = viewModel::toggleDisplay,
                onRefresh = viewModel::refresh,
                onBeep = viewModel::setBeep,
                onForget = viewModel::forget,
            ),
            setupPanel = { SetupPanel(setup, ui.wifiAvailable, setupActions(viewModel, localNetwork)) },
            onOpenApp = {
                context.startActivity(Intent(context, MainActivity::class.java))
                onDismiss()
            },
            modifier = Modifier
                .fillMaxWidth(0.85f)
                // Absorbs taps so they don't fall through to the backdrop's dismiss handler.
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = {},
                ),
        )
    }
}

@Composable
private fun QuickControlsCard(
    ui: UiState,
    actions: ControlActions,
    setupPanel: @Composable () -> Unit,
    onOpenApp: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val cardColor = MaterialTheme.colorScheme.surface
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(28.dp),
        color = cardColor,
        contentColor = MaterialTheme.colorScheme.onSurface,
        shadowElevation = 6.dp,
    ) {
        Column(
            modifier = Modifier.verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            QuickControlsHeader(ui, actions, onOpenApp)
            val state = ui.state
            when {
                ui.needsSetup -> setupPanel()
                state == null -> Box(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    when (ui.connection) {
                        Connection.Disconnected -> EmptyState(Icons.Filled.WifiOff, "Not connected")
                        Connection.NoWifi -> EmptyState(Icons.Filled.WifiOff, "No Wi-Fi")
                        else -> CircularProgressIndicator(color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                else -> {
                    val accent = accentColors(state.powerOn, state.mode)
                    val fanOnly = state.mode == OperationalMode.FAN_ONLY
                    TemperatureDial(
                        target = ui.displayedTarget ?: state.targetTemperature,
                        indoor = state.indoorTemperature,
                        outdoor = state.outdoorTemperature,
                        label = dialLabel(state),
                        accent = accent,
                        enabled = state.powerOn && !fanOnly,
                        onAdjust = actions.onAdjustTemp,
                        onSetTarget = actions.onSetTemp,
                        modifier = Modifier.align(Alignment.CenterHorizontally).widthIn(max = QUICK_DIAL_MAX_WIDTH),
                        backdrop = cardColor,
                    )
                    ModeTiles(state.mode, accent) { mode -> actions.onApply { it.mode = mode; it.powerOn = true } }
                    FanSpeedControl(state.fanSpeed, accent, enabled = state.powerOn) { fan ->
                        actions.onApply { it.fanSpeed = fan }
                    }
                }
            }
        }
    }
}

@Composable
private fun QuickControlsHeader(ui: UiState, actions: ControlActions, onOpenApp: () -> Unit) {
    val state = ui.state
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            ui.displayName,
            style = MaterialTheme.typography.titleLarge,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (state != null && !ui.needsSetup) {
            PowerButton(state) { actions.onApply { it.powerOn = !state.powerOn } }
        }
        IconButton(onClick = onOpenApp) {
            Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = "Open full app")
        }
    }
}

// Keeps the dial a notch smaller than on the main screen so the card stays compact.
private val QUICK_DIAL_MAX_WIDTH = 260.dp

@Preview(showBackground = true, widthDp = 412)
@Composable
private fun QuickControlsCardPreview() {
    DriftTheme {
        QuickControlsCard(
            ui = UiState(discoveredName = "net_ac_A71C", nickname = "Bedroom", state = sampleState),
            actions = previewActions,
            setupPanel = {},
            onOpenApp = {},
            modifier = Modifier.padding(30.dp),
        )
    }
}

@Preview(showBackground = true, widthDp = 412, uiMode = Configuration.UI_MODE_NIGHT_YES)
@Composable
private fun QuickControlsCardOffDarkPreview() {
    DriftTheme {
        QuickControlsCard(
            ui = UiState(
                discoveredName = "net_ac_A71C",
                state = sampleState.copy(powerOn = false, fanSpeed = FanSpeed.AUTO),
            ),
            actions = previewActions,
            setupPanel = {},
            onOpenApp = {},
            modifier = Modifier.padding(30.dp),
        )
    }
}
