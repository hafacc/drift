import AppIntents
import MideaKit
import SwiftUI
import WidgetKit

/// Words and colors a widget shows for one entry, shared by every widget size.
struct WidgetReading {
  /// The reading shown.
  let snapshot: Snapshot
  /// Whether the reading is too old to trust, so it shows greyed out.
  let isStale: Bool

  /// The mode color, or `nil` while the AC is off or the reading is stale.
  var accent: Color? { isStale ? nil : snapshot.accent }

  /// Whether − and + apply: the AC is on and has a target.
  var canStep: Bool { snapshot.powerOn && snapshot.mode != .fanOnly }

  /// E.g. "COOLING TO", or "OFF".
  var label: String {
    guard snapshot.powerOn else { return "OFF" }
    switch snapshot.mode {
    case .cool: return "COOLING TO"
    case .heat: return "HEATING TO"
    case .fanOnly: return "FAN ONLY"
    default: return "TARGET"
    }
  }

  /// The target, such as "24°".
  var target: String { "\(Int(snapshot.targetTemperature.rounded()))°" }

  /// The mode's name, or "Off".
  var modeName: String { snapshot.powerOn ? snapshot.mode.display.capitalized : "Off" }

  /// "Indoor 26°", or when the reading was last seen if it's stale.
  var indoor: String? { indoor(lastSeenPrefix: "Last seen", indoorPrefix: "Indoor") }

  /// The same, lowercased to follow other text on its line, as "indoor 26°".
  var inlineIndoor: String? { indoor(lastSeenPrefix: "last seen", indoorPrefix: "indoor") }

  /// Whether the target means anything: not in Fan mode, which has none.
  var hasTarget: Bool { snapshot.mode != .fanOnly }

