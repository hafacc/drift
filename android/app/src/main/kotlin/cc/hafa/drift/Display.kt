package cc.hafa.drift

import io.hafa.mideakt.ACState
import io.hafa.mideakt.FanSpeed
import io.hafa.mideakt.OperationalMode

/**
 * Human-readable labels for the protocol types. mideakt is protocol-only, so the
 * presentation strings the UI shows live here.
 */
val OperationalMode.display: String
    get() = when (this) {
        OperationalMode.AUTO -> "auto"
        OperationalMode.COOL -> "cool"
        OperationalMode.DRY -> "dry"
        OperationalMode.HEAT -> "heat"
        OperationalMode.FAN_ONLY -> "fan"
        OperationalMode.SMART_DRY -> "smart dry"
        else -> "mode($raw)"
    }

/** Lowercase name, such as "low", or "fan(55)" for a speed without a name. */
val FanSpeed.display: String
    get() = when (this) {
        FanSpeed.SILENT -> "silent"
        FanSpeed.LOW -> "low"
        FanSpeed.MEDIUM -> "medium"
        FanSpeed.HIGH -> "high"
        FanSpeed.AUTO -> "auto"
        FanSpeed.MAX -> "max"
        else -> "fan($raw)"
    }

/** The current mode as a display string, persisted for the tile and widget. */
val ACState.modeName: String
    get() = mode.display
