//
//  AgentViewSwiftUIApp.swift
//  AgentView
//
//  NOTE: This file is intentionally NOT the app entry point.
//  The actual @main app for the project lives in `AgentView/Sources/AgentViewApp.swift`.
//

import SwiftUI

/// Kept around so the SwiftUI sample UI (`ContentView`) can still compile if it’s referenced elsewhere.
/// This avoids a filename/type collision with `AgentView/Sources/AgentViewApp.swift`.
struct AgentViewSwiftUIApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

