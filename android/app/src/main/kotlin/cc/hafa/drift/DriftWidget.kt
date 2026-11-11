package cc.hafa.drift

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.text.format.DateUtils
import androidx.annotation.DrawableRes
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.Action
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import io.hafa.mideakt.OperationalMode
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.roundToInt

/** Bound the live reach so an unreachable AC can't stall the widget for tens of
 *  seconds through [DeviceManager]'s retry/discovery path — long enough to risk
 *  Glance's session-worker timeout and freeze the widget. Mirrors the macOS widget's
 *  8s `fetchBudget`; on timeout we fall back to the cached last-known state. */
private const val FETCH_BUDGET_MS = 8_000L

private val SquareSize = DpSize(110.dp, 110.dp)
private val WideSize = DpSize(250.dp, 48.dp)
// A short, narrow widget: the wide layout without room for the steppers.
private val StripSize = DpSize(110.dp, 48.dp)
// Big enough for a row of mode buttons under the steppers.
private val ModesSize = DpSize(160.dp, 180.dp)
// Opacity of the − and + pills' tint over the "on" background.
private const val STEP_ALPHA = 0.12f
// A reading older than this is shown greyed out as "last seen".
private const val STALE_AFTER_MS = 10 * 60 * 1000L
// The modes the widget offers, as the app's mode tiles do.
private val WidgetModes =
    listOf(OperationalMode.AUTO, OperationalMode.COOL, OperationalMode.DRY, OperationalMode.FAN_ONLY)

/** Home-screen widget showing the AC state, with power, setpoint and mode controls; fetches
 *  live in provideGlance, then follows the stored last reading as it changes. */
class DriftWidget : GlanceAppWidget() {
    override val sizeMode: SizeMode = SizeMode.Responsive(setOf(SquareSize, WideSize, StripSize, ModesSize))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val store = CredentialStore(context)
        val reach = store.load()?.let {
            withTimeoutOrNull(FETCH_BUDGET_MS) { DriftApplication.devices(context).refresh() }
        }
        // Shown only when there's no reading at all; a successful reach has already been
        // saved as the last state, which is what the content renders.
        val caption = when (reach) {
            is Reachability.Busy -> "In use"
            is Reachability.NoWifi -> "No Wi-Fi"
            else -> "Not found"
        }
        provideContent {
            val revision by CredentialStore.revisions.collectAsState()
            val snapshot = remember(revision) { WidgetSnapshot.load(store) }
            val updatedAt = snapshot.last?.updatedAtMillis
            LaunchedEffect(updatedAt) { scheduleStaleRedraw(context, updatedAt) }
            GlanceTheme {
                WidgetContent(context, snapshot, caption)
            }
        }
    }
}

class DriftWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = DriftWidget()
}

/** Toggles power through the app's shared connection, then repaints the widget. */
class TogglePowerAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        withTimeoutOrNull(FETCH_BUDGET_MS) { DriftApplication.devices(context).togglePower() }
        DriftWidget().update(context, glanceId)
    }
}

/** Steps the setpoint by [DeltaKey] degrees through the app's shared connection, then
 *  repaints the widget. */
class StepTemperatureAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val delta = parameters[DeltaKey] ?: return
        withTimeoutOrNull(FETCH_BUDGET_MS) { DriftApplication.devices(context).stepTemperature(delta) }
        DriftWidget().update(context, glanceId)
    }

    companion object {
        val DeltaKey = ActionParameters.Key<Int>("delta")
    }
}

/** Sets the mode in [ModeKey] and turns the AC on through the app's shared connection, then
 *  repaints the widget. */
class SetModeAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val mode = parameters[ModeKey]?.let { OperationalMode(it) } ?: return
        withTimeoutOrNull(FETCH_BUDGET_MS) {
            DriftApplication.devices(context).apply { state -> state.mode = mode; state.powerOn = true }
        }
        DriftWidget().update(context, glanceId)
    }

    companion object {
        val ModeKey = ActionParameters.Key<Int>("mode")
    }
}

