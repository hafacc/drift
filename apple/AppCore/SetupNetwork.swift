import Foundation
import MideaKit

/// The network operations first-run setup performs, so tests can stand in for the AC
/// and Midea's cloud.
protocol SetupNetwork: Sendable {
  /// Listen for ACs on the network.
  nonisolated(nonsending) func discover() async throws -> [DiscoveredDevice]
  /// Sign in to Midea's cloud with the person's Midea account.
  nonisolated(nonsending) func login(account: String, password: String) async throws
    -> any SetupCloudSession
  /// Read a version-2 AC's state with the given credentials, throwing if it doesn't answer.
  nonisolated(nonsending) func check(_ credentials: DeviceCredentials) async throws
}

/// A signed-in session with Midea's cloud.
protocol SetupCloudSession: Sendable {
  /// Fetch the AC's token and key from the cloud and return the pair it answers with.
  nonisolated(nonsending) func credentials(for device: DiscoveredDevice) async throws
    -> DeviceCredentials
}

/// The real network: LAN discovery, Midea's cloud, and the AC itself.
struct LiveSetupNetwork: SetupNetwork {
  nonisolated(nonsending) func discover() async throws -> [DiscoveredDevice] {
    try await DeviceSearch.discover()
  }

  nonisolated(nonsending) func login(account: String, password: String) async throws
    -> any SetupCloudSession
  {
    LiveCloudSession(
      session: try await SmartHomeCloud(account: account, password: password).login())
  }

  nonisolated(nonsending) func check(_ credentials: DeviceCredentials) async throws {
    _ = try await MideaClient.withSession(credentials: credentials) { try await $0.refresh() }
  }
}

private struct LiveCloudSession: SetupCloudSession {
  let session: SmartHomeSession

  nonisolated(nonsending) func credentials(for device: DiscoveredDevice) async throws
    -> DeviceCredentials
  {
    try await Setup.credentials(for: device, session: session)
  }
}

/// What first-run setup reaches the outside world through: the network, and the clock
/// it waits on between tries.
struct SetupEnvironment: Sendable {
  /// The network operations setup performs.
  var network: any SetupNetwork = LiveSetupNetwork()
  /// Wait out a pause between tries, throwing if the task is cancelled.
  var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

  /// The real network and clock.
  static let live = SetupEnvironment()
}