  /// "Indoor 26° · Outdoor 31°", or when the reading was last seen if it's stale.
  var temperatures: String? {
    guard !isStale else { return indoor }
    let parts = [
      snapshot.indoorTemperature.map { "Indoor \(Int($0.rounded()))°" },
      snapshot.outdoorTemperature.map { "Outdoor \(Int($0.rounded()))°" },
    ].compactMap(\.self)
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func indoor(lastSeenPrefix: String, indoorPrefix: String) -> String? {
    if isStale {
      return "\(lastSeenPrefix) \(lastSeen)"
    } else {
      return snapshot.indoorTemperature.map { "\(indoorPrefix) \(Int($0.rounded()))°" }
    }
  }

  private var lastSeen: String {
    if Calendar.current.isDateInToday(snapshot.updated) {
      return snapshot.updated.formatted(date: .omitted, time: .shortened)
    } else {
      return snapshot.updated.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
  }
}

/// The Home Screen widget: the target and indoor temperature, with power and − and + when
/// medium.
struct HomeWidgetView: View {
  @Environment(\.widgetFamily) private var systemFamily
  @Environment(\.widgetRenderingMode) private var renderingMode
  let entry: ACEntry
  /// The size to lay out for, or `nil` for the one the system gives.
  var familyOverride: WidgetFamily?

  private var family: WidgetFamily { familyOverride ?? systemFamily }

  var body: some View {
    if let snapshot = entry.snapshot {
      let reading = WidgetReading(snapshot: snapshot, isStale: entry.isStale)
      if family == .systemMedium {
        medium(reading)
      } else {
        small(reading)
      }
    } else {
      WidgetPlaceholder(hasDevice: entry.hasDevice)
    }
  }

  private func small(_ reading: WidgetReading) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(reading.snapshot.deviceName)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
      Spacer(minLength: 4)
      Text(reading.label)
        .font(.caption.weight(.semibold))
        .foregroundStyle(reading.accent ?? .secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .widgetAccentable()
      targetText(reading)
      if let indoor = reading.indoor {
        Text(indoor)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func medium(_ reading: WidgetReading) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(reading.snapshot.deviceName) · \(reading.modeName)")
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Spacer(minLength: 0)
        targetText(reading)
        if let temperatures = reading.temperatures {
          Text(temperatures)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      buttons(reading)
        .disabled(entry.sending)
        .opacity(entry.sending ? 0.5 : 1)
    }
  }

  private func targetText(_ reading: WidgetReading) -> some View {
    Text(reading.target)
      .font(.system(size: 64, weight: .light))
      .monospacedDigit()
      .foregroundStyle(reading.canStep && !reading.isStale ? .primary : .secondary)
      .lineLimit(1)
      .minimumScaleFactor(0.4)
  }

  /// Power, with − and + below while the AC has a target to change.
  private func buttons(_ reading: WidgetReading) -> some View {
    VStack(spacing: 8) {
      Button(intent: TogglePowerIntent()) {
        if renderingMode == .fullColor {
          CircleGlyph(symbol: "power")
            .foregroundStyle(
              reading.accent == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white)
            )
            .padding(12)
            .background(reading.accent ?? Color(.systemFill), in: Circle())
        } else {
          // Tinted and clear Home Screens draw by alpha in one color, so a solid disc would
          // swallow the glyph.
          CircleGlyph(symbol: "power")
            .widgetAccentable(reading.accent != nil)
            .padding(12)
            .background(.primary.opacity(0.15), in: Circle())
        }
      }
      .buttonStyle(.plain)
      .accessibilityLabel(reading.snapshot.powerOn ? "Turn off" : "Turn on")
      if reading.canStep {
        HStack(spacing: 8) {
          stepButton("minus", label: "Colder", delta: -1, reading: reading)
          stepButton("plus", label: "Warmer", delta: 1, reading: reading)
        }
      }
    }
    .frame(maxHeight: .infinity)
  }

  private func stepButton(_ symbol: String, label: String, delta: Int, reading: WidgetReading)
    -> some View
  {
    Button(intent: AdjustTemperatureIntent(delta: delta)) {
      CircleGlyph(symbol: symbol)
        .foregroundStyle(reading.accent ?? .primary)
        .padding(12)
        .background((reading.accent ?? .primary).opacity(0.12), in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

/// A button symbol in a square of the power symbol's size, so every round button matches.
private struct CircleGlyph: View {
  let symbol: String

  var body: some View {
    ZStack {
      Image(systemName: "power").hidden()
      Image(systemName: symbol)
    }
    .font(.title3.weight(.semibold))
  }
}

/// Shown without a reading: connecting once set up, otherwise a pointer to setup.
struct WidgetPlaceholder: View {
  let hasDevice: Bool

  var body: some View {
    VStack(spacing: 4) {
      Image(systemName: hasDevice ? "arrow.triangle.2.circlepath" : "wifi.slash")
        .foregroundStyle(.secondary)
      Text(hasDevice ? "Connecting…" : "Open Drift to set up")
        .font(.caption)
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// The small and medium Home Screen widgets.
struct HomeWidget: Widget {
  static let kind = "DriftWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: ACProvider()) { entry in
      HomeWidgetView(entry: entry)
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "drift://open"))
    }
    .configurationDisplayName("Drift")
    .description("See your AC's target and room temperature, and change them.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

/// The read-only Lock Screen widgets: the mode and target, and the indoor temperature.
struct LockScreenWidgetView: View {
  @Environment(\.widgetFamily) private var systemFamily
  let entry: ACEntry
  /// The size to lay out for, or `nil` for the one the system gives.
  var familyOverride: WidgetFamily?

  private var family: WidgetFamily { familyOverride ?? systemFamily }

  var body: some View {
    if let snapshot = entry.snapshot {
      let reading = WidgetReading(snapshot: snapshot, isStale: entry.isStale)
      if family == .accessoryCircular {
        circular(reading)
      } else {
        rectangular(reading)
      }
    } else if family == .accessoryCircular {
      ZStack {
        AccessoryWidgetBackground()
        Image(systemName: entry.hasDevice ? "arrow.triangle.2.circlepath" : "wifi.slash")
      }
    } else {
      WidgetPlaceholder(hasDevice: entry.hasDevice)
    }
  }

  private func circular(_ reading: WidgetReading) -> some View {
    ZStack {
      AccessoryWidgetBackground()
      VStack(spacing: 0) {
        Image(systemName: reading.snapshot.powerOn ? reading.snapshot.mode.symbol : "power")
          .font(.caption)
        Text(reading.snapshot.powerOn ? (reading.hasTarget ? reading.target : "Fan") : "Off")
          .font(.title3.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.5)
      }
      .padding(4)
    }
    .opacity(reading.isStale ? 0.6 : 1)
  }

  private func rectangular(_ reading: WidgetReading) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("\(reading.snapshot.deviceName) · \(reading.modeName)")
        .font(.headline)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        if reading.hasTarget {
          Text(reading.target)
            .font(.title2.weight(.semibold))
            .lineLimit(1)
        }
        if let indoor = reading.hasTarget ? reading.inlineIndoor : reading.indoor {
          Text(indoor)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .opacity(reading.isStale ? 0.6 : 1)
  }
}

/// The Lock Screen widgets; a tap opens the app.
struct LockScreenWidget: Widget {
  static let kind = "DriftLockScreenWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: ACProvider()) { entry in
      LockScreenWidgetView(entry: entry)
        .containerBackground(.clear, for: .widget)
        .widgetURL(URL(string: "drift://open"))
    }
    .configurationDisplayName("Drift")
    .description("See your AC's mode, target and room temperature.")
    .supportedFamilies([.accessoryCircular, .accessoryRectangular])
  }
}

/// Every widget and control Drift offers.
@main
struct DriftWidgetBundle: WidgetBundle {
  var body: some Widget {
    HomeWidget()
    LockScreenWidget()
    PowerControl()
  }
}

private let previewSnapshot = Snapshot(
  deviceName: "Bedroom", powerOn: true, mode: .cool, targetTemperature: 24,
  indoorTemperature: 26, outdoorTemperature: 31)

private var offSnapshot: Snapshot {
  var snapshot = previewSnapshot
  snapshot.powerOn = false
  snapshot.updated = Date() - 1_800
  return snapshot
}

#Preview("Small", as: .systemSmall) {
  HomeWidget()
} timeline: {
  ACEntry(date: Date(), snapshot: previewSnapshot, hasDevice: true)
  ACEntry(date: Date(), snapshot: offSnapshot, hasDevice: true)
}

#Preview("Medium", as: .systemMedium) {
  HomeWidget()
} timeline: {
  ACEntry(date: Date(), snapshot: previewSnapshot, hasDevice: true)
  ACEntry(date: Date(), snapshot: offSnapshot, hasDevice: true)
}

#Preview("Lock Screen", as: .accessoryRectangular) {
  LockScreenWidget()
} timeline: {
  ACEntry(date: Date(), snapshot: previewSnapshot, hasDevice: true)
}
