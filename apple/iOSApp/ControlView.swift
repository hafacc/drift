import MideaKit
import SwiftUI

/// The set-up AC's controls, polling it while the app is in the foreground.
struct ControlView: View {
  @Environment(DeviceStore.self) private var store
  @Environment(\.scenePhase) private var scenePhase
  @State private var nickname = ""
  @State private var renaming = false
  @State private var confirmingForget = false
  @State private var showingPrivacy = false
  @State private var showingFilterHelp = false

  private let modes: [OperationalMode] = [.auto, .cool, .dry, .fanOnly]

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          if let notice = connectionNotice, store.snapshot != nil {
            Label(notice, systemImage: "wifi.slash")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(.fill.tertiary, in: Capsule())
          }

          if let snapshot = store.displayed {
            controls(snapshot)
          } else {
            noReading
          }

          if !store.status.isEmpty {
            Text(store.status)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }

          // Shown without a reading too, so an AC that won't come back can be forgotten.
          deviceOptions
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .animation(.easeInOut(duration: 0.3), value: store.displayed?.accent)
      }
      .background(Color(.systemGroupedBackground))
      .refreshable { await store.refreshNow() }
      .navigationTitle(store.deviceName)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          powerButton
        }
      }
      .alert("Rename", isPresented: $renaming) {
        TextField(store.discoveredName, text: $nickname)
        Button("Rename") {
          store.setNickname(nickname)
          store.commitNickname()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Leave empty to use the name the AC reports.")
      }
      .sheet(isPresented: $showingPrivacy) { PrivacySheet() }
      .alert("Clearing the filter alert", isPresented: $showingFilterHelp) {
        Button("OK") {}
      } message: {
        Text(FilterResetGuide.instructions)
      }
    }
    .onAppear {
      if scenePhase != .background { store.startPolling() }
    }
    .onDisappear { store.stopPolling() }
    .onChange(of: scenePhase) { _, phase in
      // The AC allows one connection, so it's released for the widgets while in the background.
      switch phase {
      case .background: store.stopPollingForBackground()
      case .active: store.startPolling()
      default: break
      }
    }
  }

  private var connectionNotice: String? {
    switch store.connection {
    case .disconnected: "Not connected — showing last reading"
    case .noLocalNetwork: "No Wi-Fi — showing last reading"
    case .connecting, .connected: nil
    }
  }

  @ViewBuilder
  private var powerButton: some View {
    let powerOn = store.displayed?.powerOn ?? false
    let button = Button {
      store.setPower(!powerOn)
    } label: {
      Label(powerOn ? "On" : "Off", systemImage: "power")
        .labelStyle(.titleAndIcon)
        .fontWeight(.semibold)
    }
    .disabled(store.displayed == nil)
    .accessibilityLabel(powerOn ? "Turn off" : "Turn on")
    if powerOn {
      button
        .buttonStyle(.glassProminent)
        .tint(store.displayed?.accent)
    } else {
      button
    }
  }

  @ViewBuilder
  private func controls(_ snapshot: Snapshot) -> some View {
    let accent = snapshot.accent ?? .gray
    let fanOnly = snapshot.mode == .fanOnly
    TemperatureDial(
      target: store.displayedTarget ?? snapshot.targetTemperature,
      indoor: snapshot.indoorTemperature,
      outdoor: snapshot.outdoorTemperature,
      range: store.temperatureRange,
      accent: accent,
      label: dialLabel(snapshot),
      setTarget: { store.setTemperature($0) },
      step: { store.adjustTemperature($0) }
    )
    .disabled(!snapshot.powerOn || fanOnly)
    .opacity(!snapshot.powerOn || fanOnly ? 0.4 : 1)

    modeTiles(snapshot, accent: accent)

    FanSpeedControl(fanSpeed: snapshot.fanSpeed, accent: accent) { fan in
      store.apply { $0.fanSpeed = fan }
    }
    .disabled(!snapshot.powerOn)
    .opacity(snapshot.powerOn ? 1 : 0.4)

    extras(snapshot, accent: accent)

    if snapshot.filterAlert {
      filterCard
    }
  }

  private func dialLabel(_ snapshot: Snapshot) -> String {
    guard snapshot.powerOn else { return "TARGET" }
    switch snapshot.mode {
    case .cool: return "COOLING TO"
    case .heat: return "HEATING TO"
    case .fanOnly: return "FAN ONLY"
    default: return "TARGET"
    }
  }

  /// Auto, Cool, Dry and Fan; picking one also turns the AC on.
  private func modeTiles(_ snapshot: Snapshot, accent: Color) -> some View {
    HStack(spacing: 8) {
      ForEach(modes, id: \.rawValue) { mode in
        let selected = snapshot.mode == mode
        Button {
          store.setMode(mode)
        } label: {
          VStack(spacing: 4) {
            Image(systemName: mode.symbol)
              .font(.title3)
            Text(mode.display.capitalized)
              .font(.footnote)
              .fontWeight(selected ? .semibold : .medium)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }
          .frame(maxWidth: .infinity, minHeight: 64)
          .foregroundStyle(tileForeground(selected: selected, powerOn: snapshot.powerOn))
          .background(
            tileBackground(selected: selected, powerOn: snapshot.powerOn, accent: accent),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
          )
          .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
  }

  private func tileForeground(selected: Bool, powerOn: Bool) -> AnyShapeStyle {
    if selected && powerOn {
      AnyShapeStyle(.white)
    } else if selected {
      AnyShapeStyle(.primary)
    } else {
      AnyShapeStyle(.secondary)
    }
  }

  private func tileBackground(selected: Bool, powerOn: Bool, accent: Color) -> AnyShapeStyle {
    if selected && powerOn {
      AnyShapeStyle(accent)
    } else if selected {
      AnyShapeStyle(Color(.systemGray4))
    } else {
      AnyShapeStyle(Color(.secondarySystemGroupedBackground))
    }
  }

  /// Eco, Turbo, Swing and Light. Eco and Turbo drive the compressor, so Fan only has neither.
  private func extras(_ snapshot: Snapshot, accent: Color) -> some View {
    let compressorAvailable = snapshot.powerOn && snapshot.mode != .fanOnly
    let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    return LazyVGrid(columns: columns, spacing: 8) {
      ExtraToggle(
        title: "Eco", symbol: "leaf", isOn: snapshot.eco, accent: accent,
        available: compressorAvailable
      ) { value in store.apply { $0.eco = value } }
      ExtraToggle(
        title: "Turbo", symbol: "bolt", isOn: snapshot.turbo, accent: accent,
        available: compressorAvailable
      ) { value in store.apply { $0.turbo = value } }
      ExtraToggle(
        title: "Swing", symbol: "arrow.up.and.down", isOn: snapshot.swingOn, accent: accent,
        available: snapshot.powerOn
      ) { value in store.apply { $0.swingMode = value ? .vertical : .off } }
      ExtraToggle(
        title: "Light", symbol: "lightbulb", isOn: snapshot.displayOn, accent: accent,
        available: snapshot.powerOn
      ) { _ in store.toggleDisplay() }
    }
    .disabled(store.busy)
  }

  private var filterCard: some View {
    HStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.orange)
      Text("Filter needs cleaning")
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("How To") { showingFilterHelp = true }
        .fontWeight(.semibold)
    }
    .font(.subheadline)
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  /// A spinner while connecting, otherwise why there's no reading.
  @ViewBuilder
  private var noReading: some View {
    Group {
      switch store.connection {
      case .disconnected:
        ContentUnavailableView("Not Connected", systemImage: "wifi.slash")
      case .noLocalNetwork:
        ContentUnavailableView("No Wi-Fi", systemImage: "wifi.slash")
      case .connecting, .connected:
        ProgressView()
      }
    }
    .frame(maxWidth: .infinity, minHeight: 360)
  }

  /// Whether the AC beeps at each command, renaming it, the privacy policy, and forgetting it.
  private var deviceOptions: some View {
    VStack(spacing: 0) {
      Toggle("Beep", isOn: Binding(get: { store.beepEnabled }, set: { store.setBeep($0) }))
        .tint(store.displayed?.accent ?? .gray)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
      Divider()
        .padding(.leading, 16)
      optionRow("Rename") {
        nickname = store.currentNickname
        renaming = true
      }
      Divider()
        .padding(.leading, 16)
      optionRow("Privacy") { showingPrivacy = true }
      Divider()
        .padding(.leading, 16)
      optionRow("Forget This AC", role: .destructive) { confirmingForget = true }
        .foregroundStyle(.red)
        // Attached here so the popup points at this row, not the screen's top.
        .confirmationDialog(
          "Forget this AC?", isPresented: $confirmingForget, titleVisibility: .visible
        ) {
          Button("Forget This AC", role: .destructive) { store.forget() }
        } message: {
          Text("Drift deletes its key. Setting it up again needs your Midea account.")
        }
    }
    .background(
      Color(.secondarySystemGroupedBackground),
      in: RoundedRectangle(cornerRadius: 26, style: .continuous)
    )
    .padding(.top, 8)
  }

  /// A full-width row button, tappable anywhere across the card.
  private func optionRow(
    _ title: String, role: ButtonRole? = nil, action: @escaping () -> Void
  ) -> some View {
    Button(role: role, action: action) {
      Text(title)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// A grid tile that switches one of the AC's extras; its icon stays grey either way.
private struct ExtraToggle: View {
  let title: String
  let symbol: String
  let isOn: Bool
  let accent: Color
  // Whether the extra applies right now; dimmed and disabled when not.
  let available: Bool
  let set: (Bool) -> Void

  var body: some View {
    Button {
      set(!isOn)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.title3)
          .foregroundStyle(.secondary)
          .frame(minWidth: 24)
        Text(title)
          .fontWeight(isOn ? .semibold : .regular)
          .foregroundStyle(isOn ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 14)
      .frame(minHeight: 52)
      .background(
        isOn
          ? AnyShapeStyle(accent.opacity(0.15))
          : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(!available)
    .opacity(available ? 1 : 0.4)
    .accessibilityAddTraits(isOn ? .isSelected : [])
    .accessibilityValue(isOn ? "On" : "Off")
  }
}
