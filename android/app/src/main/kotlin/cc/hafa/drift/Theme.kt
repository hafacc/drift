package cc.hafa.drift

import android.content.Context
import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.core.graphics.ColorUtils
import io.hafa.mideakt.OperationalMode

@Composable
fun DriftTheme(content: @Composable () -> Unit) {
    val colors = driftColorScheme(LocalContext.current, isSystemInDarkTheme())
    MaterialTheme(colorScheme = colors, content = content)
}

/** The wallpaper scheme on Android 12+, Material's baseline below. */
fun driftColorScheme(context: Context, dark: Boolean): ColorScheme =
    when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }

/** Colours for the accented parts of the control screen: a solid fill (and its content)
 *  for selected/filled controls, a tone for accent-coloured text on the page background,
 *  and a softer container for toggled-on tiles. */
@Immutable
data class AccentColors(
    val fill: Color,
    val onFill: Color,
    val text: Color,
    val container: Color,
    val onContainer: Color,
)

/** The scheme's primary roles nudged toward the mode's hue, or neutral roles when the unit is off. */
@Composable
fun accentColors(powerOn: Boolean, mode: OperationalMode): AccentColors {
    val scheme = MaterialTheme.colorScheme
    return remember(scheme, powerOn, mode) { accentColors(scheme, powerOn, mode) }
}

fun accentColors(scheme: ColorScheme, powerOn: Boolean, mode: OperationalMode): AccentColors {
    val hue = mode.hue
    return when {
        !powerOn -> AccentColors(
            fill = scheme.outline,
            onFill = scheme.surface,
            text = scheme.onSurfaceVariant,
            container = scheme.surfaceContainerHighest,
            onContainer = scheme.onSurface,
        )
        hue == null -> AccentColors(
            fill = scheme.primary,
            onFill = scheme.onPrimary,
            text = scheme.primary,
            container = scheme.primaryContainer,
            onContainer = scheme.onPrimaryContainer,
        )
        else -> AccentColors(
            fill = scheme.primary.towardHue(hue),
            onFill = scheme.onPrimary.towardHue(hue),
            text = scheme.primary.towardHue(hue),
            container = scheme.primaryContainer.towardHue(hue),
            onContainer = scheme.onPrimaryContainer.towardHue(hue),
        )
    }
}

// Hue (degrees) each mode leans toward; null for a mode without a name.
private val OperationalMode.hue: Float?
    get() = when (this) {
        OperationalMode.COOL -> 215f
        OperationalMode.HEAT -> 25f
        OperationalMode.DRY, OperationalMode.SMART_DRY -> 175f
        OperationalMode.FAN_ONLY -> 145f
        OperationalMode.AUTO -> 245f
        else -> null
    }

/** Rotates the hue part of the way to [targetHue], then re-solves HSL lightness so the
 *  relative luminance — and so contrast against the role's pair — is unchanged. */
private fun Color.towardHue(targetHue: Float): Color {
    val argb = toArgb()
    val hsl = FloatArray(3)
    ColorUtils.colorToHSL(argb, hsl)
    val (hue, saturation) = hsl
    val delta = (targetHue - hue + 540f) % 360f - 180f
    val shift = (delta * HUE_BLEND).coerceIn(-MAX_HUE_SHIFT, MAX_HUE_SHIFT)
    val shiftedHue = (hue + shift + 360f) % 360f
    val luminance = ColorUtils.calculateLuminance(argb)
    var low = 0f
    var high = 1f
    repeat(LIGHTNESS_SEARCH_STEPS) {
        val middle = (low + high) / 2
        val candidate = ColorUtils.HSLToColor(floatArrayOf(shiftedHue, saturation, middle))
        if (ColorUtils.calculateLuminance(candidate) < luminance) {
            low = middle
        } else {
            high = middle
        }
    }
    val shifted = ColorUtils.HSLToColor(floatArrayOf(shiftedHue, saturation, (low + high) / 2))
    return Color(shifted).copy(alpha = alpha)
}

private const val HUE_BLEND = 0.5f
private const val MAX_HUE_SHIFT = 60f
private const val LIGHTNESS_SEARCH_STEPS = 16
