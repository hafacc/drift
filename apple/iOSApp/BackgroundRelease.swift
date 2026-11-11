import UIKit

extension DeviceStore {
  /// Stop polling as the app goes to the background, keeping it running until the AC's
  /// connection is released so iOS doesn't suspend it while still holding the AC's only slot.
  func stopPollingForBackground() {
    let assertion = BackgroundAssertion(name: "Release the AC connection")
    let release = stopPolling()
    Task {
      await release.value
      assertion.end()
    }
  }
}

/// A UIKit background task, ended once, whichever comes first: `end()` or its expiry.
@MainActor
private final class BackgroundAssertion {
  private var identifier = UIBackgroundTaskIdentifier.invalid

  /// Begin a background task called `name`.
  init(name: String) {
    identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
      self?.end()
    }
  }

  /// End the background task, if it hasn't ended already.
  func end() {
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    identifier = .invalid
  }
}
