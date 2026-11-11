package cc.hafa.drift

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.VolumeUp
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material.icons.outlined.AcUnit
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.Eco
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.SwapVert
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material.icons.outlined.WaterDrop
import androidx.compose.material.icons.outlined.WbSunny
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.min
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.LifecycleStartEffect
import io.hafa.mideakt.ACState
import io.hafa.mideakt.FanSpeed
import io.hafa.mideakt.OperationalMode
import io.hafa.mideakt.SetState
import io.hafa.mideakt.SwingMode
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlinx.coroutines.delay

@Composable
fun DriftApp(viewModel: DeviceViewModel) {
    val ui by viewModel.ui.collectAsState()
    val setup by viewModel.setup.collectAsState()
    LifecycleStartEffect(Unit) {
        viewModel.startPolling()
        onStopOrDispose { viewModel.stopPolling() }
    }
    // A backgrounded/cached process can miss the Wi-Fi callback for a change that
    // happened while it wasn't looking, so force a fresh, synchronous recheck every
    // time this screen actually comes back on-screen rather than trusting it silently.
    LifecycleResumeEffect(Unit) {
        viewModel.refreshWifiStatus()
        onPauseOrDispose { }
    }
    val localNetwork = rememberLocalNetworkAccess(onGranted = viewModel::refresh)
    Scaffold { padding ->
        Column(modifier = Modifier.padding(padding).fillMaxSize()) {
            if (!localNetwork.granted) LocalNetworkBanner(onAllow = localNetwork::request)
            BatteryOptimizationBanner()
            Box(modifier = Modifier.weight(1f)) {
                if (ui.needsSetup) {
                    SetupScreen(ui, setup, setupActions(viewModel, localNetwork))
                } else {
                    ControlScreen(
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
                    )
                }
            }
        }
    }
}

@Composable
private fun SetupScreen(ui: UiState, setup: SetupState, actions: SetupActions) {
    Box(modifier = Modifier.fillMaxSize().imePadding(), contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier.verticalScroll(rememberScrollState()).padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(72.dp)
                    .background(MaterialTheme.colorScheme.surfaceContainerHigh, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Outlined.AcUnit,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.size(36.dp),
                )
            }
            Text("Set up your AC", style = MaterialTheme.typography.headlineSmall)
            Text(
                "Drift finds it on your network, then signs in to your Midea account once to get its key. It " +
                    "doesn't keep your password.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            SetupPanel(setup, ui.wifiAvailable, actions)
            PrivacyButton()
        }
    }
}

/** One callback per setup-screen action, hoisted to the view model. */
internal class SetupActions(
    val onSetUp: () -> Unit,
    val onEditAccount: ((CloudAccount) -> CloudAccount) -> Unit,
    val onResume: () -> Unit,
    val onPause: () -> Unit,
)

/** Setup's actions for [viewModel], each asking for local network access first where it needs it. */
internal fun setupActions(viewModel: DeviceViewModel, localNetwork: LocalNetworkAccess) =
    SetupActions(
        onSetUp = { if (localNetwork.granted) viewModel.setup() else localNetwork.request() },
        onEditAccount = viewModel::editAccount,
        onResume = viewModel::resumeSetup,
        onPause = viewModel::pauseSetup,
    )

/**
 * Setup's form and status, shared by the app and the quick controls: the Midea account fields,
 * the current step or what last failed, and the button that starts it.
 * Automatic setup runs only while some panel is on-screen.
 */
@Composable
internal fun SetupPanel(setup: SetupState, wifiAvailable: Boolean, actions: SetupActions) {
    val latestActions by rememberUpdatedState(actions)
    LifecycleStartEffect(Unit) {
        latestActions.onResume()
        onStopOrDispose { latestActions.onPause() }
    }
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        AccountFields(setup.account, enabled = setup.phase !is SetupPhase.Running, onEdit = actions.onEditAccount)
        setup.phase.failure?.let { failure -> FailureText(failure) }
        SetupControls(setup, wifiAvailable, actions)
    }
}

/** The current step or retry wait, or the button that starts setup. */
@Composable
private fun SetupControls(setup: SetupState, wifiAvailable: Boolean, actions: SetupActions) {
    when (val phase = setup.phase) {
        // Shown in place of the button rather than relabeling it.
        is SetupPhase.Running -> SetupProgress(phase.step.message)
        is SetupPhase.Waiting -> RetryCountdown(phase.retryAt)
        else -> {
            SetupButton(wifiAvailable, enabled = setup.account.isComplete, actions.onSetUp)
        }
    }
}

