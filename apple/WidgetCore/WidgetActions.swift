import AppIntents
import MideaKit
import OSLog
import SwiftUI
import WidgetKit

private let widgetLog = Logger(subsystem: "cc.hafa.Drift", category: "widget")

/// What a widget shows at one moment.
struct ACEntry: TimelineEntry {
  let date: Date
  let snapshot: Snapshot?
  // A device is set up, even if we have no reading yet — lets the view tell
  // "not set up" apart from "set up but still connecting".
  let hasDevice: Bool
  // A button press is on its way to the AC, so the buttons are off until it lands.
  var sending = false

  /// Whether the reading is old enough to show greyed out as "last seen".
  var isStale: Bool {
    snapshot.map { date.timeIntervalSince($0.updated) >= ACProvider.staleAfter } ?? false
  }
}

/// Provides timeline entries for the widget. Tries a live local fetch using the
/// shared credentials; on any failure falls back to the last stored snapshot.
@MainActor
struct ACProvider: @MainActor TimelineProvider {
  // The app reuses one warm connection and answers in well under a second; a
  // cold widget fetch (connect + auth + warm-up) can run far longer, and the
  // device's single TCP slot is often held by the open app, so the fetch stalls
  // until its read timeout. WidgetKit kills timeline generation that overruns its
  // budget — which leaves the widget frozen — so bound the whole fetch and fall
  // back to the app's last shared snapshot rather than risk the overrun.
  nonisolated static let fetchBudget: TimeInterval = 8
  // The device serves one TCP client at a time, and the app writes a snapshot after
  // every successful poll (~5s apart) before reloading us. So a stored snapshot
  // younger than this means the app is live on that single slot: our own connection
  // would knock it off, stalling its polls until they time out and it reports the
  // unit as disconnected — for a reading no fresher than the one we already have.
  nonisolated static let liveFetchStaleAfter: TimeInterval = 60
  // Past this a press is taken to have died with the extension, and the buttons come back.
  nonisolated static let sendingTimeout: TimeInterval = fetchBudget + 2
  // A reading older than this is shown greyed out as "last seen".
  nonisolated static let staleAfter: TimeInterval = 600

  func placeholder(in context: Context) -> ACEntry {
    ACEntry(
      date: Date(), snapshot: SharedStore.loadSnapshot(), hasDevice: SharedStore.loadDevice() != nil
    )
  }

