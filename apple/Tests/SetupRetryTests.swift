import Foundation
import MideaKit
import Synchronization
import Testing

/// A network call setup made, in the order it made them.
enum NetworkCall: Equatable, CustomStringConvertible {
  case discover
  case login(email: String, password: String)
  case credentials
  case check

  var description: String {
    switch self {
    case .discover: "discover"
    case .login(let email, let password): "login(\(email), \(password))"
    case .credentials: "credentials"
    case .check: "check"
    }
  }
}

/// Stands in for the AC and Midea's cloud, recording every call; tests flip what
/// succeeds between attempts.
final class FakeNetwork: SetupNetwork {
  /// How the cloud answers a sign-in.
  enum Login { case works, unreachable, rejected, fails }
  /// How the cloud answers a key fetch.
  enum Keys { case returned, missing, unreachable, notOwner }
  /// How the AC answers a local query.
  enum Answer { case silent, rejectsKey, answers }

  struct Behavior {
    var findsAC = true
    var version = 3
    var login = Login.works
    var keys = Keys.returned
    var answer = Answer.silent
  }

  static let token: [UInt8] = Array(repeating: 0, count: 64)
  static let key: [UInt8] = Array(repeating: 1, count: 32)

  private let state = Mutex<(behavior: Behavior, calls: [NetworkCall])>((Behavior(), []))

  var calls: [NetworkCall] { state.withLock { $0.calls } }

  func update(_ change: (inout Behavior) -> Void) {
    state.withLock { change(&$0.behavior) }
  }

  private func record(_ call: NetworkCall) -> Behavior {
    state.withLock { current in
      current.calls.append(call)
      return current.behavior
    }
  }

  nonisolated(nonsending) func discover() async throws -> [DiscoveredDevice] {
    let behavior = record(.discover)
    return behavior.findsAC
      ? [
        DiscoveredDevice(
          id: 0x1234_5678, ip: "127.0.0.1", port: 6444, version: behavior.version,
          name: "Test AC", serialNumber: nil)
      ] : []
  }

  nonisolated(nonsending) func login(account: String, password: String) async throws
    -> any SetupCloudSession
  {
    switch record(.login(email: account, password: password)).login {
    case .works: return FakeCloudSession(network: self)
    case .unreachable: throw URLError(.notConnectedToInternet)
    case .rejected: throw CloudError.loginRejected(code: 1, message: "wrong password")
    case .fails: throw NoAnswer()
    }
  }

  nonisolated(nonsending) func check(_ credentials: DeviceCredentials) async throws {
    #expect(credentials.version == 2)
    try Self.answer(record(.check).answer)
  }

  /// Mirrors `Setup.credentials(for:session:)`: an error from the AC wins over one from
  /// the cloud.
  fileprivate func credentials(for device: DiscoveredDevice) throws -> DeviceCredentials {
    let behavior = record(.credentials)
    switch behavior.keys {
    case .returned: break
    case .missing: throw CloudError.keyNotFound(udpid: "")
    case .unreachable: throw URLError(.timedOut)
    case .notOwner: throw CloudError.notDeviceOwner(message: "not yours")
    }
    try Self.answer(behavior.answer)
    return DeviceCredentials(device: device, token: Self.token, key: Self.key)
  }

  /// Stands in for MideaKit's timeout, which tests can't create.
  private struct NoAnswer: Error {}

  private static func answer(_ answer: Answer) throws {
    switch answer {
    case .silent: throw NoAnswer()
    case .rejectsKey: throw HandshakeError.rejected
    case .answers: break
    }
  }
}

private struct FakeCloudSession: SetupCloudSession {
  let network: FakeNetwork

  nonisolated(nonsending) func credentials(for device: DiscoveredDevice) async throws
    -> DeviceCredentials
  {
    #expect(device.version >= 3)
    return try network.credentials(for: device)
  }
}

/// A clock whose pauses last until the test releases them, recording how long each
/// one asked for. Cancelling the waiting task ends its pause at once, like `Task.sleep`.
@MainActor
final class FakeClock {
  private(set) var requested: [Duration] = []
  private var waiting: [Int] = []
  private var released: Set<Int> = []

  /// The number of pauses in progress.
  var pending: Int { waiting.count }

  var sleep: @Sendable (Duration) async throws -> Void {
    { [self] duration in try await pause(duration) }
  }

