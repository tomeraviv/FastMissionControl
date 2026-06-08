//
//  AppDelegate.swift
//  FastMissionControl
//
//  Created by Codex.
//

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let reopenNotification = Notification.Name("io.github.fastmissioncontrol.reopen-existing-instance")

    let settings = AppSettings()
    lazy var appModel = AppModel(settings: settings)
    private var reopenObserver: Any?
    private var menuBarController: MenuBarController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerReopenObserver()

        if handOffToExistingInstanceIfNeeded() {
            NSApp.terminate(nil)
            return
        }

        appModel.controlWindowProvider = { [weak self] in self?.settingsWindowEnsuringCreated() }

        menuBarController = MenuBarController(
            onOpenOverview: { [weak self] in self?.appModel.toggleOverview() },
            onOpenSettings: { [weak self] in self?.appModel.showControlWindow() }
        )

        appModel.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appModel.refreshPermissions()
    }

    // Re-launching the agent (Finder / Dock / `open`) is the user's way back to Settings, since it
    // has no Dock tile. AppKit's contract: return false when we've handled the reopen ourselves,
    // true to let AppKit run its default handling. We always try to surface Settings — if that
    // succeeds we've handled it (false); if it couldn't (no window provider), defer to AppKit (true).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let handledByShowingSettings = appModel.showControlWindow()
        return !handledByShowingSettings
    }

    // The app is a menu-bar agent — always running, no Dock tile — so closing the Settings window
    // leaves it alive. Trade-off: if macOS drops the status item (rare, e.g. a full menu bar) the
    // app has no visible surface; relaunching it reopens Settings via the reopen handler above.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let reopenObserver {
            DistributedNotificationCenter.default().removeObserver(reopenObserver)
            self.reopenObserver = nil
        }

        appModel.shutdown()
    }

    // MARK: - Settings window

    private func settingsWindowEnsuringCreated() -> NSWindow {
        if let settingsWindow {
            return settingsWindow
        }
        let hosting = NSHostingController(rootView: ContentView(model: appModel))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Fast Mission Control"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 680, height: 760))
        window.center()
        settingsWindow = window
        return window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Keep the window object alive across hides so we don't lose Settings state when reopened.
        guard sender === settingsWindow else { return true }
        appModel.hideControlWindow()
        return false
    }

    // MARK: - Reopen channel (single-instance handoff)

    private func registerReopenObserver() {
        guard reopenObserver == nil,
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return
        }

        reopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.reopenNotification,
            object: bundleIdentifier,
            queue: .main
        ) { [weak self] notification in
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let sourcePID = notification.userInfo?["sourcePID"] as? pid_t

            guard sourcePID != currentPID else {
                return
            }

            Task { @MainActor [weak self] in
                self?.appModel.showControlWindow()
            }
        }
    }

    private func handOffToExistingInstanceIfNeeded() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { app in
                app.processIdentifier != currentPID && !app.isTerminated
            }

        guard !otherInstances.isEmpty else {
            return false
        }

        DistributedNotificationCenter.default().postNotificationName(
            Self.reopenNotification,
            object: bundleIdentifier,
            userInfo: ["sourcePID": currentPID],
            options: [.deliverImmediately]
        )

        return true
    }
}
