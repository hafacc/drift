import Foundation
import MideaKit

/// The setup step currently running, worded for the setup screen.
enum SetupStep: Equatable {
  case searching
  case fetchingKey
  case checking(attempt: Int, of: Int)

  /// Short progress text for the setup screen.
  var message: String {
    switch self {
    case .searching: return "Searching the network…"
    case .fetchingKey: return "Signing in to Midea's cloud…"
    case .checking(let attempt, let total):
      return attempt == 1 ? "Checking the AC…" : "Checking the AC (try \(attempt) of \(total))…"
    }
  }

  /// Countdown text while a retry of this step waits to start.
  func retryMessage(in seconds: Int) -> String {
    let action: String
    switch self {
    case .searching: action = "Searching again"
    case .fetchingKey: action = "Signing in again"
    case .checking: action = "Checking the AC again"
    }
    return seconds > 0 ? "\(action) in \(seconds) s…" : "\(action)…"
  }
}

/// A failed setup step: what went wrong and what to do about it.
struct SetupFailure: Error {
  /// What failed, in plain words.
  let message: String
  /// What the user can do next.
  let hint: String
  /// Whether trying the same step again later could get past this failure on its own.
  var retries = true
}

/// Words in setup's messages that differ between the Mac and the iPhone.
enum SetupWording {
  #if os(iOS)
    /// The kind of device Drift runs on.
    static let device = "iPhone"
    /// The verb for pressing a button.
    static let press = "tap"
    /// Where the Local Network permission lives.
    static let localNetworkSettings = "Settings → Privacy & Security → Local Network"
  #else
    /// The kind of device Drift runs on.
    static let device = "Mac"
    /// The verb for pressing a button.
    static let press = "click"
    /// Where the Local Network permission lives.
    static let localNetworkSettings = "System Settings → Privacy & Security → Local Network"
  #endif
}

/// The Midea account setup signs in to for the AC's key; held only in memory.
struct CloudAccount {
  /// The account's email address.
  var email = ""
  /// The account's password.
  var password = ""

  /// Whether both fields are filled in.
  var isComplete: Bool {
    !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
  }
}

/// First-run setup, one step at a time so the screen can say which step is running
/// and which one failed: find the AC on the network, sign in to Midea's cloud, then
/// fetch the AC's key and check it with the AC itself.
@MainActor
enum SetupFlow {
  // The AC serves one client at a time and frees its slot lazily, so a busy AC gets
  // a few spaced-out tries rather than a quick burst.
  private static let checkDelays: [Duration] = [.seconds(2), .seconds(5)]
  private static let discoveryRounds = 2
  private static let noKey = SetupFailure(
    message: "Midea's cloud didn't return the key.",
    hint:
      "Make sure the AC shows up in the MSmartHome app under this account, then \(SetupWording.press) Set Up again.",
    retries: false)
  private static let unreachable = SetupFailure(
    message: "Couldn't reach Midea's cloud.",
    hint: "Check this \(SetupWording.device)'s internet connection.")
  private static let signInFailed = SetupFailure(
    message: "Couldn't sign in to Midea's cloud.", hint: "Try again later.")
  private static let keyRejected = SetupFailure(
    message: "The AC turned down the key from Midea's cloud.",
    hint: "Make sure the AC is in this Midea account, then \(SetupWording.press) Set Up again.",
    retries: false)
  private static let busyHint = "Another device may be connected to it. Close the app there."

  /// The step a setup attempt starts at, skipping the search when an earlier attempt
  /// found the AC.
  static func firstStep(knownDevice: DiscoveredDevice?) -> SetupStep {
    if let knownDevice {
      if knownDevice.version >= 3 {
        return .fetchingKey
      } else {
        return .checking(attempt: 1, of: checkDelays.count + 1)
      }
    } else {
      return .searching
    }
  }