/** Ask for a redraw when the reading taken at [updatedAtMillis] turns stale, so it greys out on time. */
private fun scheduleStaleRedraw(context: Context, updatedAtMillis: Long?) {
    val staleAt = updatedAtMillis?.plus(STALE_AFTER_MS)
    val alarms = context.getSystemService(AlarmManager::class.java)
    if (staleAt == null || staleAt <= System.currentTimeMillis() || alarms == null) return
    val widgetIds = AppWidgetManager.getInstance(context)
        .getAppWidgetIds(ComponentName(context, DriftWidgetReceiver::class.java))
    val redraw = Intent(context, DriftWidgetReceiver::class.java)
        .setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, widgetIds)
    // One request code, so each new reading replaces the previous reading's alarm.
    val pending = PendingIntent.getBroadcast(
        context,
        0,
        redraw,
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
    alarms.set(AlarmManager.RTC, staleAt, pending)
}

private data class WidgetSnapshot(val name: String, val configured: Boolean, val last: LastState?) {
    companion object {
        fun load(store: CredentialStore): WidgetSnapshot {
            val credentials = store.load()
            return WidgetSnapshot(
                // Nickname if set, else the device's own name; bare "AC" until one is set up.
                name = credentials?.let { store.nickname().ifBlank { it.name } } ?: "AC",
                configured = credentials != null,
                last = credentials?.let { store.lastState() },
            )
        }
    }
}

/** Colours for one widget render: the app's mode-blended accent when on, the theme's neutral roles when off. */
@Suppress("LongParameterList")
private class WidgetColors(
    val background: ColorProvider,
    val content: ColorProvider,
    val muted: ColorProvider,
    val control: ColorProvider,
    val onControl: ColorProvider,
    val step: ColorProvider,
    val selected: ColorProvider,
    val onSelected: ColorProvider,
)

@Composable
private fun widgetColors(context: Context, powerOn: Boolean, mode: OperationalMode?): WidgetColors =
    if (!powerOn || mode == null) {
        WidgetColors(
            background = GlanceTheme.colors.widgetBackground,
            content = GlanceTheme.colors.onSurface,
            muted = GlanceTheme.colors.onSurfaceVariant,
            control = GlanceTheme.colors.secondaryContainer,
            onControl = GlanceTheme.colors.onSecondaryContainer,
            step = GlanceTheme.colors.secondaryContainer,
            selected = GlanceTheme.colors.primary,
            onSelected = GlanceTheme.colors.onPrimary,
        )
    } else {
        // Glance can't blend its own providers, so resolve the same scheme the app uses for each mode.
        val day = accentColors(driftColorScheme(context, dark = false), powerOn = true, mode)
        val night = accentColors(driftColorScheme(context, dark = true), powerOn = true, mode)
        WidgetColors(
            background = ColorProvider(day = day.container, night = night.container),
            content = ColorProvider(day = day.onContainer, night = night.onContainer),
            muted = ColorProvider(day = day.onContainer, night = night.onContainer),
            control = ColorProvider(day = day.fill, night = night.fill),
            onControl = ColorProvider(day = day.onFill, night = night.onFill),
            step = ColorProvider(
                day = day.onContainer.copy(alpha = STEP_ALPHA),
                night = night.onContainer.copy(alpha = STEP_ALPHA),
            ),
            selected = ColorProvider(day = day.fill, night = night.fill),
            onSelected = ColorProvider(day = day.onFill, night = night.onFill),
        )
    }

@Composable
private fun WidgetContent(context: Context, snapshot: WidgetSnapshot, caption: String) {
    val last = snapshot.last
    val mode = last?.let { reading -> OperationalMode.entries.firstOrNull { it.display == reading.modeName } }
    val lastSeen = last?.let { lastSeenCaption(context, it) }
    // A stale reading keeps its controls, so a press still reaches the AC and fetches a fresh one.
    val colors = widgetColors(context, last?.powerOn == true && lastSeen == null, mode)
    val size = LocalSize.current
    val openApp = actionStartActivity(Intent(context, MainActivity::class.java))
    val base = GlanceModifier
        .fillMaxSize()
        .appWidgetBackground()
        .background(colors.background)
        // Tapping anywhere but a button opens the app.
        .clickable(openApp)
    when {
        last == null -> {
            val message = if (snapshot.configured) caption else "Open app to set up"
            MessageLayout(base, snapshot.name, message, colors)
        }
        size.height < SquareSize.height ->
            WideLayout(
                base,
                snapshot.name,
                last,
                mode,
                colors,
                lastSeen,
                showSteppers = size.width >= WideSize.width,
            )
        else -> SquareLayout(
            base,
            snapshot.name,
            last,
            mode,
            colors,
            lastSeen,
            showModes = size.width >= ModesSize.width && size.height >= ModesSize.height,
        )
    }
}

