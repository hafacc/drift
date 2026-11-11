import Foundation
import MideaKit
import Security

/// Compact, Codable view of the AC for display in the app and the widget.
struct Snapshot: Codable {
  var deviceName: String
  var powerOn: Bool
  var targetTemperature: Double
  var indoorTemperature: Double?
  var outdoorTemperature: Double?
  // Stored as wire values because MideaKit's types aren't Codable; the names match what
  // earlier versions stored, so a saved snapshot still decodes.
  private var modeRaw: UInt8
  private var fanRaw: UInt8
  var eco: Bool
  var turbo: Bool
  var swingOn: Bool
  var displayOn: Bool
  var filterAlert: Bool
  var updated: Date

  /// The operating mode.
  var mode: OperationalMode {
    get { OperationalMode(rawValue: modeRaw) }
    set { modeRaw = newValue.rawValue }
  }

  /// The fan speed.
  var fanSpeed: FanSpeed {
    get { FanSpeed(rawValue: fanRaw) }
    set { fanRaw = newValue.rawValue }
  }

  /// Create a reading from its parts, as previews need.
  init(
    deviceName: String, powerOn: Bool, mode: OperationalMode, targetTemperature: Double,
    indoorTemperature: Double?, outdoorTemperature: Double?, fanSpeed: FanSpeed = .auto,
    updated: Date = Date()
  ) {
    self.deviceName = deviceName
    self.powerOn = powerOn
    self.targetTemperature = targetTemperature
    self.indoorTemperature = indoorTemperature
    self.outdoorTemperature = outdoorTemperature
    self.modeRaw = mode.rawValue
    self.fanRaw = fanSpeed.rawValue
    self.eco = false
    self.turbo = false
    self.swingOn = false
    self.displayOn = true
    self.filterAlert = false
    self.updated = updated
  }

  /// Create a reading from the AC's state.
  init(state: ACState, deviceName: String, updated: Date) {
    self.deviceName = deviceName
    self.powerOn = state.powerOn
    self.targetTemperature = state.targetTemperature
    self.indoorTemperature = state.indoorTemperature
    self.outdoorTemperature = state.outdoorTemperature
    self.modeRaw = state.mode.rawValue
    self.fanRaw = state.fanSpeed.rawValue
    self.eco = state.eco
    self.turbo = state.turbo
    self.swingOn = state.swingMode != .off
    self.displayOn = state.displayOn
    self.filterAlert = state.filterAlert
    self.updated = updated
  }
}

/// Storage facade, split by sensitivity. The set-up device (credentials/nickname)
/// lives in the shared Keychain because the token/key are secrets. The non-secret
/// display snapshot lives in a shared App Group container — the canonical way to
/// pass data app↔widget — so the widget renders the app's latest reading (it
/// usually can't fetch itself while the app holds the device's single connection).
enum SharedStore {
  private static let snapshotKey = "snapshot"
  private static let appLastSeenKey = "appLastSeen"
  private static let commandsKey = "widgetCommands"
  private static let appConnectedKey = "appConnected"
  private static let sendingSinceKey = "widgetSendingSince"
  private static let fetchingSinceKey = "widgetFetchingSince"
  // A queued command the app hasn't picked up by then is from a session that died without
  // clearing its heartbeat; replaying it on a later launch would surprise the user.
  private static let commandLifetime: TimeInterval = 30

  /// App Group `UserDefaults`, keyed by the group ID in the app's and widget's entitlements.
  private static var groupDefaults: UserDefaults {
    if let id = appGroupID, let defaults = UserDefaults(suiteName: id) {
      return defaults
    }
    return .standard
  }

  /// The App Group: `group.`-prefixed on iOS, which allows no other form, and
  /// Team-ID-prefixed on macOS, which needs no provisioning profile for it.
  private static var appGroupID: String? {
    #if os(iOS)
      "group.cc.hafa.Drift"
    #else
      Keychain.appGroupID("cc.hafa.Drift")
    #endif
  }

  /// Persist the device, returning the Keychain status (or `errSecParam` if it
  /// couldn't even be encoded) so setup can surface a save failure.
  @discardableResult
  static func saveDevice(_ device: StoredDevice) -> OSStatus {
    guard let data = try? JSONEncoder().encode(device) else { return errSecParam }
    return Keychain.save(data)
  }

  static func loadDevice() -> StoredDevice? {
    guard let data = Keychain.load() else { return nil }
    return try? JSONDecoder().decode(StoredDevice.self, from: data)
  }

  static func saveSnapshot(_ snapshot: Snapshot) {
    if let data = try? JSONEncoder().encode(snapshot) {
      groupDefaults.set(data, forKey: snapshotKey)
    }
  }

  static func loadSnapshot() -> Snapshot? {
    guard let data = groupDefaults.data(forKey: snapshotKey) else { return nil }
    return try? JSONDecoder().decode(Snapshot.self, from: data)
  }

  /// Forget the set-up device: drop its credentials and the shared snapshot so
  /// neither the app nor the widget shows a stale reading after disconnecting.
  static func clear() {
    Keychain.delete()
    groupDefaults.removeObject(forKey: snapshotKey)
    groupDefaults.removeObject(forKey: commandsKey)
    markAppStopped()
  }