  func getSnapshot(in context: Context, completion: @escaping (ACEntry) -> Void) {
    completion(placeholder(in: context))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<ACEntry>) -> Void) {
    // Complete with the cached snapshot immediately — don't await the live fetch
    // first. WidgetKit shows its own redacted "loading" skeleton for however long
    // this completion handler is pending, and macOS suspends the widget extension
    // whenever it's not visible, so every reopen was a cold start that sat on the
    // live fetch (up to fetchBudget) before painting anything. Racing the live
    // fetch in the background and pushing a reload on success keeps that skeleton
    // to a one-off rather than something seen on every open.
    let device = SharedStore.loadDevice()
    let snapshot = SharedStore.loadSnapshot()
    let entry = ACEntry(
      date: Date(), snapshot: snapshot, hasDevice: device != nil,
      sending: SharedStore.widgetIsSending(within: Self.sendingTimeout))
    let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
    var entries = [entry]
    let appIsLive = SharedStore.appIsLive(within: Self.liveFetchStaleAfter)
    // Redraw as greyed-out at the moment the reading goes stale, not at the next refresh.
    // Not while the app is connected: it keeps the snapshot current, but its reloads count
    // against WidgetKit's refresh budget and get dropped once that runs out, so a
    // scheduled grey-out would fire over a reading that is still being refreshed. The
    // app reloads us when it stops or loses the unit, which reschedules this.
    if let snapshot, !(appIsLive && SharedStore.appIsConnected) {
      let staleDate = snapshot.updated + Self.staleAfter
      if staleDate > entry.date, staleDate < nextUpdate {
        entries.append(ACEntry(date: staleDate, snapshot: snapshot, hasDevice: device != nil))
      }
    }
    completion(Timeline(entries: entries, policy: .after(nextUpdate)))

    let snapshotAge = snapshot.map { stored in Date().timeIntervalSince(stored.updated) }
    widgetLog.info(
      "Timeline: device \(device != nil), app live \(appIsLive), snapshot age \(snapshotAge ?? -1, format: .fixed(precision: 0))s"
    )
    guard let device, !appIsLive, (snapshotAge ?? .infinity) >= Self.liveFetchStaleAfter else {
      return
    }
    Task {
      if await Self.fetchLive(device).snapshot != nil {
        WidgetReload.all()
      }
    }
  }

  /// Read the AC within `fetchBudget`, following it to a new address if need be, and save
  /// the reading to the shared store. Callers in this process share one fetch, and another
  /// process's fetch or button press makes this skip.
  nonisolated static func fetchLive(_ device: StoredDevice) async -> LiveFetch {
    await liveFetches.run {
      if SharedStore.widgetIsFetching(within: sendingTimeout)
        || SharedStore.widgetIsSending(within: sendingTimeout)
      {
        widgetLog.info("Fetch skipped: another process is using the AC")
        return .skipped
      }
      let start = Date()
      SharedStore.widgetFetchingSince = start
      defer {
        // A later fetch in another process may have taken the stamp over.
        if SharedStore.widgetFetchingSince == start { SharedStore.widgetFetchingSince = nil }
      }
      do {
        let deadline = start + fetchBudget
        let live = try await withTimeout(seconds: fetchBudget) {
          try await WidgetReach.run(device, deadline: deadline) { credentials in
            try await DeviceService.fetchSnapshot(credentials, displayName: device.displayName)
          }
        }
        widgetLog.info(
          "Fetch succeeded in \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s")
        SharedStore.saveSnapshot(live)
        return .fetched(live)
      } catch {
        widgetLog.error(
          "Fetch failed after \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s: \(String(describing: error), privacy: .public)"
        )
        return .failed
      }
    }
  }

  // Shared by the Home Screen and Lock Screen widgets and the control, which WidgetKit
  // reloads together; the AC serves only one connection at a time.
  private nonisolated static let liveFetches = SingleFlight<LiveFetch>()
}

/// How a live fetch of the AC went.
enum LiveFetch: Sendable {
  /// The AC answered with this reading, now saved.
  case fetched(Snapshot)
  /// The AC didn't answer in time.
  case failed
  /// Another process was using the AC, so this one didn't connect.
  case skipped

  /// The fetched reading, if any.
  var snapshot: Snapshot? {
    if case .fetched(let snapshot) = self { snapshot } else { nil }
  }
}

/// Reaches the AC from the widget, which runs while the app is closed and so must follow the
/// AC to a new address itself.
enum WidgetReach {
  // The longest a search listens; shorter than the app's, to fit the widget's budget.
  private static let searchSeconds: TimeInterval = 2
  // A search shorter than this would likely miss the reply.
  private static let minimumSearchSeconds: TimeInterval = 0.5
  // Time a cold connection at a new address needs; with less left, the found address is
  // only saved, for the next refresh.
  private static let reconnectSeconds: TimeInterval = 2

  /// Run `operation` at the saved address; if that fails and time before `deadline` allows,
  /// search for the AC by its id, save a new address, and run `operation` there.
  static func run<Result: Sendable>(
    _ device: StoredDevice, deadline: Date,
    _ operation: @Sendable (DeviceCredentials) async throws -> Result
  ) async throws -> Result {
    do {
      return try await operation(device.credentials)
    } catch {
      let searchTime = min(searchSeconds, deadline.timeIntervalSinceNow - minimumSearchSeconds)
      guard searchTime >= minimumSearchSeconds,
        let moved = await relocate(device, timeout: searchTime),
        deadline.timeIntervalSinceNow >= reconnectSeconds
      else { throw error }
      return try await operation(moved.credentials)
    }
  }