  private func pause(_ duration: Duration) async throws {
    requested.append(duration)
    let index = requested.count
    waiting.append(index)
    defer { waiting.removeAll { $0 == index } }
    while !released.contains(index) {
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  /// End the oldest pause in progress.
  func release() {
    if let first = waiting.first { released.insert(first) }
  }
}

/// Wait until `condition` holds, failing the test if it doesn't within a few seconds.
@MainActor
func eventually(
  _ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
) async {
  let deadline = ContinuousClock.now + .seconds(5)
  while !condition() {
    if ContinuousClock.now > deadline {
      Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
      return
    }
    try? await Task.sleep(for: .milliseconds(1))
  }
}

/// Let any work the store has queued run, to show nothing else happens.
@MainActor
func settle() async {
  try? await Task.sleep(for: .milliseconds(100))
}

extension SetupStep {
  fileprivate var label: String {
    switch self {
    case .searching: "searching"
    case .fetchingKey: "fetchingKey"
    case .checking(let attempt, let total): "checking \(attempt)/\(total)"
    }
  }
}

extension DeviceStore.SetupPhase {
  fileprivate var label: String {
    switch self {
    case .idle: "idle"
    case .running(let step): step.label
    case .waiting(_, _, let step): "waiting → \(step.label)"
    case .failed: "failed"
    }
  }
}

private let account = CloudAccount(email: "ac@example.com", password: "secret")
private let accountLogin = NetworkCall.login(email: account.email, password: account.password)

/// A store wired to the fakes and filled in with `account`, plus a log of the setup
/// phases it went through.
@MainActor
final class Harness {
  let network = FakeNetwork()
  let clock = FakeClock()
  let store: DeviceStore
  private(set) var phases: [String] = []

  init() {
    store = DeviceStore(
      setupEnvironment: SetupEnvironment(network: network, sleep: clock.sleep))
    store.cloudAccount = account
    phases = [store.setupPhase.label]
    store.onSetupPhaseChange = { [unowned self] phase in
      if phases.last != phase.label { phases.append(phase.label) }
    }
  }

  /// Phases since the last call.
  func takePhases() -> [String] {
    defer { phases = [store.setupPhase.label] }
    return phases
  }

  /// Calls since the last call.
  private var callsSeen = 0
  func takeCalls() -> [NetworkCall] {
    let calls = network.calls
    defer { callsSeen = calls.count }
    return Array(calls[callsSeen...])
  }

  /// Wait for the `count`th pause and return how long it asked for.
  func pause(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async -> Duration? {
    await eventually("pause \(count)", sourceLocation: sourceLocation) {
      clock.requested.count >= count && clock.pending > 0
    }
    return clock.requested.count >= count ? clock.requested[count - 1] : nil
  }
}

private let keyFetch: [NetworkCall] = [accountLogin, .credentials]

@MainActor
@Suite(.serialized)
struct SetupRetryTests {
  @Test func storeStartsWithoutADevice() {
    let harness = Harness()
    #expect(harness.store.needsSetup)
    #expect(harness.store.setupPhase.label == "idle")
  }

  @Test func missingKeyStopsRetrying() async {
    let harness = Harness()
    harness.network.update { $0.keys = .missing }
    harness.store.setup()

    await eventually("setup to fail") { harness.store.setupPhase.label == "failed" }
    await settle()
    #expect(harness.clock.requested.isEmpty)
    #expect(harness.takeCalls() == [.discover] + keyFetch)
    #expect(harness.takePhases() == ["idle", "searching", "fetchingKey", "checking 1/3", "failed"])
    #expect(
      harness.store.setupPhase.failure?.message
        == "Midea's cloud didn't return the key.")
    #expect(
      harness.store.setupPhase.failure?.hint
        == "Make sure the AC shows up in the MSmartHome app under this account, then \(SetupWording.press) Set Up again."
    )
    harness.store.forget()
  }

  @Test func failingKeyFetchRetriesWithoutSearching() async {
    let harness = Harness()
    harness.network.update { $0.keys = .unreachable }
    harness.store.setup()

    #expect(await harness.pause(1) == .seconds(5))
    #expect(harness.takeCalls() == [.discover] + keyFetch)
    #expect(
      harness.takePhases() == [
        "idle", "searching", "fetchingKey", "checking 1/3", "waiting → fetchingKey",
      ])
    #expect(harness.store.setupPhase.failure?.message == "Couldn't reach Midea's cloud.")

    for (attempt, delay) in [10, 20, 30, 30, 30].enumerated() {
      harness.clock.release()
      #expect(await harness.pause(attempt + 2) == .seconds(delay))
      #expect(harness.takeCalls() == keyFetch)
      #expect(
        harness.takePhases() == [
          "waiting → fetchingKey", "fetchingKey", "checking 1/3", "waiting → fetchingKey",
        ])
    }
    #expect(harness.network.calls.filter { $0 == .discover }.count == 1)
    harness.store.forget()
  }

  @Test func silentACIsAskedAgainUntilItAnswers() async {
    let harness = Harness()
    harness.store.setup()

    #expect(await harness.pause(1) == .seconds(2))
    #expect(harness.takePhases() == ["idle", "searching", "fetchingKey", "checking 1/3"])
    harness.clock.release()
    #expect(await harness.pause(2) == .seconds(5))
    #expect(harness.takePhases() == ["checking 1/3", "checking 2/3"])
    harness.clock.release()
    #expect(await harness.pause(3) == .seconds(5))
    #expect(
      harness.takeCalls() == [.discover, accountLogin, .credentials, .credentials, .credentials])
    #expect(harness.takePhases() == ["checking 2/3", "checking 3/3", "waiting → fetchingKey"])
    #expect(
      harness.store.setupPhase.failure?.message
        == "Found the AC and got its key, but the AC didn't answer.")

    harness.clock.release()
    #expect(await harness.pause(4) == .seconds(2))
    #expect(harness.takeCalls() == keyFetch)
    #expect(harness.takePhases() == ["waiting → fetchingKey", "fetchingKey", "checking 1/3"])

    harness.network.update { $0.answer = .answers }
    harness.clock.release()
    await eventually("setup to finish") { !harness.store.needsSetup }
    #expect(harness.takeCalls() == [.credentials])
    #expect(harness.takePhases() == ["checking 1/3", "checking 2/3", "idle"])
    #expect(harness.clock.pending == 0)
    harness.store.forget()
  }

  @Test func acRejectingTheKeyStopsRetrying() async {
    let harness = Harness()
    harness.network.update { $0.answer = .rejectsKey }
    harness.store.setup()

    await eventually("setup to fail") { harness.store.setupPhase.label == "failed" }
    await settle()
    #expect(harness.clock.requested.isEmpty)
    #expect(harness.takeCalls() == [.discover] + keyFetch)
    #expect(harness.takePhases() == ["idle", "searching", "fetchingKey", "checking 1/3", "failed"])
    #expect(
      harness.store.setupPhase.failure?.message
        == "The AC turned down the key from Midea's cloud.")
    harness.store.forget()
  }

  @Test func failedSignInRetriesWithoutSearching() async {
    let harness = Harness()
    harness.network.update { $0.login = .fails }
    harness.store.setup()

    #expect(await harness.pause(1) == .seconds(5))
    #expect(harness.takeCalls() == [.discover, accountLogin])
    #expect(harness.takePhases() == ["idle", "searching", "fetchingKey", "waiting → fetchingKey"])
    #expect(harness.store.setupPhase.failure?.message == "Couldn't sign in to Midea's cloud.")

    harness.network.update { $0.login = .works }
    harness.clock.release()
    #expect(await harness.pause(2) == .seconds(2))
    #expect(harness.takeCalls() == keyFetch)
    harness.store.forget()
  }

  @Test func versionTwoACSkipsTheCloud() async {
    let harness = Harness()
    harness.network.update { $0.version = 2 }
    harness.store.setup()

    #expect(await harness.pause(1) == .seconds(2))
    harness.clock.release()
    #expect(await harness.pause(2) == .seconds(5))
    harness.clock.release()
    #expect(await harness.pause(3) == .seconds(5))
    #expect(harness.takeCalls() == [.discover, .check, .check, .check])
    #expect(
      harness.takePhases() == [
        "idle", "searching", "checking 1/3", "checking 2/3", "checking 3/3",
        "waiting → checking 1/3",
      ])
    #expect(harness.store.setupPhase.failure?.message == "Found the AC, but it didn't answer.")

    harness.network.update { $0.answer = .answers }
    harness.clock.release()
    await eventually("setup to finish") { !harness.store.needsSetup }
    #expect(harness.takeCalls() == [.check])
    harness.store.forget()
  }

  @Test func failedSearchSearchesAgain() async {
    let harness = Harness()
    harness.network.update {
      $0.findsAC = false
      $0.keys = .unreachable
    }
    harness.store.setup()

    #expect(await harness.pause(1) == .seconds(5))
    #expect(harness.takeCalls() == [.discover, .discover])
    #expect(harness.takePhases() == ["idle", "searching", "waiting → searching"])
    #expect(
      harness.store.setupPhase.failure?.message == "Couldn't find an AC on this network.")

    harness.clock.release()
    #expect(await harness.pause(2) == .seconds(10))
    #expect(harness.takeCalls() == [.discover, .discover])
    #expect(harness.takePhases() == ["waiting → searching", "searching", "waiting → searching"])

    harness.network.update { $0.findsAC = true }
    harness.clock.release()
    #expect(await harness.pause(3) == .seconds(20))
    #expect(harness.takeCalls() == [.discover] + keyFetch)
    #expect(
      harness.takePhases() == [
        "waiting → searching", "searching", "fetchingKey", "checking 1/3",
        "waiting → fetchingKey",
      ])
    harness.store.forget()
  }

  @Test func leavingTheScreenDuringACheckStopsItAndReturningSkipsTheSearch() async {
    let harness = Harness()
    harness.store.setup()
    #expect(await harness.pause(1) == .seconds(2))
    _ = harness.takeCalls()
    _ = harness.takePhases()

    harness.store.pauseSetup()
    await eventually("the pause to be cancelled") { harness.clock.pending == 0 }
    await settle()
    #expect(harness.takeCalls() == [])
    #expect(harness.takePhases() == ["checking 1/3", "idle"])

    harness.store.resumeSetup()
    #expect(await harness.pause(2) == .seconds(2))
    #expect(harness.takeCalls() == keyFetch)
    #expect(harness.takePhases() == ["idle", "fetchingKey", "checking 1/3"])
    harness.store.forget()
  }

  @Test func leavingTheScreenPausesRetriesAndReturningResumesAtTheFailedStep() async {
    let harness = Harness()
    harness.network.update { $0.keys = .unreachable }
    harness.store.setup()
    #expect(await harness.pause(1) == .seconds(5))
    _ = harness.takeCalls()
    _ = harness.takePhases()

    harness.store.pauseSetup()
    await eventually("the pause to be cancelled") { harness.clock.pending == 0 }
    await settle()
    #expect(harness.takeCalls() == [])
    #expect(harness.takePhases() == ["waiting → fetchingKey", "failed"])

    harness.store.resumeSetup()
    #expect(await harness.pause(2) == .seconds(5))
    #expect(harness.takeCalls() == keyFetch)
    harness.store.forget()
  }

  @Test func repeatedSetupCallsRunOneLoop() async {
    let harness = Harness()
    harness.network.update { $0.keys = .unreachable }
    harness.store.setup()
    harness.store.setup()
    #expect(await harness.pause(1) == .seconds(5))
    harness.store.setup()
    harness.store.resumeSetup()
    await settle()
    #expect(harness.clock.requested.count == 1)
    #expect(harness.clock.pending == 1)
    #expect(harness.takeCalls() == [.discover] + keyFetch)

    harness.clock.release()
    #expect(await harness.pause(2) == .seconds(10))
    await settle()
    #expect(harness.clock.requested.count == 2)
    #expect(harness.clock.pending == 1)
    #expect(harness.takeCalls() == keyFetch)
    harness.store.forget()
  }

  @Test func forgetResetsEverything() async {
    let harness = Harness()
    harness.store.setup()
    #expect(await harness.pause(1) == .seconds(2))
    harness.clock.release()
    #expect(await harness.pause(2) == .seconds(5))
    harness.clock.release()
    #expect(await harness.pause(3) == .seconds(5))
    _ = harness.takeCalls()

    harness.store.forget()
    await eventually("the pause to be cancelled") { harness.clock.pending == 0 }
    await settle()
    #expect(harness.takeCalls() == [])
    #expect(harness.store.setupPhase.label == "idle")
    #expect(harness.store.needsSetup)
    #expect(harness.store.cloudAccount.email.isEmpty)
    _ = harness.takePhases()

    // Nothing found before is kept: setup starts over with a search.
    harness.store.cloudAccount = account
    harness.store.setup()
    #expect(await harness.pause(4) == .seconds(2))
    #expect(harness.takeCalls() == [.discover] + keyFetch)
    #expect(harness.takePhases() == ["idle", "searching", "fetchingKey", "checking 1/3"])
    harness.store.forget()
  }

  @Test func setUpWaitsForTheAccount() async {
    let harness = Harness()
    harness.store.cloudAccount.password = ""
    harness.store.setup()
    await settle()
    #expect(harness.takeCalls() == [])
    #expect(harness.store.setupPhase.label == "idle")
  }

  @Test func wrongPasswordStopsRetrying() async {
    let harness = Harness()
    harness.network.update { $0.login = .rejected }
    harness.store.setup()

    await eventually("setup to fail") { harness.store.setupPhase.label == "failed" }
    await settle()
    #expect(harness.clock.requested.isEmpty)
    #expect(harness.takeCalls() == [.discover, accountLogin])
    #expect(harness.takePhases() == ["idle", "searching", "fetchingKey", "failed"])
    #expect(
      harness.store.setupPhase.failure?.message
        == "Midea didn't accept that email and password.")

    // Coming back to the screen doesn't try the same password again.
    harness.store.pauseSetup()
    harness.store.resumeSetup()
    await settle()
    #expect(harness.takeCalls() == [])

    // Set Up with a corrected password picks up at the sign-in.
    harness.network.update { $0.login = .works }
    harness.store.cloudAccount.password = "corrected"
    harness.store.setup()
    #expect(await harness.pause(1) == .seconds(2))
    #expect(
      harness.takeCalls()
        == [.login(email: account.email, password: "corrected"), .credentials])
    harness.store.forget()
  }

  @Test func acInAnotherAccountStopsRetrying() async {
    let harness = Harness()
    harness.network.update { $0.keys = .notOwner }
    harness.store.setup()

    await eventually("setup to fail") { harness.store.setupPhase.label == "failed" }
    await settle()
    #expect(harness.clock.requested.isEmpty)
    #expect(harness.takeCalls() == [.discover] + keyFetch)
    #expect(
      harness.store.setupPhase.failure?.message == "This AC isn't in that Midea account.")
    harness.store.forget()
  }

  @Test func unreachableCloudRetriesWithoutSearching() async {
    let harness = Harness()
    harness.network.update { $0.login = .unreachable }
    harness.store.setup()

    #expect(await harness.pause(1) == .seconds(5))
    #expect(harness.takeCalls() == [.discover, accountLogin])
    #expect(harness.takePhases() == ["idle", "searching", "fetchingKey", "waiting → fetchingKey"])
    #expect(harness.store.setupPhase.failure?.message == "Couldn't reach Midea's cloud.")

    harness.network.update {
      $0.login = .works
      $0.keys = .unreachable
    }
    harness.clock.release()
    #expect(await harness.pause(2) == .seconds(10))
    #expect(harness.takeCalls() == keyFetch)
    #expect(harness.store.setupPhase.failure?.message == "Couldn't reach Midea's cloud.")

    harness.network.update { $0.keys = .returned }
    harness.clock.release()
    #expect(await harness.pause(3) == .seconds(2))
    #expect(harness.takeCalls() == keyFetch)
    #expect(harness.network.calls.filter { $0 == .discover }.count == 1)
    harness.store.forget()
  }

  @Test func accountEditedDuringAPauseIsUsedByTheNextTry() async {
    let harness = Harness()
    harness.network.update { $0.login = .unreachable }
    harness.store.setup()
    #expect(await harness.pause(1) == .seconds(5))
    _ = harness.takeCalls()

    harness.store.cloudAccount = CloudAccount(email: " new@example.com ", password: "new")
    harness.clock.release()
    #expect(await harness.pause(2) == .seconds(10))
    #expect(harness.takeCalls() == [.login(email: "new@example.com", password: "new")])
    harness.store.forget()
  }

  @Test func accountIsClearedOnceSetUp() async {
    let harness = Harness()
    harness.network.update { $0.answer = .answers }
    harness.store.setup()
    await eventually("setup to finish") { !harness.store.needsSetup }
    #expect(harness.store.cloudAccount.email.isEmpty)
    #expect(harness.store.cloudAccount.password.isEmpty)
    harness.store.forget()
  }

  @Test func accountIsClearedByForget() async {
    let harness = Harness()
    harness.network.update { $0.keys = .unreachable }
    harness.store.setup()
    #expect(await harness.pause(1) == .seconds(5))

    harness.store.forget()
    #expect(harness.store.cloudAccount.email.isEmpty)
    #expect(harness.store.cloudAccount.password.isEmpty)
  }
}
