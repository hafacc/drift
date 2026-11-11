import MideaKit
import SwiftUI

struct ContentView: View {
  @Environment(DeviceStore.self) private var store
  @State private var nickname = ""
  @State private var renaming = false
  @State private var showingFilterHelp = false
  @State private var confirmingForget = false
  @State private var showingPrivacy = false

  private let modes: [OperationalMode] = [.auto, .cool, .dry, .fanOnly]
  private let windowWidth: CGFloat = 360

  var body: some View {
    Group {
      if store.needsSetup {
        setupView
      } else {
        controlView
      }
    }
    .sheet(isPresented: $showingPrivacy) {
      VStack(alignment: .trailing, spacing: 20) {
        PrivacyPolicyView()
        Button("Done") { showingPrivacy = false }
          .keyboardShortcut(.defaultAction)
      }
      .padding(24)
      .frame(width: 420)
    }
  }

  private var privacyButton: some View {
    Button("Privacy") { showingPrivacy = true }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .font(.caption)
  }

  private var setupView: some View {
    VStack(spacing: 16) {
      Image(systemName: "wind")
        .font(.system(size: 40))
        .foregroundStyle(.secondary)
      Text("Set up your AC")
        .font(.headline)
      Text(setupSubtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      accountFields
        .disabled(store.setupPhase.isRunning)
      setupStatus
      privacyButton
    }
    .padding(28)
    .frame(width: windowWidth)
    .navigationTitle("Drift")
    .onAppear { store.resumeSetup() }
    .onDisappear { store.pauseSetup() }
  }

  private var setupSubtitle: String {
    "Drift finds it on your network, then signs in to your Midea account once to get its key. It doesn't keep your password."
  }

  /// Progress while a step runs or a retry waits, what last failed, and the button to go on.
  @ViewBuilder
  private var setupStatus: some View {
    if let failure = store.setupPhase.failure {
      VStack(spacing: 4) {
        Text(failure.message)
          .font(.caption)
          .fontWeight(.semibold)
        if !failure.hint.isEmpty {
          Text(failure.hint)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
    }
    switch store.setupPhase {
    case .running(let step):
      // Shown in place of the button rather than relabeling it, which keeps its old shape.
      setupProgress(step.message)
    case .waiting(_, let retryDate, let step):
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let seconds = Int(retryDate.timeIntervalSince(context.date).rounded(.up))
        setupProgress(step.retryMessage(in: seconds))
      }
    case .idle, .failed:
      Button("Set Up") { store.setup() }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!store.cloudAccount.isComplete)
    }
  }

  private func setupProgress(_ message: String) -> some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(minHeight: 32)
  }

