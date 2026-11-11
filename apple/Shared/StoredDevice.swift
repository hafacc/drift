import Foundation
import MideaKit

/// What we persist about a set-up device: its credentials plus an optional
/// user-chosen nickname. Stored in the shared Keychain so the widget sees it too.
struct StoredDevice: Codable {
  var credentials: DeviceCredentials
  var nickname: String?

  var displayName: String {
    if let nickname, !nickname.isEmpty { return nickname }
    return credentials.name
  }
}
