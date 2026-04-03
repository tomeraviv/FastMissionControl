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

    let settings = AppSettings()
    lazy var appModel = AppModel(settings: settings)
    private var reopenObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerReopenObserver()

        if handOffToExistingInstanceIfNeeded() {
            NSApp.terminate(nil)
            return
        }

        _ = NSApp.setActivationPolicy(.regular)
        appModel.start()
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
}