@Composable
private fun MessageLayout(modifier: GlanceModifier, name: String, message: String, colors: WidgetColors) {
    Column(
        modifier = modifier.cornerRadius(28.dp).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        NameText(name, colors)
        Text(message, style = TextStyle(color = colors.muted, fontSize = 12.sp), maxLines = 2)
    }
}

@Suppress("LongParameterList")
@Composable
private fun SquareLayout(
    modifier: GlanceModifier,
    name: String,
    last: LastState,
    mode: OperationalMode?,
    colors: WidgetColors,
    lastSeen: String?,
    showModes: Boolean,
) {
    Column(modifier = modifier.cornerRadius(28.dp).padding(16.dp)) {
        Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            NameText(name, colors, GlanceModifier.defaultWeight())
            IconButton(
                R.drawable.ic_widget_power,
                if (last.powerOn) "Turn off" else "Turn on",
                colors.control,
                colors.onControl,
                actionRunCallback<TogglePowerAction>(),
                GlanceModifier.size(36.dp).cornerRadius(12.dp),
            )
        }
        Text(
            "${last.targetTemperature.roundToInt()}°",
            style = TextStyle(color = colors.content, fontSize = 52.sp, fontWeight = FontWeight.Bold),
            maxLines = 1,
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (last.powerOn && mode != null && lastSeen == null) {
                Image(
                    ImageProvider(mode.widgetIcon),
                    contentDescription = null,
                    colorFilter = ColorFilter.tint(colors.content),
                    modifier = GlanceModifier.size(13.dp),
                )
                Spacer(GlanceModifier.width(4.dp))
            }
            Text(
                lastSeen ?: summary(last),
                style = TextStyle(color = if (lastSeen == null) colors.content else colors.muted, fontSize = 12.sp),
                maxLines = 1,
            )
        }
        Spacer(GlanceModifier.defaultWeight())
        if (canStep(last, mode)) {
            Row(modifier = GlanceModifier.fillMaxWidth()) {
                StepButton(-1, colors, GlanceModifier.defaultWeight().height(36.dp).cornerRadius(18.dp))
                Spacer(GlanceModifier.width(6.dp))
                StepButton(1, colors, GlanceModifier.defaultWeight().height(36.dp).cornerRadius(18.dp))
            }
        }
        if (showModes) {
            Spacer(GlanceModifier.height(6.dp))
            ModeButtons(last, mode, colors)
        }
    }
}

@Composable
private fun ModeButtons(last: LastState, mode: OperationalMode?, colors: WidgetColors) {
    Row(modifier = GlanceModifier.fillMaxWidth()) {
        WidgetModes.forEachIndexed { index, option ->
            if (index > 0) Spacer(GlanceModifier.width(4.dp))
            val selected = last.powerOn && mode == option
            IconButton(
                option.widgetIcon,
                option.display.replaceFirstChar { it.uppercase() },
                if (selected) colors.selected else colors.step,
                if (selected) colors.onSelected else colors.content,
                actionRunCallback<SetModeAction>(actionParametersOf(SetModeAction.ModeKey to option.raw)),
                GlanceModifier.defaultWeight().height(32.dp).cornerRadius(12.dp),
            )
        }
    }
}

@Suppress("LongParameterList")
@Composable
private fun WideLayout(
    modifier: GlanceModifier,
    name: String,
    last: LastState,
    mode: OperationalMode?,
    colors: WidgetColors,
    lastSeen: String?,
    showSteppers: Boolean,
) {
    Row(
        modifier = modifier.cornerRadius(40.dp).padding(start = 16.dp, end = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Off, the round button reads as a power button; on, it shows the mode.
        IconButton(
            if (last.powerOn && mode != null) mode.widgetIcon else R.drawable.ic_widget_power,
            if (last.powerOn) "Turn off" else "Turn on",
            colors.control,
            colors.onControl,
            actionRunCallback<TogglePowerAction>(),
            GlanceModifier.size(48.dp).cornerRadius(24.dp),
        )
        Spacer(GlanceModifier.width(12.dp))
        Column(modifier = GlanceModifier.defaultWeight()) {
            NameText(name, colors)
            if (last.powerOn) {
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(
                        "${last.targetTemperature.roundToInt()}°",
                        style = TextStyle(color = colors.content, fontSize = 24.sp, fontWeight = FontWeight.Bold),
                    )
                    Spacer(GlanceModifier.width(4.dp))
                    Text(
                        lastSeen ?: last.modeName,
                        style = TextStyle(
                            color = if (lastSeen == null) colors.content else colors.muted,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Medium,
                        ),
                        maxLines = 1,
                        modifier = GlanceModifier.padding(bottom = 3.dp),
                    )
                }
            } else {
                Text(lastSeen ?: summary(last), style = TextStyle(color = colors.muted, fontSize = 13.sp), maxLines = 1)
            }
        }
        if (showSteppers && canStep(last, mode)) {
            StepButton(-1, colors, GlanceModifier.size(40.dp).cornerRadius(20.dp))
            Spacer(GlanceModifier.width(8.dp))
            StepButton(1, colors, GlanceModifier.size(40.dp).cornerRadius(20.dp))
        }
    }
}

