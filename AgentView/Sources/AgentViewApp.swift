import SwiftUI

@main
struct AgentViewApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    // No main window; we run as a menubar/agent app.
    Settings {
      EmptyView()
    }
  }
}