  /// Stamped by the app on every poll tick — successful or not — while it holds the
  /// device's single connection, so the widget knows to hand commands to it instead of
  /// connecting itself. A snapshot's own date can't say this: the widget writes those too.
  static func markAppLive() {
    groupDefaults.set(Date(), forKey: appLastSeenKey)
  }

  static func markAppStopped() {
    groupDefaults.removeObject(forKey: appLastSeenKey)
    groupDefaults.removeObject(forKey: appConnectedKey)
  }

  /// Whether the live app is currently reading the unit, i.e. keeping the snapshot fresh.
  /// Only meaningful while ``appIsLive(within:)``.
  static var appIsConnected: Bool {
    get { groupDefaults.bool(forKey: appConnectedKey) }
    set { groupDefaults.set(newValue, forKey: appConnectedKey) }
  }

  /// When the widget started sending a button press to the AC; nil when it isn't sending.
  static var widgetSendingSince: Date? {
    get { groupDefaults.object(forKey: sendingSinceKey) as? Date }
    set {
      if let newValue {
        groupDefaults.set(newValue, forKey: sendingSinceKey)
      } else {
        groupDefaults.removeObject(forKey: sendingSinceKey)
      }
    }
  }

  /// Whether the widget is sending a button press, started within [interval].
  static func widgetIsSending(within interval: TimeInterval) -> Bool {
    guard let since = widgetSendingSince else { return false }
    return Date().timeIntervalSince(since) < interval
  }

  /// When a widget process started reading the AC; nil when none is.
  static var widgetFetchingSince: Date? {
    get { groupDefaults.object(forKey: fetchingSinceKey) as? Date }
    set {
      if let newValue {
        groupDefaults.set(newValue, forKey: fetchingSinceKey)
      } else {
        groupDefaults.removeObject(forKey: fetchingSinceKey)
      }
    }
  }

  /// Whether a widget process is reading the AC, started within [interval].
  static func widgetIsFetching(within interval: TimeInterval) -> Bool {
    guard let since = widgetFetchingSince else { return false }
    return Date().timeIntervalSince(since) < interval
  }

  /// Whether the app has stamped itself live within [interval].
  static func appIsLive(within interval: TimeInterval) -> Bool {
    guard let lastSeen = groupDefaults.object(forKey: appLastSeenKey) as? Date else {
      return false
    }
    return Date().timeIntervalSince(lastSeen) < interval
  }

  /// Queue a widget command for the running app and wake it with a Darwin notification;
  /// returns the id to check it was taken with.
  @discardableResult
  static func sendToApp(_ command: WidgetCommand) -> UUID {
    let entry = QueuedCommand(id: UUID(), command: command, queued: Date())
    saveCommands(loadCommands() + [entry])
    if let name = commandNotificationName {
      CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil,
        nil, true)
    }
    return entry.id
  }

  /// Whether the command queued as `id` still waits for the app.
  static func isQueued(_ id: UUID) -> Bool {
    loadCommands().contains { $0.id == id }
  }

  /// Take back the command queued as `id`; whether it was still there to take.
  static func withdrawFromApp(_ id: UUID) -> Bool {
    let queued = loadCommands()
    let remaining = queued.filter { $0.id != id }
    guard remaining.count < queued.count else { return false }
    saveCommands(remaining)
    return true
  }

  /// Remove and return the queued widget commands, oldest first, dropping expired ones;
  /// the removal is what tells the widget the app took them.
  static func takeCommands() -> [WidgetCommand] {
    let queued = loadCommands()
    groupDefaults.removeObject(forKey: commandsKey)
    let cutoff = Date() - commandLifetime
    return queued.filter { $0.queued > cutoff }.map(\.command)
  }

  /// Darwin notification posted when a widget command is queued. Prefixed with the App
  /// Group so the sandbox lets both targets post and observe it.
  static var commandNotificationName: String? {
    appGroupID.map { "\($0).widgetCommand" }
  }

  private static func saveCommands(_ commands: [QueuedCommand]) {
    if commands.isEmpty {
      groupDefaults.removeObject(forKey: commandsKey)
    } else if let data = try? JSONEncoder().encode(commands) {
      groupDefaults.set(data, forKey: commandsKey)
    }
  }

  private static func loadCommands() -> [QueuedCommand] {
    guard let data = groupDefaults.data(forKey: commandsKey) else { return [] }
    return (try? JSONDecoder().decode([QueuedCommand].self, from: data)) ?? []
  }
}

/// A change requested from the widget, as absolute values so applying it twice is harmless.
enum WidgetCommand: Codable, Sendable {
  case setPower(Bool)
  case setTarget(Double)
  // The mode's wire value, since OperationalMode isn't Codable.
  case setMode(UInt8)

  func apply(to set: inout SetState) {
    switch self {
    case .setPower(let powerOn):
      set.powerOn = powerOn
    case .setTarget(let target):
      set.targetTemperature = target
    case .setMode(let mode):
      set.mode = OperationalMode(rawValue: mode)
      set.powerOn = true
    }
  }

  func apply(to snapshot: inout Snapshot) {
    switch self {
    case .setPower(let powerOn):
      snapshot.powerOn = powerOn
    case .setTarget(let target):
      snapshot.targetTemperature = target
    case .setMode(let mode):
      snapshot.mode = OperationalMode(rawValue: mode)
      snapshot.powerOn = true
    }
  }
}

private struct QueuedCommand: Codable {
  var id: UUID
  var command: WidgetCommand
  var queued: Date
}