@Composable
private fun FailureText(failure: SetupFailure) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            failure.message,
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
        )
        if (failure.hint.isNotEmpty()) {
            Text(
                failure.hint,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun AccountFields(account: CloudAccount, enabled: Boolean, onEdit: ((CloudAccount) -> CloudAccount) -> Unit) {
    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        CredentialField("Midea account email", account.email, enabled, KeyboardType.Email) { email ->
            onEdit { it.copy(email = email) }
        }
        CredentialField("Password", account.password, enabled, KeyboardType.Password, secret = true) { password ->
            onEdit { it.copy(password = password) }
        }
    }
}

@Suppress("LongParameterList")
@Composable
private fun CredentialField(
    label: String,
    value: String,
    enabled: Boolean,
    keyboardType: KeyboardType,
    secret: Boolean = false,
    onValueChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier.fillMaxWidth(),
        enabled = enabled,
        label = { Text(label) },
        singleLine = true,
        visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.None,
            autoCorrectEnabled = false,
            keyboardType = keyboardType,
            imeAction = ImeAction.Next,
        ),
    )
}

@Composable
private fun SetupButton(wifiAvailable: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Button(onClick = onClick, enabled = wifiAvailable && enabled) {
        if (!wifiAvailable) {
            Icon(
                Icons.Filled.WifiOff,
                contentDescription = "No Wi-Fi",
                modifier = Modifier.size(ButtonDefaults.IconSize),
            )
            Spacer(Modifier.size(ButtonDefaults.IconSpacing))
        }
        Text("Set Up")
    }
}