  /// Search for the AC by its id and, if it answers from a new address, save that address to
  /// the shared Keychain and return the updated device.
  private static func relocate(_ device: StoredDevice, timeout: TimeInterval) async
    -> StoredDevice?
  {
    guard let found = await DeviceSearch.relocate(device.credentials, timeout: timeout),
      // Forgotten, or set up again, while the search listened.
      var moved = SharedStore.loadDevice(), moved.credentials.id == device.credentials.id
    else { return nil }
    widgetLog.info("AC moved to \(found.ip, privacy: .private):\(found.port)")
    moved.credentials = found
    SharedStore.saveDevice(moved)
    return moved
  }
}

/// What a widget button asks for, resolved against the stored snapshot into an absolute
/// `WidgetCommand`.
enum WidgetRequest: Sendable {
  case togglePower
  case setPower(Bool)
  case adjustTemperature(Int)
  case setMode(OperationalMode)
}

/// Carries out a widget button press. The AC serves one TCP client at a time, so while the
/// app is live the widget must not connect — that would knock the app offline. Then the
/// command is handed to the app; otherwise, or if the app doesn't take it, the widget
/// connects and applies it itself.
enum WidgetCommandRunner {
  // Matches the app's selectable setpoint range and MideaKit's own clamp.
  private static let temperatureRange: ClosedRange<Double> = 17...30
  // A live app takes a queued command at once, on the Darwin notification.
  private static let handOffTimeout: TimeInterval = 1.5

  static func run(_ request: WidgetRequest) async {
    if SharedStore.widgetIsSending(within: ACProvider.sendingTimeout) {
      widgetLog.info("Button: ignored while sending")
      return
    }
    let previous = SharedStore.loadSnapshot()
    guard let command = command(for: request, from: previous) else {
      widgetLog.info("Button: nothing to do for \(String(describing: request), privacy: .public)")
      return
    }
    if var optimistic = previous {
      command.apply(to: &optimistic)
      // Stamped now so the reload below doesn't start the provider's own live fetch
      // alongside this one.
      optimistic.updated = Date()
      SharedStore.saveSnapshot(optimistic)
    }
    let appIsLive = SharedStore.appIsLive(within: ACProvider.liveFetchStaleAfter)
    // The app applies a handed-over press at once; only the widget's own connection is slow.
    if !appIsLive { SharedStore.widgetSendingSince = Date() }
    WidgetReload.all()
    if appIsLive {
      if await handToApp(command) {
        widgetLog.info("Button: \(String(describing: command), privacy: .public) handed to the app")
        return
      }
      SharedStore.widgetSendingSince = Date()
      WidgetReload.all()
    }
    let start = Date()
    if let device = SharedStore.loadDevice() {
      await apply(command, to: device, since: start, restoring: previous)
    } else if let previous {
      SharedStore.saveSnapshot(previous)
    }
    SharedStore.widgetSendingSince = nil
    WidgetReload.all()
  }

  /// Connect to `device` and apply `command`, putting `previous` back if it doesn't land.
  private static func apply(
    _ command: WidgetCommand, to device: StoredDevice, since start: Date,
    restoring previous: Snapshot?
  ) async {
    do {
      let deadline = start + ACProvider.fetchBudget
      let applied = try await withTimeout(seconds: ACProvider.fetchBudget) {
        try await WidgetReach.run(device, deadline: deadline) { credentials in
          try await DeviceService.apply(credentials, displayName: device.displayName) {
            set in command.apply(to: &set)
          }
        }
      }
      widgetLog.info(
        "Button: \(String(describing: command), privacy: .public) applied in \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s"
      )
      SharedStore.saveSnapshot(applied)
    } catch {
      widgetLog.error(
        "Button: \(String(describing: command), privacy: .public) failed after \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s: \(String(describing: error), privacy: .public)"
      )
      if let previous { SharedStore.saveSnapshot(previous) }
    }
  }

  /// Queue `command` for the app and wait for it to be taken; whether it was. One the app
  /// doesn't take in time is withdrawn, since its stamp can outlive it.
  private static func handToApp(_ command: WidgetCommand) async -> Bool {
    let id = SharedStore.sendToApp(command)
    let taken = await waitUntil(timeout: handOffTimeout, checkingEvery: 0.1) {
      !SharedStore.isQueued(id)
    }
    if taken || !SharedStore.withdrawFromApp(id) {
      return true
    } else {
      widgetLog.info("Button: the app didn't take \(String(describing: command), privacy: .public)")
      return false
    }
  }

