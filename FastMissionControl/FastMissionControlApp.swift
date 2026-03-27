//
//  FastMissionControlApp.swift
//  FastMissionControl
//
//  Created by Tomer Aviv on 27/03/2026.
//

import SwiftUI

@main
struct FastMissionControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(model: appDelegate.appModel)
        }
        .windowResizability(.contentSize)
    }
}