@Composable
private fun SetupProgress(message: String) {
    Row(
        modifier = Modifier.heightIn(min = ButtonDefaults.MinHeight),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        CircularProgressIndicator(
            modifier = Modifier.size(16.dp),
            strokeWidth = 2.dp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(message, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun RetryCountdown(retryAt: Long) {
    var now by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    LaunchedEffect(retryAt) {
        while (true) {
            now = SystemClock.elapsedRealtime()
            delay(250)
        }
    }
    val seconds = (retryAt - now + 999) / 1000
    SetupProgress(if (seconds > 0) "Trying again in $seconds s…" else "Trying again…")
}

/** One callback per control-screen action, hoisted to the view model. */
@Suppress("LongParameterList")
internal class ControlActions(
    val onNickname: (String) -> Unit,
    val onApply: ((SetState) -> Unit) -> Unit,
    val onAdjustTemp: (Int) -> Unit,
    val onSetTemp: (Double) -> Unit,
    val onToggleDisplay: () -> Unit,
    val onRefresh: () -> Unit,
    val onBeep: (Boolean) -> Unit,
    val onForget: () -> Unit,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ControlScreen(ui: UiState, actions: ControlActions) {
    val state = ui.state
    Column(modifier = Modifier.fillMaxSize()) {
        ControlTopBar(ui, actions)
        PullToRefreshBox(
            isRefreshing = ui.refreshing,
            onRefresh = actions.onRefresh,
            modifier = Modifier.weight(1f).fillMaxWidth(),
        ) {
            if (state == null) {
                NoReading(ui, actions)
            } else {
                ControlContent(ui, state, actions, modifier = Modifier.fillMaxSize())
            }
        }
    }
}

/**
 * The page before the first reading, scrollable so it can be pulled to refresh, with the
 * device options still at the bottom so an AC that won't come back can be forgotten.
 */
@Composable
private fun NoReading(ui: UiState, actions: ControlActions) {
    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .heightIn(min = maxHeight)
                .padding(start = 20.dp, end = 20.dp, bottom = 20.dp),
        ) {
            // A spinner while connecting, otherwise a reason we aren't: the phone being off
            // Wi-Fi entirely is a distinct, this-side problem from the AC just being unreachable.
            Box(modifier = Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                when (ui.connection) {
                    Connection.Disconnected -> EmptyState(Icons.Filled.WifiOff, "Not connected")
                    Connection.NoWifi -> EmptyState(Icons.Filled.WifiOff, "No Wi-Fi")
                    else -> CircularProgressIndicator(color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            DeviceOptions(ui.beepEnabled, accentColors(powerOn = false, mode = OperationalMode.AUTO), actions)
        }
    }
}

@Composable
private fun ControlContent(ui: UiState, state: ACState, actions: ControlActions, modifier: Modifier = Modifier) {
    val accent = accentColors(state.powerOn, state.mode)
    val fanOnly = state.mode == OperationalMode.FAN_ONLY
    Column(
        modifier = modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(start = 20.dp, top = 4.dp, end = 20.dp, bottom = 20.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        // We have a reading but the link has since dropped: it's stale.
        if (ui.connection == Connection.Disconnected || ui.connection == Connection.NoWifi) {
            StaleNotice(if (ui.connection == Connection.NoWifi) "No Wi-Fi" else "Not connected")
        }

        TemperatureDial(
            target = ui.displayedTarget ?: state.targetTemperature,
            indoor = state.indoorTemperature,
            outdoor = state.outdoorTemperature,
            label = dialLabel(state),
            accent = accent,
            enabled = state.powerOn && !fanOnly,
            onAdjust = actions.onAdjustTemp,
            onSetTarget = actions.onSetTemp,
            modifier = Modifier.align(Alignment.CenterHorizontally),
        )

        ModeTiles(state.mode, accent) { mode -> actions.onApply { it.mode = mode; it.powerOn = true } }
        FanSpeedControl(state.fanSpeed, accent, enabled = state.powerOn) { fan ->
            actions.onApply { it.fanSpeed = fan }
        }
        ExtrasGrid(state, accent, fanOnly, actions)

        if (state.filterAlert) FilterCard()
        DeviceOptions(ui.beepEnabled, accent, actions)
    }
}

/** Whether the AC beeps at each command, forgetting the device, and the privacy policy. */
@Composable
private fun DeviceOptions(beepEnabled: Boolean, accent: AccentColors, actions: ControlActions) {
    var confirmingForget by rememberSaveable { mutableStateOf(false) }
    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        ToggleTile(
            Icons.AutoMirrored.Outlined.VolumeUp, "Beep", beepEnabled, accent, modifier = Modifier.fillMaxWidth(),
            onChange = actions.onBeep,
        )
        TextButton(
            onClick = { confirmingForget = true },
            colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
            modifier = Modifier.align(Alignment.CenterHorizontally),
        ) {
            Text("Forget device")
        }
        PrivacyButton(modifier = Modifier.align(Alignment.CenterHorizontally))
    }
    if (confirmingForget) {
        AlertDialog(
            onDismissRequest = { confirmingForget = false },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmingForget = false
                        actions.onForget()
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
                ) { Text("Forget") }
            },
            dismissButton = { TextButton(onClick = { confirmingForget = false }) { Text("Cancel") } },
            title = { Text("Forget this device?") },
            text = { Text("Drift deletes its key. Setting it up again needs your Midea account.") },
        )
    }
}

@Composable
internal fun EmptyState(icon: ImageVector, text: String) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(text, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun StaleNotice(reason: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Filled.WifiOff,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(16.dp),
        )
        Text(
            "$reason — showing last reading",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.labelMedium,
        )
    }
}

@Composable
private fun ControlTopBar(ui: UiState, actions: ControlActions) {
    val state = ui.state
    Row(
        modifier = Modifier.fillMaxWidth().height(64.dp).padding(start = 20.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        EditableName(ui.nickname, ui.discoveredName, actions.onNickname, modifier = Modifier.weight(1f))
        if (state != null) {
            PowerButton(state) { actions.onApply { it.powerOn = !state.powerOn } }
        }
    }
}

@Composable
internal fun PowerButton(state: ACState, onToggle: () -> Unit) {
    val content: @Composable () -> Unit = {
        Icon(
            Icons.Filled.PowerSettingsNew,
            contentDescription = null,
            modifier = Modifier.size(ButtonDefaults.IconSize),
        )
        Spacer(Modifier.size(ButtonDefaults.IconSpacing))
        Text(if (state.powerOn) "On" else "Off")
    }
    if (state.powerOn) {
        val accent = accentColors(state.powerOn, state.mode)
        Button(
            onClick = onToggle,
            colors = ButtonDefaults.buttonColors(containerColor = accent.fill, contentColor = accent.onFill),
            contentPadding = ButtonDefaults.ButtonWithIconContentPadding,
        ) { content() }
    } else {
        FilledTonalButton(
            onClick = onToggle,
            colors = ButtonDefaults.filledTonalButtonColors(
                containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                contentColor = MaterialTheme.colorScheme.onSurface,
            ),
            contentPadding = ButtonDefaults.ButtonWithIconContentPadding,
        ) {
            content()
        }
    }
}

internal fun dialLabel(state: ACState): String =
    when {
        !state.powerOn -> "TARGET"
        state.mode == OperationalMode.COOL -> "COOLING TO"
        state.mode == OperationalMode.HEAT -> "HEATING TO"
        else -> "TARGET"
    }

/**
 * A 270° setpoint arc, open at the bottom, over [MIN_TEMPERATURE]–[MAX_TEMPERATURE]. Drawn
 * in fractions of its width so it shrinks to fit narrow screens; − and + sit centred on
 * the arc's two ends. Dragging along the ring sets the target in whole degrees.
 */
@Suppress("LongParameterList")
@Composable
internal fun TemperatureDial(
    target: Double,
    indoor: Double?,
    outdoor: Double?,
    label: String,
    accent: AccentColors,
    enabled: Boolean,
    onAdjust: (Int) -> Unit,
    onSetTarget: (Double) -> Unit,
    modifier: Modifier = Modifier,
    // Whatever the dial sits on, so the − and + rings cut cleanly into the arc ends.
    backdrop: Color = MaterialTheme.colorScheme.background,
) {
    BoxWithConstraints(modifier = modifier) {
        val dialWidth = min(maxWidth, DIAL_MAX_WIDTH)
        Box(modifier = Modifier.size(dialWidth, dialWidth * DIAL_HEIGHT_FRACTION)) {
            DialArc(target, indoor, accent, enabled, onSetTarget, Modifier.fillMaxSize())
            DialReadout(target, indoor, outdoor, label, accent, enabled, dialWidth)
            val endDx = dialWidth * DIAL_RADIUS_FRACTION * cos(Math.toRadians(ARC_START_DEGREES.toDouble())).toFloat()
            val centre = dialWidth / 2
            val buttonY = stepButtonCentreY(dialWidth)
            StepButton(Icons.Filled.Remove, "Colder", enabled, centre + endDx, buttonY, backdrop) { onAdjust(-1) }
            StepButton(Icons.Filled.Add, "Warmer", enabled, centre - endDx, buttonY, backdrop) { onAdjust(1) }
        }
    }
}

@Suppress("LongParameterList")
@Composable
private fun DialArc(
    target: Double,
    indoor: Double?,
    accent: AccentColors,
    enabled: Boolean,
    onSetTarget: (Double) -> Unit,
    modifier: Modifier = Modifier,
) {
    val trackColor = MaterialTheme.colorScheme.surfaceVariant
    val dotColor = MaterialTheme.colorScheme.onSurface
    val fillColor = if (enabled) accent.fill else accent.fill.copy(alpha = DISABLED_ALPHA)
    val knobColor = accent.onFill
    val latestOnSetTarget by rememberUpdatedState(onSetTarget)
    val touchSlop = with(LocalDensity.current) { RING_TOUCH_MARGIN.toPx() }
    Canvas(
        modifier = modifier.pointerInput(enabled) {
            if (!enabled) return@pointerInput
            awaitEachGesture {
                val down = awaitFirstDown()
                val centre = Offset(size.width / 2f, size.width / 2f)
                val radius = size.width * DIAL_RADIUS_FRACTION
                val ringBand = size.width * DIAL_TRACK_FRACTION / 2 + touchSlop
                val distance = (down.position - centre).getDistance()
                // Only the ring itself is draggable, so a swipe elsewhere still scrolls the page.
                if (distance < radius - ringBand || distance > radius + ringBand) return@awaitEachGesture
                down.consume()
                var lastSent = setpointAt(down.position, centre)
                latestOnSetTarget(lastSent)
                drag(down.id) { change ->
                    change.consume()
                    val next = setpointAt(change.position, centre)
                    if (next != lastSent) {
                        lastSent = next
                        latestOnSetTarget(next)
                    }
                }
            }
        },
    ) {
        val centre = Offset(size.width / 2f, size.width / 2f)
        val radius = size.width * DIAL_RADIUS_FRACTION
        val arcTopLeft = Offset(centre.x - radius, centre.y - radius)
        val arcSize = Size(radius * 2, radius * 2)
        val stroke = Stroke(width = size.width * DIAL_TRACK_FRACTION, cap = StrokeCap.Round)
        drawArc(trackColor, ARC_START_DEGREES, ARC_SWEEP_DEGREES, false, arcTopLeft, arcSize, style = stroke)
        val targetSweep = ARC_SWEEP_DEGREES * fractionOf(target)
        drawArc(fillColor, ARC_START_DEGREES, targetSweep, false, arcTopLeft, arcSize, style = stroke)
        if (indoor != null) {
            val indoorSweep = ARC_SWEEP_DEGREES * fractionOf(indoor)
            drawCircle(dotColor, size.width * DIAL_DOT_FRACTION, pointOnArc(centre, radius, indoorSweep))
        }
        val knobCentre = pointOnArc(centre, radius, targetSweep)
        val knobRadius = size.width * DIAL_KNOB_FRACTION
        drawCircle(knobColor, knobRadius, knobCentre)
        drawCircle(fillColor, knobRadius, knobCentre, style = Stroke(width = size.width * DIAL_KNOB_RING_FRACTION))
    }
}

@Suppress("LongParameterList")
@Composable
private fun DialReadout(
    target: Double,
    indoor: Double?,
    outdoor: Double?,
    label: String,
    accent: AccentColors,
    enabled: Boolean,
    dialWidth: Dp,
) {
    val readout = listOfNotNull(
        indoor?.let { "Room ${it.roundToInt()}°" },
        outdoor?.let { "outside ${it.roundToInt()}°" },
    ).joinToString(" · ").replaceFirstChar { it.uppercase() }
    val setpoint = "${target.roundToInt()}°"
    val labelStyle = MaterialTheme.typography.labelLarge.copy(letterSpacing = 0.08.em)
    val readoutStyle = MaterialTheme.typography.bodyMedium
    val density = LocalDensity.current
    val nominalSize = with(density) { (dialWidth * DIAL_SETPOINT_FRACTION).toSp() }
    val nominalSetpointStyle = MaterialTheme.typography.displayLarge.copy(
        fontSize = nominalSize,
        lineHeight = nominalSize,
        fontWeight = FontWeight.SemiBold,
        lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.Both),
    )
    // The stack must end above the step buttons' rings, whose size doesn't scale with the
    // dial, so the setpoint shrinks by whatever the measured label and room line leave it.
    val measurer = rememberTextMeasurer()
    val readoutTop = dialWidth * DIAL_READOUT_TOP_FRACTION
    val setpointSize = with(density) {
        val stackBottom = stepButtonCentreY(dialWidth) - STEP_BUTTON_SIZE / 2 - STEP_BUTTON_RING - READOUT_CLEARANCE
        val labelHeight = measurer.measure(label, labelStyle, maxLines = 1).size.height.toDp()
        val readoutHeight = if (readout.isEmpty()) {
            0.dp
        } else {
            measurer.measure(readout, readoutStyle, maxLines = 1).size.height.toDp() + READOUT_GAP
        }
        val setpointHeight = measurer.measure(setpoint, nominalSetpointStyle, maxLines = 1).size.height.toDp()
        val fit = (stackBottom - readoutTop - labelHeight - readoutHeight) / setpointHeight
        nominalSize * fit.coerceIn(0f, 1f)
    }
    Column(
        modifier = Modifier.fillMaxWidth().padding(top = readoutTop),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(label, color = accent.text, style = labelStyle, maxLines = 1)
        Text(
            setpoint,
            style = nominalSetpointStyle.copy(fontSize = setpointSize, lineHeight = setpointSize),
            maxLines = 1,
            color = if (enabled) {
                MaterialTheme.colorScheme.onSurface
            } else {
                MaterialTheme.colorScheme.onSurface.copy(alpha = DISABLED_ALPHA)
            },
        )
        if (readout.isNotEmpty()) {
            Text(
                readout,
                style = readoutStyle,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                modifier = Modifier.padding(top = READOUT_GAP),
            )
        }
    }
}

@Suppress("LongParameterList")
@Composable
private fun StepButton(
    icon: ImageVector,
    description: String,
    enabled: Boolean,
    centreX: Dp,
    centreY: Dp,
    backdrop: Color,
    onClick: () -> Unit,
) {
    val outer = STEP_BUTTON_SIZE + STEP_BUTTON_RING * 2
    // The background-coloured ring cuts the button out of the arc end it sits on.
    Box(
        modifier = Modifier
            .offset(x = centreX - outer / 2, y = centreY - outer / 2)
            .size(outer)
            .background(backdrop, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        FilledTonalIconButton(
            onClick = onClick,
            enabled = enabled,
            colors = IconButtonDefaults.filledTonalIconButtonColors(
                containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                contentColor = MaterialTheme.colorScheme.onSurface,
            ),
            modifier = Modifier.size(STEP_BUTTON_SIZE),
        ) {
            Icon(icon, contentDescription = description)
        }
    }
}

/** Where the − and + buttons' centres sit: on the arc's two ends. */
private fun stepButtonCentreY(dialWidth: Dp): Dp =
    dialWidth / 2 + dialWidth * DIAL_RADIUS_FRACTION * sin(Math.toRadians(ARC_START_DEGREES.toDouble())).toFloat()

private fun fractionOf(temperature: Double): Float =
    ((temperature - MIN_TEMPERATURE) / (MAX_TEMPERATURE - MIN_TEMPERATURE)).toFloat().coerceIn(0f, 1f)

private fun pointOnArc(centre: Offset, radius: Float, sweep: Float): Offset {
    val radians = Math.toRadians((ARC_START_DEGREES + sweep).toDouble())
    return Offset(centre.x + radius * cos(radians).toFloat(), centre.y + radius * sin(radians).toFloat())
}

/** The whole-degree setpoint under [position]; a touch in the open gap snaps to the nearer end. */
private fun setpointAt(position: Offset, centre: Offset): Double {
    val degrees = Math.toDegrees(atan2(position.y - centre.y, position.x - centre.x).toDouble()).toFloat()
    val fromStart = (degrees - ARC_START_DEGREES + FULL_TURN) % FULL_TURN
    val fraction = when {
        fromStart <= ARC_SWEEP_DEGREES -> fromStart / ARC_SWEEP_DEGREES
        fromStart < ARC_SWEEP_DEGREES + (FULL_TURN - ARC_SWEEP_DEGREES) / 2 -> 1f
        else -> 0f
    }
    return (MIN_TEMPERATURE + fraction * (MAX_TEMPERATURE - MIN_TEMPERATURE)).roundToInt().toDouble()
}

@Composable
internal fun ModeTiles(currentMode: OperationalMode, accent: AccentColors, onSelect: (OperationalMode) -> Unit) {
    val modes = listOf(OperationalMode.AUTO, OperationalMode.COOL, OperationalMode.DRY, OperationalMode.FAN_ONLY)
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for (mode in modes) {
            val selected = mode == currentMode
            Surface(
                selected = selected,
                onClick = { onSelect(mode) },
                shape = RoundedCornerShape(16.dp),
                color = if (selected) accent.fill else MaterialTheme.colorScheme.surfaceContainerHigh,
                contentColor = if (selected) accent.onFill else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f).height(64.dp),
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
                ) {
                    Icon(mode.icon, contentDescription = null, modifier = Modifier.size(20.dp))
                    Text(
                        mode.display.replaceFirstChar { it.uppercase() },
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                    )
                }
            }
        }
    }
}

private val OperationalMode.icon: ImageVector
    get() = when (this) {
        OperationalMode.AUTO -> Icons.Outlined.AutoAwesome
        OperationalMode.COOL -> Icons.Outlined.AcUnit
        OperationalMode.DRY, OperationalMode.SMART_DRY -> Icons.Outlined.WaterDrop
        OperationalMode.FAN_ONLY -> Icons.Filled.Air
        OperationalMode.HEAT -> Icons.Outlined.WbSunny
        else -> Icons.Filled.PowerSettingsNew
    }

private val SliderFanSpeeds = listOf(FanSpeed.SILENT, FanSpeed.LOW, FanSpeed.MEDIUM, FanSpeed.HIGH, FanSpeed.MAX)

@Composable
internal fun FanSpeedControl(
    current: FanSpeed,
    accent: AccentColors,
    enabled: Boolean = true,
    onSelect: (FanSpeed) -> Unit,
) {
    val isAuto = current == FanSpeed.AUTO
    val currentIndex = SliderFanSpeeds.indexOf(current)
    // Held while dragging so the thumb follows the finger; the speed is only sent on release.
    var dragIndex by remember { mutableStateOf<Int?>(null) }
    val shownIndex = dragIndex ?: currentIndex.takeIf { it >= 0 } ?: SliderFanSpeeds.indexOf(FanSpeed.MEDIUM)
    val shownLabel = when {
        dragIndex != null -> SliderFanSpeeds[shownIndex].display
        current in FanSpeed.entries -> current.display
        else -> "—"
    }
    Column(
        modifier = Modifier.alpha(if (enabled) 1f else DISABLED_ALPHA),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(
                "Fan speed",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                shownLabel.replaceFirstChar { it.uppercase() },
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            // On Auto the slider shows no speed of its own, so its fill goes neutral.
            val sliderFill = if (isAuto && dragIndex == null) MaterialTheme.colorScheme.outline else accent.fill
            Slider(
                value = shownIndex.toFloat(),
                onValueChange = { dragIndex = it.roundToInt() },
                enabled = enabled,
                onValueChangeFinished = {
                    dragIndex?.let { index -> if (index != currentIndex) onSelect(SliderFanSpeeds[index]) }
                    dragIndex = null
                },
                valueRange = 0f..(SliderFanSpeeds.size - 1).toFloat(),
                steps = SliderFanSpeeds.size - 2,
                colors = SliderDefaults.colors(
                    thumbColor = sliderFill,
                    activeTrackColor = sliderFill,
                    inactiveTrackColor = MaterialTheme.colorScheme.surfaceContainerHighest,
                    activeTickColor = accent.onFill,
                    inactiveTickColor = MaterialTheme.colorScheme.onSurfaceVariant,
                ),
                modifier = Modifier.weight(1f),
            )
            FanAutoButton(isAuto, accent, enabled) { onSelect(FanSpeed.AUTO) }
        }
    }
}

/** The fan speed's Auto button, filled while the fan is on Auto. */
@Composable
private fun FanAutoButton(isAuto: Boolean, accent: AccentColors, enabled: Boolean, onSelect: () -> Unit) {
    if (isAuto) {
        Button(
            onClick = {},
            enabled = enabled,
            colors = ButtonDefaults.buttonColors(containerColor = accent.fill, contentColor = accent.onFill),
        ) { Text("Auto") }
    } else {
        OutlinedButton(
            onClick = onSelect,
            enabled = enabled,
            colors = ButtonDefaults.outlinedButtonColors(
                contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
            ),
        ) { Text("Auto") }
    }
}

@Composable
private fun ExtrasGrid(state: ACState, accent: AccentColors, fanOnly: Boolean, actions: ControlActions) {
    val compressorAvailable = state.powerOn && !fanOnly
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ToggleTile(
                Icons.Outlined.Eco, "Eco", state.eco, accent, enabled = compressorAvailable,
                modifier = Modifier.weight(1f),
                onChange = { value -> actions.onApply { it.eco = value } },
            )
            ToggleTile(
                Icons.Outlined.Bolt, "Turbo", state.turbo, accent, enabled = compressorAvailable,
                modifier = Modifier.weight(1f),
                onChange = { value -> actions.onApply { it.turbo = value } },
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ToggleTile(
                Icons.Outlined.SwapVert, "Swing", state.swingMode != SwingMode.OFF, accent,
                enabled = state.powerOn,
                modifier = Modifier.weight(1f),
                onChange = { value ->
                    actions.onApply { it.swingMode = if (value) SwingMode.VERTICAL else SwingMode.OFF }
                },
            )
            ToggleTile(
                Icons.Outlined.Lightbulb, "Light", state.displayOn, accent, enabled = state.powerOn,
                modifier = Modifier.weight(1f),
                onChange = { actions.onToggleDisplay() },
            )
        }
    }
}

