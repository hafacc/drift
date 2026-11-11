import SwiftUI

/// The iPhone app: setup until an AC is set up, then its controls.
@main
struct DriftApp: App {
  @State private var store = DeviceStore()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(store)
        // The widgets open drift://open, which only has to bring the app forward.
        .onOpenURL { _ in }
    }
  }
}

/// Shows setup or the controls, whichever the store needs.
struct ContentView: View {
  @Environment(DeviceStore.self) private var store

  var body: some View {
    if store.needsSetup {
      SetupView()
    } else {
      ControlView()
    }
  }
}
