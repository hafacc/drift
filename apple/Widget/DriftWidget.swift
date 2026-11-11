import AppIntents
import MideaKit
import SwiftUI
import WidgetKit

/// Colours for a widget reading: white on the mode colour while on, neutral while off or
/// stale.
private struct WidgetPalette {
  let accent: Color?
  let foreground: Color
  let secondary: Color
  let control: Color  // − / + and power buttons
  let idle: Color  // unselected mode buttons
  let selected: Color  // selected mode button
  let selectedForeground: Color

  init(accent: Color?) {
    self.accent = accent
    if let accent {
      foreground = .white
      secondary = .white.opacity(0.88)
      control = .white.opacity(0.22)
      idle = .white.opacity(0.14)
      selected = .white
      selectedForeground = accent
    } else {
      foreground = .primary
      secondary = .secondary
      control = .primary.opacity(0.08)
      idle = .primary.opacity(0.05)
      selected = .primary.opacity(0.18)
      selectedForeground = .primary
    }
  }

  init(entry: ACEntry) {
    guard let snapshot = entry.snapshot, !Self.isStale(snapshot, at: entry.date) else {
      self.init(accent: nil)
      return
    }
    self.init(accent: snapshot.accent)
  }

  static func isStale(_ snapshot: Snapshot, at date: Date) -> Bool {
    date.timeIntervalSince(snapshot.updated) >= ACProvider.staleAfter
  }
}

struct DriftWidgetView: View {
  @Environment(\.widgetFamily) private var family
  @Environment(\.widgetRenderingMode) private var renderingMode
  var entry: ACEntry

  private let modes: [OperationalMode] = [.auto, .cool, .dry, .fanOnly]

  var body: some View {
    if let snapshot = entry.snapshot {
      // Off the desktop's full-colour mode the system drops the mode-coloured background
      // and tints by luminance, where white-on-accent controls wash out.
      let palette =
        renderingMode == .fullColor ? WidgetPalette(entry: entry) : WidgetPalette(accent: nil)
      if family == .systemMedium {
        HStack(spacing: 14) {
          summary(snapshot, palette: palette) {
            Text("Fan \(snapshot.fanSpeed.display)")
              .font(.system(size: 11))
              .foregroundStyle(palette.secondary)
          }
          controls(snapshot, palette: palette)
            .frame(width: 150)
            .disabled(entry.sending)
            .opacity(entry.sending ? 0.5 : 1)
        }
      } else {
        summary(snapshot, palette: palette) {
          HStack {
            Spacer()
            Button(intent: TogglePowerIntent()) {
              Image(systemName: "power")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(palette.control, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(snapshot.powerOn ? "Turn off" : "Turn on")
            .disabled(entry.sending)
            .opacity(entry.sending ? 0.5 : 1)
          }
        }
      }
    } else if entry.hasDevice {
      // Set up, but we have no reading yet (cold widget, app holding the
      // connection, or the unit briefly unreachable). Don't imply it's gone —
      // the tap still opens the app for a live look.
      VStack(spacing: 4) {
        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        Text("Connecting…")
          .font(.caption2)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 4) {
        Image(systemName: "wifi.slash").foregroundStyle(.secondary)
        Text("Open the app to set up")
          .font(.caption2)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func summary(
    _ snapshot: Snapshot, palette: WidgetPalette, @ViewBuilder bottom: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      header(snapshot)
        .foregroundStyle(snapshot.powerOn ? palette.foreground : palette.secondary)
      Text(snapshot.powerOn ? setpoint(snapshot) : "Off")
        .font(.system(size: 50, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .minimumScaleFactor(0.6)
        .lineLimit(1)
        .foregroundStyle(snapshot.powerOn ? palette.foreground : palette.secondary)
        .padding(.top, 4)
      // An old reading stays on screen with its controls, so a press still reaches the AC;
      // the press itself fetches a fresh one.
      Text(
        WidgetPalette.isStale(snapshot, at: entry.date)
          ? "Last seen \(lastSeen(snapshot.updated))" : detail(snapshot)
      )
      .font(.system(size: 11))
      .lineLimit(1)
      .foregroundStyle(palette.secondary)
      Spacer(minLength: 0)
      bottom()
    }
    .foregroundStyle(palette.foreground)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func header(_ snapshot: Snapshot) -> some View {
    HStack(spacing: 6) {
      Image(systemName: snapshot.powerOn ? snapshot.mode.symbol : "power")
      Text(snapshot.deviceName)
        .lineLimit(1)
    }
    .font(.system(size: 12, weight: .semibold))
  }

  private func controls(_ snapshot: Snapshot, palette: WidgetPalette) -> some View {
    let canStep = snapshot.powerOn && snapshot.mode != .fanOnly
    return VStack(spacing: 6) {
      HStack(spacing: 6) {
        temperatureButton("minus", label: "Colder", delta: -1, palette: palette)
        temperatureButton("plus", label: "Warmer", delta: 1, palette: palette)
      }
      .disabled(!canStep)
      .opacity(canStep ? 1 : 0.4)
      HStack(spacing: 4) {
        ForEach(modes, id: \.rawValue) { mode in
          let selected = snapshot.powerOn && snapshot.mode == mode
          Button(intent: SetModeIntent(mode: mode)) {
            Image(systemName: mode.symbol)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(selected ? palette.selectedForeground : palette.foreground)
              .frame(maxWidth: .infinity, minHeight: 30)
              .background(
                selected ? palette.selected : palette.idle,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(mode.display.capitalized)
        }
      }
      Button(intent: TogglePowerIntent()) {
        Label(snapshot.powerOn ? "Turn off" : "Turn on", systemImage: "power")
          .font(.system(size: 12, weight: .semibold))
          .frame(maxWidth: .infinity, minHeight: 30)
          .background(palette.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
      .buttonStyle(.plain)
    }
    .foregroundStyle(palette.foreground)
  }

  private func temperatureButton(
    _ symbol: String, label: String, delta: Int, palette: WidgetPalette
  ) -> some View {
    Button(intent: AdjustTemperatureIntent(delta: delta)) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .semibold))
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(palette.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  private func setpoint(_ snapshot: Snapshot) -> String {
    "\(Int(snapshot.targetTemperature.rounded()))°"
  }

  /// E.g. "Cooling · room 25°" while on, "Room 27°" while off.
  private func detail(_ snapshot: Snapshot) -> String {
    let room = snapshot.indoorTemperature.map { "\(Int($0.rounded()))°" }
    guard snapshot.powerOn else { return room.map { "Room \($0)" } ?? "" }
    let activity = snapshot.mode.activity
    return room.map { "\(activity) · room \($0)" } ?? activity
  }

  private func lastSeen(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) {
      return date.formatted(date: .omitted, time: .shortened)
    } else {
      return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
  }
}

struct DriftWidget: Widget {
  nonisolated static let kind = "DriftWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: ACProvider()) { entry in
      DriftWidgetView(entry: entry)
        .containerBackground(for: .widget) {
          if let accent = WidgetPalette(entry: entry).accent {
            accent
          } else {
            Rectangle().fill(.fill.tertiary)
          }
        }
        .widgetURL(URL(string: "drift://open"))  // tap opens the app
    }
    .configurationDisplayName("Drift")
    .description("See and change your AC's power, temperature, and mode.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

@main
struct DriftWidgetBundle: WidgetBundle {
  var body: some Widget {
    DriftWidget()
  }
}
