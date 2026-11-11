import Foundation
import MideaKit
import Network
import OSLog
import Observation
import Security
import Synchronization

/// Serializes access to the connection: user actions wait their turn; polls skip
/// if something is already running.
private actor Gate {
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func tryEnter() -> Bool {
    if busy { return false }
    busy = true
    return true
  }

  func enter() async {
    if !busy {
      busy = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func leave() {
    if waiters.isEmpty {
      busy = false
    } else {
      waiters.removeFirst().resume()  // hand the turn over; stays busy
    }
  }
}

/// Holds the `MideaClient` so the app can reuse one authenticated connection
/// while the window is open. `DeviceStore`'s `Gate` serializes the callers (one
/// operation at a time, polls skipping when a user action runs), so the client is
/// only ever driven from here, one request at a time.
private actor ClientSession {
  private let client: MideaClient

  init(credentials: DeviceCredentials) {
    client = MideaClient(credentials: credentials)
  }

  func refresh() async throws -> ACState {
    try await client.refresh()
  }

  func apply(beep: Bool, _ change: @Sendable @escaping (inout SetState) -> Void) async throws
    -> ACState
  {
    try await client.apply { [change] set in
      set.beep = beep
      change(&set)
    }
  }

  /// Turn the display to `displayOn`, toggling only when a fresh reading differs and no
  /// earlier try of the same request has toggled, so a repeat can't undo it.
  func setDisplay(_ displayOn: Bool, beep: Bool, toggle: DisplayToggle) async throws -> ACState {
    let reading = try await client.refresh()
    // The AC reports its old state for a poll or two after a toggle, so a repeat that sees
    // the old state mustn't toggle again.
    if reading.displayOn == displayOn || toggle.wasSent {
      return reading
    } else {
      toggle.markSent()
      return try await client.toggleDisplay(beep: beep)
    }
  }

  func disconnect() async {
    await client.disconnect()
  }
}

/// Whether one display request has sent its toggle, shared by every try of that request.
private final class DisplayToggle: Sendable {
  private let sent = Mutex(false)

  /// Whether the toggle has gone out.
  var wasSent: Bool { sent.withLock { $0 } }

  /// Record that the toggle has gone out.
  func markSent() {
    sent.withLock { $0 = true }
  }
}

/// Observable view-model for the app window.
///
/// Holds a persistent `ClientSession` and polls it cheaply (reusing one
/// authenticated connection) while the window is open. Provisions the device on
/// first run, persists it to the shared Keychain, and reloads widget timelines
/// after a change.
@MainActor
@Observable
final class DeviceStore {
  /// Where first-run setup stands.
  enum SetupPhase {
    case idle
    case running(SetupStep)
    /// The last attempt failed; the next one starts on its own at the given time, at the
    /// given step.
    case waiting(SetupFailure, until: Date, retrying: SetupStep)
    /// The last attempt failed and nothing will retry it until the user acts.
    case failed(SetupFailure)

    /// Whether a setup step is in progress.
    var isRunning: Bool {
      if case .running = self { return true } else { return false }
    }

    /// The failure being shown, if any.
    var failure: SetupFailure? {
      switch self {
      case .waiting(let failure, _, _), .failed(let failure): return failure
      case .idle, .running: return nil
      }
    }
  }

  /// Whether we currently have a live connection to the AC.
  enum Connection { case connecting, connected, disconnected, noLocalNetwork }

  /// A change the user just made, shown in place of the device's own reading until the
  /// device reports it back, or until `deadline` — whichever comes first.
  private struct PendingChange {
    var snapshot: Snapshot
    var deadline: Date
  }

  private(set) var snapshot: Snapshot?
  private(set) var status: String = ""
  private(set) var busy = false  // a user action is in flight
  private(set) var needsSetup = false
  private(set) var setupPhase: SetupPhase = .idle {
    didSet { onSetupPhaseChange?(setupPhase) }
  }
  /// Called with each new setup phase as it is set, even ones that pass within one update.
  @ObservationIgnored var onSetupPhaseChange: ((SetupPhase) -> Void)?
  /// The Midea account setup signs in to; never saved, and cleared once setup ends.
  var cloudAccount = CloudAccount()
  private(set) var connection: Connection = .connecting {
    didSet {
      guard connection != oldValue else { return }
      // The widget only greys out a reading on its own schedule while the app isn't
      // keeping it fresh, so it has to re-plan whenever that changes.
      SharedStore.appIsConnected = connection == .connected
      WidgetReload.all()
    }
  }
  private(set) var targetOverride: Double?  // optimistic setpoint while adjusting
  private var pendingChange: PendingChange?
  private(set) var beepEnabled: Bool =
    (UserDefaults.standard.object(forKey: "beepEnabled") as? Bool) ?? true

  private var device: StoredDevice?
  @ObservationIgnored private var session: ClientSession?
  // The reading behind `snapshot`; seeding a `SetState` needs it.
  @ObservationIgnored private var lastState: ACState?
  @ObservationIgnored private let gate = Gate()
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var temperatureTask: Task<Void, Never>?
  @ObservationIgnored private var setupTask: Task<Void, Never>?
  // Whether automatic setup should run while the setup screen shows; false before the
  // first "Set Up", after a failure retrying can't fix, and once set up.
  @ObservationIgnored private var autoSetup = false
  // The AC an earlier setup attempt found, so a retry skips the search.
  @ObservationIgnored private var foundDevice: DiscoveredDevice?
  private let setupEnvironment: SetupEnvironment
  // The AC frees its single connection slot lazily, so retries back off rather than
  // keep it busy; the last pause repeats.
  private let setupRetryDelays: [Duration] = [
    .seconds(5), .seconds(10), .seconds(20), .seconds(30),
  ]
  private let pollSeconds: UInt64 = 5
  // Polls search for the AC at a new address at most this often while it doesn't answer;
  // each search listens for several seconds and holds up user actions meanwhile.
  private let relocateInterval: TimeInterval = 60
  @ObservationIgnored private var lastRelocate: Date?
  // The unit keeps reporting its pre-change state for a moment — sometimes a poll or two —
  // after a command, so a pending change outlives readings that disagree with it. Only this
  // long, though: past that the change didn't stick, and the truth beats a stale promise.
  private let settleSeconds: TimeInterval = 10
  // The AC is only reachable over the local network (Wi-Fi or Ethernet), so a reach
  // attempted without one can't land — tracked here so polls and user actions can report
  // that distinctly (and skip the doomed attempt) rather than as a generic "not connected".
  // Optimistic default: assume the network is up until the monitor's first callback says
  // otherwise, so launch doesn't flash a false "not on a local network".
  @ObservationIgnored private var localNetworkAvailable = true
  // The AC serves one client at a time and occasionally drops one; MideaKit reconnects
  // on the next call, so a single failure isn't worth showing as "not connected".
  @ObservationIgnored private var consecutiveFailures = 0
  private let localNetworkMonitor = NWPathMonitor()
  // Selectable setpoint range. The floor matches MideaKit's own clamp (SetState sends
  // min(max(target, 17), 30)); offering 16 in the UI only for the device to snap back
  // to 17 is a lie, so the ends are kept in agreement here.
  let temperatureRange: ClosedRange<Double> = 17...30

  var deviceName: String { device?.displayName ?? "AC" }
  var discoveredName: String { device?.credentials.name ?? "" }
  var serialNumber: String? { device?.credentials.serialNumber }
  var currentNickname: String { device?.nickname ?? "" }
  var displayedTarget: Double? { targetOverride ?? displayed?.targetTemperature }
  /// What the controls render: a change still settling, otherwise the device's reading.
  var displayed: Snapshot? { pendingChange?.snapshot ?? snapshot }

  /// Load the set-up device, if any, and start watching the local network and widget commands;
  /// setup reaches the network and waits through `setupEnvironment`.
  init(setupEnvironment: SetupEnvironment = .live) {
    self.setupEnvironment = setupEnvironment
    device = SharedStore.loadDevice()
    snapshot = SharedStore.loadSnapshot()
    needsSetup = device == nil
    if let device { session = ClientSession(credentials: device.credentials) }
    localNetworkMonitor.pathUpdateHandler = { [weak self] path in
      // Not the default route's interface: on Wi-Fi without internet, iOS routes the
      // default over cellular while the AC is still reachable on the Wi-Fi.
      let available = path.availableInterfaces.contains { interface in
        interface.type == .wifi || interface.type == .wiredEthernet
      }
      Task { @MainActor in self?.localNetworkAvailable = available }
    }
    localNetworkMonitor.start(queue: DispatchQueue.global(qos: .utility))
    observeWidgetCommands()
  }

  /// The widget can't connect while the app holds the device's only connection, so it
  /// queues its commands in the App Group and posts a Darwin notification; apply them here
  /// through the same optimistic path as the window's own controls.
  private func observeWidgetCommands() {
    guard let name = SharedStore.commandNotificationName else { return }
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
      { _, _, _, _, _ in
        Task { @MainActor in NotificationCenter.default.post(name: .widgetCommand, object: nil) }
      }, name as CFString, nil, .deliverImmediately)
    NotificationCenter.default.addObserver(forName: .widgetCommand, object: nil, queue: .main) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.applyWidgetCommands() }
    }
  }

  private func applyWidgetCommands() {
    let commands = SharedStore.takeCommands()
    Logger(subsystem: "cc.hafa.Drift", category: "app").info(
      "Applying \(commands.count) widget commands")
    for command in commands {
      switch command {
      case .setPower(let powerOn): setPower(powerOn)
      case .setTarget(let target):
        // Stepped from a reading that was on, but the AC has since been turned off here.
        if displayed?.powerOn != false { setTemperature(target) }
      case .setMode(let mode): setMode(OperationalMode(rawValue: mode))
      }
    }
  }

  // MARK: Setup & nickname

  /// Run setup: find the AC, fetch its key with `cloudAccount`, and check it locally,
  /// retrying the step that failed on its own with growing pauses until it succeeds, it
  /// fails in a way retrying can't fix, or the screen goes away.
  func setup() {
    guard needsSetup, cloudAccount.isComplete else { return }
    autoSetup = true
    guard setupTask == nil else { return }
    setupTask = Task { [weak self] in await self?.retrySetup() }
  }

  /// Resume automatic setup when the setup screen shows again.
  func resumeSetup() {
    if autoSetup { setup() }
  }

  /// Pause automatic setup while the setup screen isn't showing.
  func pauseSetup() {
    guard autoSetup else { return }
    cancelSetupTask()
  }

  private func retrySetup() async {
    var failures = 0
    while !Task.isCancelled {
      setupPhase = .running(
        SetupFlow.firstStep(knownDevice: foundDevice))
      do throws(SetupFailure) {
        // Read each attempt, so edits made while a retry waits are used.
        let credentials = try await SetupFlow.run(
          knownDevice: foundDevice, account: cloudAccount, environment: setupEnvironment,
          progress: { [weak self] step in
            if !Task.isCancelled { self?.setupPhase = .running(step) }
          },
          found: { [weak self] device in
            if !Task.isCancelled { self?.foundDevice = device }
          })
        guard !Task.isCancelled else { return }
        finishSetup(credentials)
        return
      } catch {
        guard !Task.isCancelled else { return }
        guard error.retries else {
          autoSetup = false
          setupPhase = .failed(error)
          setupTask = nil
          return
        }
        let delay = setupRetryDelays[min(failures, setupRetryDelays.count - 1)]
        failures += 1
        setupPhase = .waiting(
          error, until: .now + TimeInterval(delay.components.seconds),
          retrying: SetupFlow.firstStep(knownDevice: foundDevice))
        do { try await setupEnvironment.sleep(delay) } catch { return }
      }
    }
  }

  /// Stop any setup attempt or pending retry, leaving its failure on screen.
  private func cancelSetupTask() {
    setupTask?.cancel()
    setupTask = nil
    switch setupPhase {
    case .running: setupPhase = .idle
    case .waiting(let failure, _, _): setupPhase = .failed(failure)
    case .idle, .failed: break
    }
  }

  private func finishSetup(_ credentials: DeviceCredentials) {
    setupTask = nil
    autoSetup = false
    foundDevice = nil
    cloudAccount = CloudAccount()
    let stored = StoredDevice(credentials: credentials, nickname: nil)
    let saveStatus = SharedStore.saveDevice(stored)
    device = stored
    session = ClientSession(credentials: credentials)
    needsSetup = false
    setupPhase = .idle
    // The session works from memory even if the Keychain write failed, but the
    // next launch would silently lose the device and re-run setup — so surface it.
    if saveStatus != errSecSuccess {
      status =
        "Set up, but saving the device failed (Keychain error \(saveStatus)) — you may have to set up again next launch."
    }
    startPolling()
  }

  /// Save the nickname in memory and the Keychain.
  func setNickname(_ nickname: String) {
    guard var device else { return }
    let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    device.nickname = trimmed.isEmpty ? nil : trimmed
    self.device = device
    SharedStore.saveDevice(device)
    if var snapshot {
      snapshot.deviceName = device.displayName
      self.snapshot = snapshot
      SharedStore.saveSnapshot(snapshot)
    }
  }

  /// Push the saved nickname to the widget.
  func commitNickname() {
    WidgetReload.all()
  }

  /// Disconnect and forget the device: delete the stored credentials and return
  /// to setup. Clears the shared snapshot so the widget stops showing a stale
  /// reading too.
  func forget() {
    stopPolling()
    SharedStore.clear()
    device = nil
    session = nil
    snapshot = nil
    lastState = nil
    pendingChange = nil
    targetOverride = nil
    connection = .connecting
    needsSetup = true
    status = ""
    setupTask?.cancel()
    setupTask = nil
    autoSetup = false
    foundDevice = nil
    cloudAccount = CloudAccount()
    setupPhase = .idle
    WidgetReload.all()
  }

  // MARK: Polling & control

  /// Begin cheap periodic polling on the persistent connection.
  func startPolling() {
    guard pollTask == nil, session != nil else { return }
    let seconds = pollSeconds
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.poll()
        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
      }
    }
  }

  /// Stop polling and release the connection when the window isn't visible; the returned
  /// task ends once any running call has finished and the connection is closed.
  @discardableResult
  func stopPolling() -> Task<Void, Never> {
    pollTask?.cancel()
    pollTask = nil
    SharedStore.markAppStopped()
    connection = .connecting
    return Task { [weak self, session, gate] in
      await gate.enter()
      // Polling may have started again while this waited.
      if self?.pollTask == nil { await session?.disconnect() }
      await gate.leave()
    }
  }

  /// Read the AC now, in the background.
  func refresh() {
    runUser(isChange: false) { try await $0.refresh() }
  }

  /// Read the AC now, returning once the reading is in or has failed.
  func refreshNow() async {
    await perform(isChange: false) { try await $0.refresh() }
  }

  func apply(_ change: @escaping @Sendable (inout SetState) -> Void) {
    let beep = beepEnabled
    if let lastState {
      // Predict by running the change over the same seed the command will use.
      var set = SetState(from: lastState)
      change(&set)
      expect { shown in
        shown.powerOn = set.powerOn
        shown.targetTemperature = set.targetTemperature
        shown.mode = set.mode
        shown.fanSpeed = set.fanSpeed
        shown.eco = set.eco
        shown.turbo = set.turbo
        shown.swingOn = set.swingMode != .off
      }
    }
    runUser(isChange: true) { try await $0.apply(beep: beep, change) }
  }

  func setPower(_ powerOn: Bool) {
    apply { $0.powerOn = powerOn }
  }

  func setMode(_ mode: OperationalMode) {
    apply {
      $0.mode = mode
      $0.powerOn = true
    }
  }

  /// Flip the display from the shown reading.
  func toggleDisplay() {
    guard let shown = displayed else { return }
    let displayOn = !shown.displayOn
    let beep = beepEnabled
    expect { $0.displayOn = displayOn }
    let toggle = DisplayToggle()
    runUser(isChange: true) {
      try await $0.setDisplay(displayOn, beep: beep, toggle: toggle)
    }
  }

  func setBeep(_ enabled: Bool) {
    beepEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: "beepEnabled")
  }

  /// Optimistically adjust the setpoint now; send the result after a pause.
  func adjustTemperature(_ delta: Double) {
    guard let current = displayedTarget else { return }
    setTemperature(current + delta)
  }

  /// Optimistically set the setpoint now; send it after a pause, so a drag sends only
  /// where it comes to rest.
  func setTemperature(_ requested: Double) {
    let target = min(temperatureRange.upperBound, max(temperatureRange.lowerBound, requested))
    targetOverride = target
    temperatureTask?.cancel()
    temperatureTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 600_000_000)
      if Task.isCancelled { return }
      await self?.commitTemperature(target)
    }
  }

  private func commitTemperature(_ target: Double) async {
    let beep = beepEnabled
    expect { $0.targetTemperature = target }
    await perform(isChange: true) { session in
      try await session.apply(beep: beep) { set in
        set.targetTemperature = target
      }
    }
    // Only clear if a newer adjustment hasn't superseded this one.
    if targetOverride == target { targetOverride = nil }
  }

  private func poll() async {
    guard let session else { return }
    SharedStore.markAppLive()
    applyWidgetCommands()
    guard localNetworkAvailable else {
      connection = .noLocalNetwork
      return
    }
    guard await gate.tryEnter() else { return }
    defer { Task { await gate.leave() } }
    do {
      let state = try await session.refresh()
      // Nudge the widget when the glanceable state changes so it re-reads the
      // shared snapshot (it can't fetch itself while the app holds the device).
      let changed =
        snapshot?.powerOn != state.powerOn
        || snapshot?.targetTemperature != state.targetTemperature
        || snapshot?.mode != state.mode
        || snapshot?.fanSpeed != state.fanSpeed
      update(state, reloadWidget: changed)
      connection = .connected
      consecutiveFailures = 0
    } catch {
      consecutiveFailures += 1
      // The next poll is the retry; only a second failure in a row means disconnected.
      if consecutiveFailures >= 2 {
        connection = .disconnected
        if lastRelocate.map({ Date().timeIntervalSince($0) >= relocateInterval }) ?? true {
          // The next poll uses the session at the new address.
          _ = await relocate()
        }
      }
    }
    await releaseIfStopped()
  }

  private func runUser(
    isChange: Bool, _ operation: @escaping @Sendable (ClientSession) async throws -> ACState
  ) {
    Task { await perform(isChange: isChange, operation) }
  }

  /// Run `operation`, which must send absolute state so it can be repeated: once more on the
  /// same session, then once at the AC's new address if a search finds it has moved.
  private func perform(
    isChange: Bool, _ operation: @Sendable (ClientSession) async throws -> ACState
  ) async {
    guard session != nil else {
      if isChange { withdrawChange() }
      return
    }
    guard localNetworkAvailable else {
      connection = .noLocalNetwork
      if isChange { withdrawChange() }
      return
    }
    await gate.enter()
    // An address search that ran while this waited may have replaced the session, or the
    // device may have been forgotten.
    guard let session else {
      if isChange { withdrawChange() }
      await gate.leave()
      return
    }
    busy = true
    do {
      let state: ACState
      do {
        state = try await operation(session)
      } catch {
        // MideaKit reconnects lazily, so the call after a dropped connection usually lands.
        do {
          state = try await operation(session)
        } catch {
          guard let moved = await relocate() else { throw error }
          state = try await operation(moved)
        }
      }
      update(state, reloadWidget: isChange)
      status = ""
      connection = .connected
      consecutiveFailures = 0
    } catch {
      consecutiveFailures += 1
      connection = .disconnected
      if isChange { withdrawChange() }
    }
    busy = false
    await releaseIfStopped()
    await gate.leave()
  }

  /// Free the AC's only connection if polling stopped while the caller held the gate, since
  /// `stopPolling` doesn't wait for the gate and the caller may have reconnected after it.
  private func releaseIfStopped() async {
    if pollTask == nil { await session?.disconnect() }
  }

  /// Search the network for the AC by its id after its known address stops answering, and
  /// if it has moved, save the new address and return a session there.
  private func relocate() async -> ClientSession? {
    guard let known = device?.credentials else { return nil }
    lastRelocate = Date()
    guard let found = await DeviceSearch.relocate(known),
      // Forgotten, or set up again, while the search listened.
      var moved = device, moved.credentials.id == known.id
    else { return nil }
    Logger(subsystem: "cc.hafa.Drift", category: "app").info(
      "AC moved to \(found.ip, privacy: .private):\(found.port)")
    moved.credentials = found
    // Saved to the shared Keychain item, so the widget reaches the new address too.
    SharedStore.saveDevice(moved)
    device = moved
    let previous = session
    let relocated = ClientSession(credentials: moved.credentials)
    session = relocated
    await previous?.disconnect()
    return relocated
  }

  /// Show a change at once rather than the reading that predates it, which would otherwise
  /// snap the control back under the user's hand. Layered onto what's displayed now, so a
  /// second change doesn't discard a first one that is still settling.
  private func expect(_ change: (inout Snapshot) -> Void) {
    guard var shown = displayed else { return }
    change(&shown)
    pendingChange = PendingChange(snapshot: shown, deadline: Date() + settleSeconds)
  }

  /// Stop showing a change that didn't reach the AC, here and in the widget.
  private func withdrawChange() {
    pendingChange = nil
    targetOverride = nil
    // The widget saved its own guess at the result when it handed the change over.
    if let snapshot { SharedStore.saveSnapshot(snapshot) }
    WidgetReload.all()
  }

  /// Whether a reading agrees with a pending change on every field the user can set.
  private func settled(_ reading: Snapshot, _ expected: Snapshot) -> Bool {
    reading.powerOn == expected.powerOn
      && reading.targetTemperature == expected.targetTemperature
      && reading.mode == expected.mode
      && reading.fanSpeed == expected.fanSpeed
      && reading.eco == expected.eco
      && reading.turbo == expected.turbo
      && reading.swingOn == expected.swingOn
      && reading.displayOn == expected.displayOn
  }

  private func update(_ state: ACState, reloadWidget: Bool) {
    guard let device else { return }
    lastState = state
    let newSnapshot = Snapshot(state: state, deviceName: device.displayName, updated: Date())
    snapshot = newSnapshot
    if let pendingChange,
      settled(newSnapshot, pendingChange.snapshot) || Date() >= pendingChange.deadline
    {
      self.pendingChange = nil
    }
    SharedStore.saveSnapshot(newSnapshot)
    if reloadWidget {
      WidgetReload.all()
    }
  }
}

extension Notification.Name {
  fileprivate static let widgetCommand = Notification.Name("cc.hafa.Drift.widgetCommand")
}
