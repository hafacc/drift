import Foundation
import MideaKit

/// Stateless local operations against the AC, shared by the app and the widget.
/// Each call opens a fresh authenticated connection.
enum DeviceService {
  static func fetchSnapshot(
    _ credentials: DeviceCredentials, displayName: String
  ) async throws -> Snapshot {
    let state = try await MideaClient.withSession(credentials: credentials) { client in
      try await client.refresh()
    }
    return Snapshot(state: state, deviceName: displayName, updated: Date())
  }

  /// Refresh current state, apply a change on top of it, and return the result.
  static func apply(
    _ credentials: DeviceCredentials, displayName: String,
    _ change: @escaping (inout SetState) -> Void
  ) async throws -> Snapshot {
    let state = try await MideaClient.withSession(credentials: credentials) { client in
      let current = try await client.refresh()
      var set = SetState(from: current)
      change(&set)
      return try await client.apply(set)
    }
    return Snapshot(state: state, deviceName: displayName, updated: Date())
  }
}