  /// Find an AC unless `knownDevice` is set, sign in with `account` if it needs a key,
  /// and check it locally, reporting each step and handing a newly found AC to `found`.
  static func run(
    knownDevice: DiscoveredDevice?, account: CloudAccount, environment: SetupEnvironment,
    progress: (SetupStep) -> Void, found: (DiscoveredDevice) -> Void
  ) async throws(SetupFailure) -> DeviceCredentials {
    let device: DiscoveredDevice
    if let knownDevice {
      device = knownDevice
    } else {
      progress(.searching)
      device = try await discover(environment.network)
      found(device)
    }

    guard device.version >= 3 else {
      // Version 2 needs no key.
      let credentials = DeviceCredentials(device: device)
      return try await check(
        environment: environment, progress: progress,
        failure: SetupFailure(message: "Found the AC, but it didn't answer.", hint: busyHint)
      ) {
        try await environment.network.check(credentials)
        return credentials
      }
    }

    progress(.fetchingKey)
    let session = try await login(account, network: environment.network)
    return try await check(
      environment: environment, progress: progress,
      failure: SetupFailure(
        message: "Found the AC and got its key, but the AC didn't answer.", hint: busyHint),
      stopping: cloudFailure
    ) {
      try await session.credentials(for: device)
    }
  }

  private static func discover(_ network: any SetupNetwork) async throws(SetupFailure)
    -> DiscoveredDevice
  {
    let notFound = SetupFailure(
      message: "Couldn't find an AC on this network.",
      hint:
        "Make sure this \(SetupWording.device) is on the AC's Wi-Fi and Drift is allowed in \(SetupWording.localNetworkSettings)."
    )
    // The first search after install can run while the Local Network prompt is still up.
    for _ in 0..<discoveryRounds where !Task.isCancelled {
      let found = try? await network.discover()
      if let device = found?.sorted(by: { $0.id < $1.id }).first { return device }
    }
    throw notFound
  }

  private static func login(_ account: CloudAccount, network: any SetupNetwork)
    async throws(SetupFailure) -> any SetupCloudSession
  {
    do {
      return try await network.login(
        account: account.email.trimmingCharacters(in: .whitespacesAndNewlines),
        password: account.password)
    } catch CloudError.loginRejected(let code, let message) {
      throw SetupFailure(
        message: "Midea didn't accept that email and password.",
        hint:
          "Midea said: \(message) (\(code)). Check them, then \(SetupWording.press) Set Up again.",
        retries: false)
    } catch is URLError {
      throw unreachable
    } catch {
      throw signInFailed
    }
  }

  /// The failure a key fetch error ends the check with, or `nil` when it's worth
  /// asking the AC again.
  private static func cloudFailure(_ error: any Error) -> SetupFailure? {
    switch error {
    case CloudError.notDeviceOwner:
      SetupFailure(
        message: "This AC isn't in that Midea account.",
        hint:
          "Sign in with the account the AC was set up in, then \(SetupWording.press) Set Up again.",
        retries: false)
    case is URLError: unreachable
    case is CloudError: noKey
    case HandshakeError.rejected: keyRejected
    default: nil
    }
  }

  /// Run `attempt` a few times with growing pauses until the AC answers, ending early
  /// with the failure `stopping` gives an error, and with `failure` once tries run out.
  private static func check(
    environment: SetupEnvironment, progress: (SetupStep) -> Void, failure: SetupFailure,
    stopping: (any Error) -> SetupFailure? = { _ in nil },
    attempt: () async throws -> DeviceCredentials
  ) async throws(SetupFailure) -> DeviceCredentials {
    let attempts = checkDelays.count + 1
    for number in 1...attempts where !Task.isCancelled {
      progress(.checking(attempt: number, of: attempts))
      do {
        return try await attempt()
      } catch {
        if let stop = stopping(error) { throw stop }
      }
      if number < attempts {
        try? await environment.sleep(checkDelays[number - 1])
      }
    }
    throw failure
  }
}
