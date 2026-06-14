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

    // The settings window is created and managed imperatively by AppDelegate using
    // NSHostingController so we can keep it out of the way until the user requests it from the
    // status menu (and so closing it hides it rather than destroying the scene). The App protocol
    // still needs a Scene, so we supply an empty Settings scene that never auto-opens.
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