@Suppress("LongParameterList")
@Composable
private fun ToggleTile(
    icon: ImageVector,
    label: String,
    checked: Boolean,
    accent: AccentColors,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
    onChange: (Boolean) -> Unit,
) {
    Surface(
        checked = checked,
        onCheckedChange = onChange,
        enabled = enabled,
        shape = RoundedCornerShape(20.dp),
        color = if (checked) accent.container else MaterialTheme.colorScheme.surfaceContainerHigh,
        contentColor = if (checked) accent.onContainer else MaterialTheme.colorScheme.onSurface,
        modifier = modifier.height(56.dp),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 16.dp).alpha(if (enabled) 1f else DISABLED_ALPHA),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp))
            Text(
                label,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = if (checked) FontWeight.SemiBold else FontWeight.Medium,
            )
        }
    }
}

@Composable
private fun FilterCard() {
    var showHelp by remember { mutableStateOf(false) }
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.tertiaryContainer,
        contentColor = MaterialTheme.colorScheme.onTertiaryContainer,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(start = 16.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(Icons.Outlined.WarningAmber, contentDescription = null, modifier = Modifier.size(20.dp))
            Text("Filter needs cleaning", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
            TextButton(onClick = { showHelp = true }) {
                Text("How to", color = MaterialTheme.colorScheme.tertiary, fontWeight = FontWeight.SemiBold)
            }
        }
    }
    if (showHelp) {
        AlertDialog(
            onDismissRequest = { showHelp = false },
            confirmButton = { TextButton(onClick = { showHelp = false }) { Text("OK") } },
            title = { Text("Clearing the filter alert") },
            text = { Text(FilterResetGuide.INSTRUCTIONS) },
        )
    }
}

