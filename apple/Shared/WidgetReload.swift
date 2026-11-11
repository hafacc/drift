import WidgetKit

/// Asks the system to redraw everything that shows the shared snapshot.
enum WidgetReload {
  /// Reload every widget timeline, and on iOS every control too.
  static func all() {
    WidgetCenter.shared.reloadAllTimelines()
    #if os(iOS)
      ControlCenter.shared.reloadAllControls()
    #endif
  }
}
