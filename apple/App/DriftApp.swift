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

  #if DEBUG
    /// For store screenshots: with `-DriftScreenshotFile YES`, writes the window as a
    /// base64 PNG to standard output once it has drawn; the app is sandboxed, and an app
    /// may capture its own windows without screen recording access.
    func applicationDidFinishLaunching(_ notification: Notification) {
      guard UserDefaults.standard.bool(forKey: "DriftScreenshotFile") else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.showWindow() }
      Task {
        do {
          try await Self.captureWindow()
        } catch {
          print("DRIFT-SCREENSHOT-ERROR \(error)")
        }
      }
    }

    private static func captureWindow() async throws {
      try await Task.sleep(for: .seconds(4))
      let number = await MainActor.run {
        NSApp.windows.first(where: \.isVisible)?.windowNumber ?? 0
      }
      // CGWindowListCreateImage is gone from the SDK but still answers for an app's own
      // windows without screen recording access, which ScreenCaptureKit doesn't.
      typealias CreateImage =
        @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
      guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
        let image = unsafeBitCast(symbol, to: CreateImage.self)(
          .null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(number),
          CGWindowImageOption.bestResolution.rawValue)?.takeRetainedValue()
      else {
        print("DRIFT-SCREENSHOT-ERROR no image")
        return
      }
      if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
        print("DRIFT-SCREENSHOT " + png.base64EncodedString())
        fflush(stdout)
      }
    }
  #endif

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