/**
 * Prompts, once, to grant unrestricted battery in the app's Settings page. The Quick Settings tile keeps the AC
 * connection warm with a short foreground service; Android blocks starting that service
 * from a passive tile pull *unless* the app is exempt from battery optimization — so
 * without this grant the tile still works, falling back to a cold reconnect on every pull.
 * Surfaced here rather than left hidden. Clears itself once the grant is made.
 */
@Composable
private fun BatteryOptimizationBanner() {
    val context = LocalContext.current
    val powerManager = remember { context.getSystemService(PowerManager::class.java) }
    var ignoring by remember {
        mutableStateOf(powerManager?.isIgnoringBatteryOptimizations(context.packageName) ?: true)
    }
    var dismissed by rememberSaveable { mutableStateOf(false) }
    // Re-check on resume so the banner clears the moment the grant is made, here or in Settings.
    LifecycleResumeEffect(Unit) {
        ignoring = powerManager?.isIgnoringBatteryOptimizations(context.packageName) ?: true
        onPauseOrDispose { }
    }
    if (ignoring || dismissed) return

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {}
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        contentColor = MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, top = 8.dp, end = 16.dp),
    ) {
        Column {
            Row(
                modifier = Modifier.fillMaxWidth().padding(start = 16.dp, top = 14.dp, end = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(Icons.Outlined.Info, contentDescription = null)
                Text(
                    "Allow unrestricted battery so the Quick Settings tile stays connected. Without it, " +
                        "Android drops the connection between uses and the tile has to reconnect each time.",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.weight(1f),
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
            ) {
                TextButton(onClick = { dismissed = true }) { Text("Not now") }
                TextButton(onClick = { launcher.launch(batteryOptimizationIntent(context)) }) { Text("Allow") }
            }
        }
    }
}

/** Asks for the Android 17 local network grant, without which the AC can't be reached at all. */
@Composable
private fun LocalNetworkBanner(onAllow: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        contentColor = MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, top = 8.dp, end = 16.dp),
    ) {
        Column {
            Row(
                modifier = Modifier.fillMaxWidth().padding(start = 16.dp, top = 14.dp, end = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(Icons.Outlined.Info, contentDescription = null)
                Text(
                    "Allow local network access so Drift can reach your AC over Wi-Fi.",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.weight(1f),
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                TextButton(onClick = onAllow) { Text("Allow") }
            }
        }
    }
}

// The app's own Settings page, where "App battery usage" holds the Unrestricted choice. The
// direct exemption prompt needs a permission Google Play only grants to a short list of app kinds.
private fun batteryOptimizationIntent(context: Context): Intent =
    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))

