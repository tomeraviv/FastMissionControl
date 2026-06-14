//
//  AppDelegate.swift
//  FastMissionControl
//
//  Created by Codex.
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let reopenNotification = Notification.Name("io.github.fastmissioncontrol.reopen-existing-instance")
    private static let hasCompletedFirstLaunchKey = "io.github.fastmissioncontrol.hasCompletedFirstLaunch"

    private enum StartupWindowBehavior {
        case show
        case hide
    }

    let settings = AppSettings()
    lazy var appModel = AppModel(settings: settings)
    private var reopenObserver: Any?
    private var startupWindowObserver: Any?
    private var startupWindowBehavior: StartupWindowBehavior?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerReopenObserver()

        if handOffToExistingInstanceIfNeeded() {
            NSApp.terminate(nil)
            return
        }

        _ = NSApp.setActivationPolicy(.regular)
        appModel.start()
        applyStartupWindowBehavior()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appModel.refreshPermissions()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !appModel.showControlWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let reopenObserver {
            DistributedNotificationCenter.default().removeObserver(reopenObserver)
            self.reopenObserver = nil
        }

        removeStartupWindowObserver()

        appModel.shutdown()
    }

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

    private func applyStartupWindowBehavior() {
        let defaults = UserDefaults.standard
        let isFirstLaunch = !defaults.bool(forKey: Self.hasCompletedFirstLaunchKey)
        defaults.set(true, forKey: Self.hasCompletedFirstLaunchKey)

        let behavior: StartupWindowBehavior = (isFirstLaunch || !appModel.permissions.isReady) ? .show : .hide
        startupWindowBehavior = behavior
        installStartupWindowObserverIfNeeded()

        switch behavior {
        case .show:
            if appModel.showControlWindow() {
                removeStartupWindowObserver()
            }
        case .hide:
            appModel.hideControlWindow()
        }
    }

    private func installStartupWindowObserverIfNeeded() {
        guard startupWindowObserver == nil else {
            return
        }

        startupWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { [weak self] in
                guard let self,
                      let window = notification.object as? NSWindow,
                      !(window is NSPanel) else {
                    return
                }

                switch self.startupWindowBehavior {
                case .show:
                    _ = self.appModel.showControlWindow()
                case .hide:
                    self.appModel.hideControlWindow()
                case nil:
                    return
                }

                self.removeStartupWindowObserver()
            }
        }
    }

    private func removeStartupWindowObserver() {
        if let startupWindowObserver {
            NotificationCenter.default.removeObserver(startupWindowObserver)
            self.startupWindowObserver = nil
        }

        startupWindowBehavior = nil
    }
}