  /// The absolute command for `request`, or `nil` when it needs a reading there isn't, or
  /// would change nothing.
  private static func command(for request: WidgetRequest, from snapshot: Snapshot?)
    -> WidgetCommand?
  {
    if case .setPower(let powerOn) = request { return .setPower(powerOn) }
    guard let snapshot else { return nil }
    switch request {
    case .setPower(let powerOn):
      return .setPower(powerOn)
    case .togglePower:
      return .setPower(!snapshot.powerOn)
    case .adjustTemperature(let delta):
      guard snapshot.powerOn, snapshot.mode != .fanOnly else { return nil }
      let target = min(
        temperatureRange.upperBound,
        max(temperatureRange.lowerBound, snapshot.targetTemperature.rounded() + Double(delta)))
      return target == snapshot.targetTemperature ? nil : .setTarget(target)
    case .setMode(let mode):
      return .setMode(mode.rawValue)
    }
  }
}

struct TogglePowerIntent: AppIntent {
  static let title: LocalizedStringResource = "Toggle Power"
  static let isDiscoverable = false

  func perform() async throws -> some IntentResult {
    await WidgetCommandRunner.run(.togglePower)
    return .result()
  }
}

struct AdjustTemperatureIntent: AppIntent {
  static let title: LocalizedStringResource = "Adjust Temperature"
  static let isDiscoverable = false

  @Parameter(title: "Degrees") var delta: Int

  init() {}

  init(delta: Int) {
    self.delta = delta
  }

  func perform() async throws -> some IntentResult {
    await WidgetCommandRunner.run(.adjustTemperature(delta))
    return .result()
  }
}

struct SetModeIntent: AppIntent {
  static let title: LocalizedStringResource = "Set Mode"
  static let isDiscoverable = false

  @Parameter(title: "Mode") var modeRaw: Int

  init() {}

  init(mode: OperationalMode) {
    self.modeRaw = Int(mode.rawValue)
  }

  func perform() async throws -> some IntentResult {
    await WidgetCommandRunner.run(.setMode(OperationalMode(rawValue: UInt8(clamping: modeRaw))))
    return .result()
  }
}

/// Thrown by ``withTimeout`` when [seconds] elapses before the operation does.
private struct WidgetFetchTimeout: Error {}

/// Single-use guard so whichever of [operation]/the timer finishes first is the
/// only one to resume the continuation; the loser's task keeps running in the
/// background (harmless — it just finishes and gets ignored) rather than being
/// waited on.
private actor ResumeOnce {
  private var done = false
  func tryResume() -> Bool {
    if done { return false }
    done = true
    return true
  }
}

/// Run [operation], throwing if it doesn't finish within [seconds]. Bounds the
/// widget's live fetch so a stalled connection can't overrun WidgetKit's budget.
///
/// A `withThrowingTaskGroup` can't do this: structured concurrency requires the
/// group to wait for every child task to actually finish before it returns, even
/// after `cancelAll()`. `MideaConnection`'s continuation-based reads never check
/// `Task.isCancelled`, so that cancellation is a no-op and the group would block
/// for however long the real fetch takes (which can chain past a minute of
/// internal per-read timeouts) — silently defeating the bound and leaving
/// WidgetKit to blow its own refresh budget, which is what left the widget blank.
/// Racing two independent, unstructured tasks against a shared continuation
/// actually returns once the timer fires, regardless of the operation's progress.
func withTimeout<T: Sendable>(
  seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
    let guardState = ResumeOnce()
    Task {
      do {
        let value = try await operation()
        if await guardState.tryResume() { continuation.resume(returning: value) }
      } catch {
        if await guardState.tryResume() { continuation.resume(throwing: error) }
      }
    }
    Task {
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      if await guardState.tryResume() { continuation.resume(throwing: WidgetFetchTimeout()) }
    }
  }
}