@Composable
private fun EditableName(
    nickname: String,
    placeholder: String,
    onChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val editing = remember { mutableStateOf(false) }
    if (editing.value) {
        val focusRequester = remember { FocusRequester() }
        val hasFocused = remember { mutableStateOf(false) }
        OutlinedTextField(
            value = nickname,
            onValueChange = onChange,
            placeholder = { Text(placeholder) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { editing.value = false }),
            modifier = modifier
                .focusRequester(focusRequester)
                .onFocusChanged { state ->
                    // Only dismiss after the field has actually gained focus,
                    // otherwise the initial unfocused callback cancels editing.
                    if (state.isFocused) hasFocused.value = true
                    else if (hasFocused.value) editing.value = false
                },
        )
        LaunchedEffect(Unit) { focusRequester.requestFocus() }
    } else {
        Box(modifier = modifier) {
            Text(
                text = nickname.ifBlank { placeholder },
                style = MaterialTheme.typography.titleLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.clickable { editing.value = true }.padding(vertical = 4.dp),
            )
        }
    }
}

// Dial geometry, as fractions of the dial's width unless noted.
private val DIAL_MAX_WIDTH = 300.dp
private const val DIAL_HEIGHT_FRACTION = 272f / 300f
private const val DIAL_RADIUS_FRACTION = 0.4f
private const val DIAL_TRACK_FRACTION = 22f / 300f
private const val DIAL_KNOB_FRACTION = 15f / 300f
private const val DIAL_KNOB_RING_FRACTION = 4f / 300f
private const val DIAL_DOT_FRACTION = 3.5f / 300f
private const val DIAL_SETPOINT_FRACTION = 88f / 300f
private const val DIAL_READOUT_TOP_FRACTION = 52f / 300f
private const val ARC_START_DEGREES = 135f
private const val ARC_SWEEP_DEGREES = 270f
private const val FULL_TURN = 360f
private const val DISABLED_ALPHA = 0.38f
// Extra reach beyond the drawn track that still grabs the ring.
private val RING_TOUCH_MARGIN = 16.dp
private val STEP_BUTTON_SIZE = 56.dp
private val STEP_BUTTON_RING = 5.dp
// Space between the room line and the step buttons' rings below it.
private val READOUT_CLEARANCE = 4.dp
// Space between the setpoint and the room line.
private val READOUT_GAP = 4.dp

