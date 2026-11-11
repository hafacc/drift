import AppKit
import SwiftUI

/// Drives the single-window lifecycle: quit when the window closes (a one-window
/// utility has no reason to linger in the Dock headless), and bring the window back
/// on reactivation (e.g. a Dock click after minimizing — WindowGroup won't reopen a
/// closed window on its own).
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Closing the only window quits the app. The widget is a separate process and
  /// is unaffected — it reads the shared store and fetches on its own.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    showWindow()
    return true
  }

  @MainActor
  private func showWindow() {
    NSApp.activate()
    NSApp.windows.first?.makeKeyAndOrderFront(nil)
  }
}

@main
struct DriftApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var store = DeviceStore()

  var body: some Scene {
    WindowGroup("Drift") {
      ContentView()
        .environment(store)
        // The widget taps open drift://open; just bring the app forward.
        .onOpenURL { _ in
          NSApp.activate()
          NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
    .windowResizability(.contentSize)
  }
}
