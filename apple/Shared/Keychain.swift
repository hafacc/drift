import Foundation
import Security

/// Secure storage for device credentials (token/key), shared between the app and
/// the widget via a keychain access group. Secrets belong in the Keychain, not in
/// a plist / UserDefaults.
///
/// The access group is `<TeamID>.cc.hafa.Drift.shared`, which must match
/// the `keychain-access-groups` entitlement on both targets. The team prefix is
/// discovered at runtime so it never has to be hard-coded.
enum Keychain {
  private static let accessGroupSuffix = "cc.hafa.Drift.shared"
  private static let service = "cc.hafa.Drift.credentials"
  private static let account = "device"

  /// Persist [data], returning the `SecItemAdd` status so callers can tell a real
  /// failure (e.g. an access-group/signing mismatch) from success instead of
  /// silently working from memory until the next launch loses the credentials.
  @discardableResult
  static func save(_ data: Data) -> OSStatus {
    var query = baseQuery()
    SecItemDelete(query as CFDictionary)  // absent is fine; only the add's status matters
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(query as CFDictionary, nil)
  }

  static func delete() {
    SecItemDelete(baseQuery() as CFDictionary)
  }

  static func load() -> Data? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
      return nil
    }
    return result as? Data
  }

  /// Team-prefixed App Group identifier (e.g. `ABCDE12345.cc.hafa.Drift`) for a
  /// `$(AppIdentifierPrefix)cc.hafa.Drift` entitlement. macOS App Groups must
  /// carry the Team ID prefix (the iOS-style `group.…` form needs a provisioning
  /// profile to authorize it and fails under local signing). Reuses the same
  /// runtime-discovered prefix as the Keychain access group.
  static func appGroupID(_ name: String) -> String? {
    teamPrefix().map { "\($0).\(name)" }
  }

  private static func baseQuery() -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    // Without an access group the app still works; only widget sharing needs it.
    if let group = accessGroup() {
      query[kSecAttrAccessGroup as String] = group
    }
    return query
  }

  private static func accessGroup() -> String? {
    guard let prefix = teamPrefix() else { return nil }
    return "\(prefix).\(accessGroupSuffix)"
  }

  /// Discover the team-id prefix by reading the access group of a probe item.
  private static func teamPrefix() -> String? {
    let probe: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrAccount as String: "teamPrefixProbe",
      kSecAttrService as String: "teamPrefixProbe",
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    var status = SecItemCopyMatching(probe as CFDictionary, &result)
    if status == errSecItemNotFound {
      status = SecItemAdd(probe as CFDictionary, &result)
    }
    guard status == errSecSuccess,
      let attributes = result as? [String: Any],
      let group = attributes[kSecAttrAccessGroup as String] as? String,
      let prefix = group.components(separatedBy: ".").first
    else {
      return nil
    }
    return prefix
  }
}