internal val sampleState = ACState(
    powerOn = true, targetTemperature = 24.0, mode = OperationalMode.COOL, fanSpeed = FanSpeed.MEDIUM,
    indoorTemperature = 25.0, outdoorTemperature = 30.0, swingMode = SwingMode.OFF, eco = false, turbo = false,
    sleep = false, fahrenheit = false, purifier = false, displayOn = true, filterAlert = true,
    freezeProtection = false, targetHumidity = null,
)

internal val previewActions = ControlActions(
    onNickname = {}, onApply = {}, onAdjustTemp = {}, onSetTemp = {}, onToggleDisplay = {},
    onRefresh = {}, onBeep = {}, onForget = {},
)

@Preview(showBackground = true, heightDp = 844)
@Composable
private fun ControlScreenPreview() {
    DriftTheme {
        Surface(color = MaterialTheme.colorScheme.background) {
            ControlScreen(
                ui = UiState(discoveredName = "net_ac_A71C", nickname = "Bedroom", state = sampleState),
                actions = previewActions,
            )
        }
    }
}

@Preview(showBackground = true, heightDp = 844, uiMode = Configuration.UI_MODE_NIGHT_YES)
@Composable
private fun ControlScreenOffDarkPreview() {
    DriftTheme {
        Surface(color = MaterialTheme.colorScheme.background) {
            ControlScreen(
                ui = UiState(
                    discoveredName = "net_ac_A71C",
                    state = sampleState.copy(powerOn = false, fanSpeed = FanSpeed.AUTO, filterAlert = false),
                ),
                actions = previewActions,
            )
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun SetupScreenPreview() {
    DriftTheme {
        SetupScreen(UiState(needsSetup = true), SetupState(), previewSetupActions)
    }
}

@Preview(showBackground = true)
@Composable
private fun SetupScreenWaitingPreview() {
    DriftTheme {
        SetupScreen(
            UiState(needsSetup = true),
            SetupState(
                phase = SetupPhase.Waiting(
                    SetupFailure(
                        message = "Found the AC and got its key, but the AC didn't answer.",
                        hint = "Another device may be connected to it. Close the app there.",
                    ),
                    retryAt = 0,
                ),
            ),
            previewSetupActions,
        )
    }
}

private val previewSetupActions = SetupActions(
    onSetUp = {},
    onEditAccount = {},
    onResume = {},
    onPause = {},
)
