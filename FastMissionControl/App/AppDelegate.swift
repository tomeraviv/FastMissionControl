//
//  AppDelegate.swift
//  FastMissionControl
//
//  Created by Codex.
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    lazy var appModel = AppModel(settings: settings)

    func applicationDidFinishLaunching(_ notification: Notification) {
        appModel.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appModel.refreshPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appModel.shutdown()
    }
}