@Composable
private fun NameText(name: String, colors: WidgetColors, modifier: GlanceModifier = GlanceModifier) {
    Text(
        name,
        style = TextStyle(color = colors.content, fontSize = 13.sp, fontWeight = FontWeight.Bold),
        maxLines = 1,
        modifier = modifier,
    )
}

@Suppress("LongParameterList")
@Composable
private fun IconButton(
    @DrawableRes icon: Int,
    description: String,
    background: ColorProvider,
    tint: ColorProvider,
    onClick: Action,
    modifier: GlanceModifier,
) {
    Box(
        modifier = modifier.background(background).clickable(onClick),
        contentAlignment = Alignment.Center,
    ) {
        Image(
            ImageProvider(icon),
            contentDescription = description,
            colorFilter = ColorFilter.tint(tint),
            modifier = GlanceModifier.size(20.dp),
        )
    }
}

@Composable
private fun StepButton(delta: Int, colors: WidgetColors, modifier: GlanceModifier) {
    Box(
        modifier = modifier
            .background(colors.step)
            .clickable(
                actionRunCallback<StepTemperatureAction>(actionParametersOf(StepTemperatureAction.DeltaKey to delta)),
            ),
        contentAlignment = Alignment.Center,
    ) {
        Image(
            ImageProvider(if (delta < 0) R.drawable.ic_widget_minus else R.drawable.ic_widget_plus),
            contentDescription = if (delta < 0) "Colder" else "Warmer",
            colorFilter = ColorFilter.tint(colors.content),
            modifier = GlanceModifier.size(16.dp),
        )
    }
}

/** Whether the setpoint can be stepped: the AC is on and not in fan-only mode, which has no setpoint. */
private fun canStep(last: LastState, mode: OperationalMode?): Boolean =
    last.powerOn && mode != OperationalMode.FAN_ONLY

/** "Last seen" and the reading's time, with its date unless it's from today; null while it's fresh. */
private fun lastSeenCaption(context: Context, last: LastState): String? {
    val updated = last.updatedAtMillis
    return if (updated == null || System.currentTimeMillis() - updated < STALE_AFTER_MS) {
        null
    } else {
        val flags = if (DateUtils.isToday(updated)) {
            DateUtils.FORMAT_SHOW_TIME
        } else {
            DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_TIME or
                DateUtils.FORMAT_ABBREV_MONTH or DateUtils.FORMAT_NO_YEAR
        }
        "Last seen ${DateUtils.formatDateTime(context, updated, flags)}"
    }
}

private fun summary(last: LastState): String {
    val state = if (last.powerOn) last.modeName.replaceFirstChar { it.uppercase() } else "Off"
    return listOfNotNull(state, last.indoorTemperature?.let { "room ${it.roundToInt()}°" }).joinToString(" · ")
}

@get:DrawableRes
private val OperationalMode.widgetIcon: Int
    get() = when (this) {
        OperationalMode.AUTO -> R.drawable.ic_mode_auto
        OperationalMode.COOL -> R.drawable.ic_mode_cool
        OperationalMode.DRY, OperationalMode.SMART_DRY -> R.drawable.ic_mode_dry
        OperationalMode.FAN_ONLY -> R.drawable.ic_mode_fan
        OperationalMode.HEAT -> R.drawable.ic_mode_heat
        else -> R.drawable.ic_widget_power
    }
