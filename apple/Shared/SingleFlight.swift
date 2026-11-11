import Foundation
import Synchronization

/// Runs one operation at a time; callers that arrive while it runs await the same result.
final class SingleFlight<Value: Sendable>: Sendable {
  private let running = Mutex<Task<Value, Never>?>(nil)

  /// Create a coordinator with nothing running.
  init() {}

  /// Run `operation`, or join the one already running and return its result.
  func run(_ operation: @escaping @Sendable () async -> Value) async -> Value {
    let task = running.withLock { slot in
      if let current = slot {
        return current
      } else {
        let started = Task {
          let value = await operation()
          running.withLock { $0 = nil }
          return value
        }
        slot = started
        return started
      }
    }
    return await task.value
  }
}

/// Wait up to `timeout` for `condition` to hold, checking every `interval`; whether it did.
func waitUntil(
  timeout: TimeInterval, checkingEvery interval: TimeInterval,
  _ condition: @Sendable () -> Bool
) async -> Bool {
  let deadline = Date() + timeout
  while !condition() {
    let remaining = deadline.timeIntervalSinceNow
    guard remaining > 0 else { return false }
    try? await Task.sleep(nanoseconds: UInt64(min(interval, remaining) * 1_000_000_000))
  }
  return true
}