  private var accountFields: some View {
    @Bindable var store = store
    return VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Midea account email")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("Email", text: $store.cloudAccount.email, prompt: Text("you@example.com"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Password")
          .font(.caption)
          .foregroundStyle(.secondary)
        SecureField("Password", text: $store.cloudAccount.password)
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
      }
    }
  }

  private var controlView: some View {
    VStack(spacing: 18) {
      if let notice = connectionNotice, store.snapshot != nil {
        Label(notice, systemImage: "wifi.slash")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(.fill.tertiary, in: Capsule())
      }

      if let snapshot = store.displayed {
        TemperatureDial(
          target: store.displayedTarget ?? snapshot.targetTemperature,
          indoor: snapshot.indoorTemperature,
          range: store.temperatureRange,
          accent: accent(snapshot),
          label: dialLabel(snapshot),
          setTarget: { store.setTemperature($0) },
          step: { store.adjustTemperature($0) }
        )
        .disabled(!snapshot.powerOn || fanOnly(snapshot))
        .opacity(!snapshot.powerOn || fanOnly(snapshot) ? 0.4 : 1)

        modePicker(snapshot)
        FanSpeedControl(fanSpeed: snapshot.fanSpeed, accent: accent(snapshot)) { fan in
          store.apply { $0.fanSpeed = fan }
        }
        .disabled(!snapshot.powerOn)
        .opacity(snapshot.powerOn ? 1 : 0.4)
        extras(snapshot)
        footer(snapshot)
      } else if store.connection == .disconnected || store.connection == .noLocalNetwork {
        VStack(spacing: 8) {
          Image(systemName: "wifi.slash")
            .font(.system(size: 28))
          Text(connectionNotice ?? "")
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 320)
      } else {
        ProgressView().frame(maxWidth: .infinity, minHeight: 320)
      }

      if !store.status.isEmpty {
        Text(store.status)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      // Shown without a reading too, so a device that won't come back can be forgotten and
      // set up again.
      deviceOptions
    }
    .padding(.horizontal, 20)
    .padding(.top, 4)
    .padding(.bottom, 16)
    .frame(width: windowWidth)
    .animation(.easeInOut(duration: 0.3), value: store.displayed?.accent)
    .onAppear { store.startPolling() }
    .onDisappear { store.stopPolling() }
    .navigationTitle(store.deviceName)
    // The system title can't truncate, so in this narrow window it pushed the toolbar
    // buttons into the system's overflow menu; show the name as an item that can.
    .toolbar(removing: .title)
    .toolbar {
      ToolbarItem(placement: .navigation) {
        nameButton
      }
      .sharedBackgroundVisibility(.hidden)
      ToolbarSpacer(.flexible)
      ToolbarItemGroup(placement: .primaryAction) {
        Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }
          .keyboardShortcut("r")
          .disabled(store.busy)
          .help("Refresh")
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
      Text("Leave empty to use the name the unit reports.")
    }
  }

  private var connectionNotice: String? {
    switch store.connection {
    case .disconnected: return "Not connected — showing last reading"
    case .noLocalNetwork: return "Not on a local network — showing last reading"
    case .connecting, .connected: return nil
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
    .buttonBorderShape(.capsule)
    .disabled(store.displayed == nil)
    .help(powerOn ? "Turn off" : "Turn on")
    if powerOn {
      button
        .buttonStyle(.borderedProminent)
        .tint(store.displayed?.accent)
    } else {
      button.buttonStyle(.bordered)
    }
  }

  /// The device's name, which opens Rename when clicked.
  private var nameButton: some View {
    Button {
      nickname = store.currentNickname
      renaming = true
    } label: {
      Text(store.deviceName)
        .font(.headline)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: 150, alignment: .leading)
    }
    .buttonStyle(.plain)
    .help("Rename \(store.deviceName)")
    .accessibilityHint("Rename")
  }

  /// Whether the AC beeps at each command, forgetting the device, and the privacy policy.
  private var deviceOptions: some View {
    VStack(spacing: 12) {
      Divider()
      Toggle(isOn: Binding(get: { store.beepEnabled }, set: { store.setBeep($0) })) {
        Label("Beep", systemImage: "speaker.wave.2")
      }
      .toggleStyle(CapsuleToggleStyle(tint: store.displayed.map(accent) ?? .gray))
      Button("Forget This Device", role: .destructive) { confirmingForget = true }
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
        .confirmationDialog(
          "Forget this device?", isPresented: $confirmingForget, titleVisibility: .visible
        ) {
          Button("Forget", role: .destructive) { store.forget() }
        } message: {
          Text("Drift deletes its key. Setting it up again needs your Midea account.")
        }
      privacyButton
    }
  }

  /// The mode colour, or a neutral grey while the unit is off.
  private func accent(_ snapshot: Snapshot) -> Color {
    snapshot.accent ?? .gray
  }

  /// Fan-only mode regulates no temperature, so the setpoint and
  /// compressor-based modes (Eco/Turbo) don't apply.
  private func fanOnly(_ snapshot: Snapshot) -> Bool {
    snapshot.mode == .fanOnly
  }

  private func dialLabel(_ snapshot: Snapshot) -> String {
    guard snapshot.powerOn else { return "OFF" }
    switch snapshot.mode {
    case .cool: return "COOLING TO"
    case .heat: return "HEATING TO"
    case .fanOnly: return "FAN ONLY"
    default: return "TARGET"
    }
  }

  private func modePicker(_ snapshot: Snapshot) -> some View {
    HStack(spacing: 8) {
      ForEach(modes, id: \.rawValue) { mode in
        let selected = snapshot.mode == mode
        Button {
          store.setMode(mode)
        } label: {
          VStack(spacing: 4) {
            Image(systemName: mode.symbol)
              .font(.system(size: 18))
              .frame(height: 22)
            Text(mode.display.capitalized)
              .font(.caption)
              .fontWeight(selected ? .semibold : .medium)
          }
          .frame(maxWidth: .infinity, minHeight: 60)
          .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
          .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(selected ? AnyShapeStyle(accent(snapshot)) : AnyShapeStyle(.fill.tertiary))
          }
          .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
  }

  private func extras(_ snapshot: Snapshot) -> some View {
    let style = CapsuleToggleStyle(tint: accent(snapshot))
    return HStack(spacing: 6) {
      // Eco and Turbo drive the compressor — inert in Fan-only mode.
      Toggle(isOn: Binding(get: { snapshot.eco }, set: { value in store.apply { $0.eco = value } }))
      {
        Label("Eco", systemImage: "leaf")
      }
      .disabled(store.busy || !snapshot.powerOn || fanOnly(snapshot))
      Toggle(
        isOn: Binding(get: { snapshot.turbo }, set: { value in store.apply { $0.turbo = value } })
      ) {
        Label("Turbo", systemImage: "bolt")
      }
      .disabled(store.busy || !snapshot.powerOn || fanOnly(snapshot))
      Toggle(
        isOn: Binding(
          get: { snapshot.swingOn },
          set: { value in store.apply { $0.swingMode = value ? .vertical : .off } })
      ) {
        Label("Swing", systemImage: "arrow.up.and.down")
      }
      .disabled(store.busy || !snapshot.powerOn)
      Toggle(isOn: Binding(get: { snapshot.displayOn }, set: { _ in store.toggleDisplay() })) {
        Label("Light", systemImage: "lightbulb")
      }
      .disabled(store.busy || !snapshot.powerOn)
    }
    .toggleStyle(style)
  }

  private func footer(_ snapshot: Snapshot) -> some View {
    VStack(spacing: 12) {
      Divider()
      HStack {
        if let outdoor = snapshot.outdoorTemperature {
          Label("\(Int(outdoor.rounded()))° outside", systemImage: "sun.max")
        }
        Spacer()
        if snapshot.filterAlert {
          Button {
            showingFilterHelp = true
          } label: {
            Label("Clean filter", systemImage: "exclamationmark.triangle")
              .fontWeight(.semibold)
              .foregroundStyle(.orange)
              .padding(.horizontal, 10)
              .padding(.vertical, 4)
              .background(.orange.opacity(0.15), in: Capsule())
          }
          .buttonStyle(.plain)
          .popover(isPresented: $showingFilterHelp, arrowEdge: .bottom) {
            filterHelpContent
          }
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var filterHelpContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Clearing the filter alert")
        .font(.headline)
      Text(FilterResetGuide.instructions)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding()
    .frame(width: 260)
  }
}

/// A 270° arc, open at the bottom, over the selectable setpoint range. Dragging along the
/// arc picks a whole degree; the − / + buttons sit on the arc's two ends.
private struct TemperatureDial: View {
  let target: Double
  let indoor: Double?
  let range: ClosedRange<Double>
  let accent: Color
  let label: String
  let setTarget: (Double) -> Void
  let step: (Double) -> Void

  private let side: CGFloat = 240
  private let radius: CGFloat = 100
  private let lineWidth: CGFloat = 14
  private let startDegrees: Double = 135
  private let sweepDegrees: Double = 270
  // Cuts the square frame just below the step buttons, which hang under the arc's ends.
  private let height: CGFloat = 216

  var body: some View {
    ZStack(alignment: .top) {
      arc
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .gesture(dragGesture)

      VStack(spacing: 0) {
        Text(label)
          .font(.caption)
          .fontWeight(.semibold)
          .tracking(0.7)
          .foregroundStyle(accent)
        Text("\(Int(target.rounded()))°")
          .font(.system(size: 68, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .contentTransition(.numericText(value: target))
        if let indoor {
          Text("Room is \(Int(indoor.rounded()))°")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.top, 58)
      .allowsHitTesting(false)

      stepButton("minus", label: "Colder", delta: -1, fraction: 0)
      stepButton("plus", label: "Warmer", delta: 1, fraction: 1)
    }
    .frame(width: side, height: height, alignment: .top)
    .animation(.snappy(duration: 0.2), value: target)
    .accessibilityRepresentation {
      Stepper {
        Text("Target temperature")
      } onIncrement: {
        step(1)
      } onDecrement: {
        step(-1)
      }
      .accessibilityValue("\(Int(target.rounded()))°")
    }
  }

  private var arc: some View {
    ZStack {
      track(to: 1).stroke(.fill.secondary, style: stroke)
        .frame(width: radius * 2, height: radius * 2)
      track(to: fraction(of: target)).stroke(accent, style: stroke)
        .frame(width: radius * 2, height: radius * 2)
      if let indoor {
        Circle()
          .fill(.primary)
          .frame(width: 6, height: 6)
          .position(point(at: fraction(of: indoor)))
      }
      Circle()
        .fill(.white)
        .strokeBorder(accent, lineWidth: 3)
        .frame(width: 22, height: 22)
        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
        .position(point(at: fraction(of: target)))
    }
  }

  private func track(to fraction: Double) -> some Shape {
    Circle()
      .trim(from: 0, to: sweepDegrees / 360 * fraction)
      .rotation(.degrees(startDegrees))
  }

  private var stroke: StrokeStyle { StrokeStyle(lineWidth: lineWidth, lineCap: .round) }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        let center = CGPoint(x: side / 2, y: side / 2)
        // Only drags that start on the ring count, so a click in the middle does nothing.
        let startDistance = hypot(
          value.startLocation.x - center.x, value.startLocation.y - center.y)
        guard abs(startDistance - radius) <= lineWidth * 2 else { return }
        let degrees = atan2(value.location.y - center.y, value.location.x - center.x) * 180 / .pi
        var along = (degrees - startDegrees).truncatingRemainder(dividingBy: 360)
        if along < 0 { along += 360 }
        if along > sweepDegrees {
          // In the gap at the bottom: pin to whichever end is nearer.
          along = along < (sweepDegrees + 360) / 2 ? sweepDegrees : 0
        }
        let span = range.upperBound - range.lowerBound
        let requested = (range.lowerBound + along / sweepDegrees * span).rounded()
        if requested != target.rounded() { setTarget(requested) }
      }
  }

  private func fraction(of temperature: Double) -> Double {
    let span = range.upperBound - range.lowerBound
    return min(1, max(0, (temperature - range.lowerBound) / span))
  }

  private func point(at fraction: Double) -> CGPoint {
    let radians = (startDegrees + sweepDegrees * fraction) * .pi / 180
    return CGPoint(x: side / 2 + radius * cos(radians), y: side / 2 + radius * sin(radians))
  }

  private func stepButton(_ symbol: String, label: String, delta: Double, fraction: Double)
    -> some View
  {
    Button {
      step(delta)
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 16, weight: .medium))
        .accessibilityLabel(label)
    }
    .buttonStyle(DialStepButtonStyle())
    .position(point(at: fraction))
    .frame(width: side, height: side)
  }
}

/// A round 44pt button ringed with the window background, so it sits cleanly on the arc.
private struct DialStepButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.primary)
      .frame(width: 44, height: 44)
      .background {
        Circle()
          .fill(Color(nsColor: .controlBackgroundColor))
          .overlay(Circle().fill(.primary.opacity(configuration.isPressed ? 0.12 : 0)))
          .overlay(Circle().strokeBorder(.separator))
      }
      .background {
        Circle()
          .fill(Color(nsColor: .windowBackgroundColor))
          .padding(-5)
      }
      .contentShape(Circle())
      .opacity(isEnabled ? 1 : 0.5)
  }
}

/// Discrete fan speeds on a bar, plus a separate Auto that leaves the bar unselected.
private struct FanSpeedControl: View {
  let fanSpeed: FanSpeed
  let accent: Color
  let select: (FanSpeed) -> Void

  @State private var draggedIndex: Int?

  private let speeds: [FanSpeed] = [.silent, .low, .medium, .high, .max]
  private let barHeight: CGFloat = 12

  private var isAuto: Bool { fanSpeed == .auto }
  private var shownIndex: Int? {
    draggedIndex ?? speeds.firstIndex(of: fanSpeed)
  }
  private var valueName: String {
    if let shownIndex {
      return speeds[shownIndex].display.capitalized
    } else {
      return FanSpeed.allCases.contains(fanSpeed) ? fanSpeed.display.capitalized : "—"
    }
  }

  var body: some View {
    VStack(spacing: 8) {
      HStack {
        Text("Fan speed").foregroundStyle(.secondary)
        Spacer()
        Text(valueName).fontWeight(.semibold)
      }
      .font(.caption)

      HStack(spacing: 10) {
        bar
          .frame(height: 32)
          .accessibilityElement()
          .accessibilityLabel("Fan speed")
          .accessibilityValue(valueName)
          .accessibilityAdjustableAction { direction in
            let current = shownIndex ?? (direction == .increment ? -1 : speeds.count)
            let next = direction == .increment ? current + 1 : current - 1
            if speeds.indices.contains(next) { select(speeds[next]) }
          }
        autoButton
      }
    }
  }

  private var bar: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let handleX = shownIndex.map { index in
        min(width - 1.5, max(1.5, width * CGFloat(index) / CGFloat(speeds.count - 1)))
      }
      ZStack(alignment: .leading) {
        Capsule()
          .fill(.fill.secondary)
          .frame(height: barHeight)
        if let handleX {
          Capsule()
            .fill(accent)
            .frame(width: max(barHeight, handleX), height: barHeight)
          RoundedRectangle(cornerRadius: 1.5)
            .fill(accent)
            .frame(width: 3, height: 28)
            .background {
              RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: .windowBackgroundColor))
                .padding(.horizontal, -3)
            }
            .position(x: handleX, y: geometry.size.height / 2)
        }
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in draggedIndex = index(at: value.location.x, width: width) }
          .onEnded { value in
            let chosen = speeds[index(at: value.location.x, width: width)]
            draggedIndex = nil
            if chosen != fanSpeed { select(chosen) }
          }
      )
    }
  }

  @ViewBuilder
  private var autoButton: some View {
    let button = Button("Auto") { select(.auto) }
    if isAuto {
      button.buttonStyle(.borderedProminent).tint(accent)
    } else {
      button.buttonStyle(.bordered)
    }
  }

  private func index(at location: CGFloat, width: CGFloat) -> Int {
    let position = (location / max(width, 1) * CGFloat(speeds.count - 1)).rounded()
    return Int(min(CGFloat(speeds.count - 1), max(0, position)))
  }
}

/// A capsule button that toggles, tinted when on.
private struct CapsuleToggleStyle: ToggleStyle {
  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    CapsuleToggle(configuration: configuration, tint: tint)
  }
}

private struct CapsuleToggle: View {
  let configuration: ToggleStyleConfiguration
  let tint: Color

  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    let isOn = configuration.isOn
    Button {
      configuration.isOn.toggle()
    } label: {
      configuration.label
        .labelStyle(CompactLabelStyle())
        .font(.caption)
        .fontWeight(isOn ? .semibold : .regular)
        .lineLimit(1)
        .foregroundStyle(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
        .frame(maxWidth: .infinity, minHeight: 32)
        .background {
          Capsule()
            .fill(
              isOn
                ? AnyShapeStyle(tint.opacity(0.15))
                : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
        }
        .overlay {
          Capsule().strokeBorder(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.separator))
        }
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .opacity(isEnabled ? 1 : 0.45)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

private struct CompactLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.icon
      configuration.title
    }
  }
}
