import MideaKit
import SwiftUI

/// Human-readable labels for the protocol types. MideaKit is protocol-only, so the
/// presentation strings the UI and widget show live here.
extension OperationalMode {
  /// Lowercase name, such as "fan", or "mode(7)" for a mode without a name.
  var display: String {
    switch self {
    case .auto: return "auto"
    case .cool: return "cool"
    case .dry: return "dry"
    case .heat: return "heat"
    case .fanOnly: return "fan"
    case .smartDry: return "smart dry"
    default: return "mode(\(rawValue))"
    }
  }

  /// SF Symbol for the mode, or the power symbol for a mode without a name.
  var symbol: String {
    switch self {
    case .auto: return "sparkles"
    case .cool: return "snowflake"
    case .dry, .smartDry: return "drop"
    case .heat: return "sun.max"
    case .fanOnly: return "fan"
    default: return "power"
    }
  }

  /// What the unit is doing in this mode, e.g. "Cooling".
  var activity: String {
    switch self {
    case .auto: return "Auto"
    case .cool: return "Cooling"
    case .dry, .smartDry: return "Drying"
    case .heat: return "Heating"
    case .fanOnly: return "Fan only"
    default: return display.capitalized
    }
  }
}

extension FanSpeed {
  /// Lowercase name, such as "low", or "fan(55)" for a speed without a name.
  var display: String {
    switch self {
    case .silent: return "silent"
    case .low: return "low"
    case .medium: return "medium"
    case .high: return "high"
    case .auto: return "auto"
    case .max: return "max"
    default: return "fan(\(rawValue))"
    }
  }
}

extension Snapshot {
  /// Mode color used to tint the app's controls and the widget. `nil` when the unit
  /// is off or reports a mode the UI has no color for.
  var accent: Color? {
    guard powerOn else { return nil }
    switch mode {
    case .cool: return .blue
    case .heat: return .orange
    case .dry, .smartDry: return .teal
    case .fanOnly:
      #if os(iOS)
        return .green
      #else
        return .mint
      #endif
    case .auto: return .indigo
    default: return nil
    }
  }
}
