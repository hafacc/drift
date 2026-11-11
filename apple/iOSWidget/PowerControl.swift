import AppIntents
import MideaKit
import SwiftUI
import WidgetKit

/// The AC's last confirmed reading, as the power control shows it.
struct PowerReading: Sendable {
  /// The AC's display name.
  var name: String
  /// The confirmed reading, or `nil` when there is none to trust.
  var snapshot: Snapshot?

  /// Whether the AC is on.
  var isOn: Bool { snapshot?.powerOn ?? false }

  /// The mode's symbol while `isOn`, otherwise the power symbol.
  func symbol(isOn: Bool) -> String {
    guard let snapshot, isOn else { return "power" }
    return snapshot.mode.symbol
  }

  /// E.g. "Cool · 24°" while `isOn`, "Off" while off, or "Not Connected" without a reading.
  func summary(isOn: Bool) -> String {
    guard let snapshot else { return isOn ? "On" : "Not Connected" }
    guard isOn else { return "Off" }
    let mode = snapshot.mode.display.capitalized
    if snapshot.mode == .fanOnly {
      return mode
    } else {
      return "\(mode) · \(Int(snapshot.targetTemperature.rounded()))°"
    }
  }

  /// The mode color the control shows while on, even before the AC reports it on.
  var onTint: Color {
    guard var snapshot else { return .gray }
    snapshot.powerOn = true
    return snapshot.accent ?? .gray
  }

  /// A cooling AC, for the control gallery.
  static var preview: PowerReading {
    PowerReading(
      name: "AC",
      snapshot: Snapshot(
        deviceName: "AC", powerOn: true, mode: .cool, targetTemperature: 24,
        indoorTemperature: 26, outdoorTemperature: 31))
  }

  /// Read the AC's power: the app's reading while it's connected, a recent stored one, or a
  /// fresh one fetched now.
  static func current() async -> PowerReading {
    guard let device = SharedStore.loadDevice() else {
      return PowerReading(name: "Drift", snapshot: nil)
    }
    let stored = SharedStore.loadSnapshot()
    let storedAge = stored.map { Date().timeIntervalSince($0.updated) } ?? .infinity
    if SharedStore.appIsLive(within: ACProvider.liveFetchStaleAfter) {
      // The app holds the AC's only connection; trust its reading only while it's current.
      let current = SharedStore.appIsConnected || storedAge < ACProvider.liveFetchStaleAfter
      return PowerReading(name: device.displayName, snapshot: current ? stored : nil)
    } else if storedAge < ACProvider.liveFetchStaleAfter {
      return PowerReading(name: device.displayName, snapshot: stored)
    } else {
      switch await ACProvider.fetchLive(device) {
      case .fetched(let live):
        WidgetCenter.shared.reloadAllTimelines()
        return PowerReading(name: device.displayName, snapshot: live)
      case .failed:
        return PowerReading(name: device.displayName, snapshot: nil)
      case .skipped:
        // The process using the AC reloads every control once it's done.
        return PowerReading(name: device.displayName, snapshot: stored)
      }
    }
  }
}

/// Supplies the power control's reading.
struct PowerControlProvider: ControlValueProvider {
  var previewValue: PowerReading { .preview }

  func currentValue() async throws -> PowerReading {
    await PowerReading.current()
  }
}

/// Turns the AC on or off.
struct SetPowerIntent: SetValueIntent {
  static let title: LocalizedStringResource = "Set AC Power"
  static let description = IntentDescription("Turns your air conditioner on or off.")

  @Parameter(title: "Power") var value: Bool

  init() {}

  func perform() async throws -> some IntentResult {
    await WidgetCommandRunner.run(.setPower(value))
    return .result()
  }
}

/// A Control Center, Lock Screen and Action button control that turns the AC on or off.
struct PowerControl: ControlWidget {
  static let kind = "cc.hafa.Drift.PowerControl"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind, provider: PowerControlProvider()) { reading in
      ControlWidgetToggle(reading.name, isOn: reading.isOn, action: SetPowerIntent()) { isOn in
        Label(reading.summary(isOn: isOn), systemImage: reading.symbol(isOn: isOn))
      }
      .tint(reading.onTint)
    }
    .displayName("AC Power")
    .description("Turn your air conditioner on or off.")
  }
}
