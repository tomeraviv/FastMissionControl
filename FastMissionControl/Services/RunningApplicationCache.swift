//
//  RunningApplicationCache.swift
//  FastMissionControl
//
//  Created by Codex.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
struct RunningApplicationRecord {
    let app: NSRunningApplication
    let icon: NSImage

    var pid: pid_t {
        app.processIdentifier
    }

    var bundleIdentifier: String? {
        app.bundleIdentifier
    }

    var localizedName: String? {
        app.localizedName
    }
}

@MainActor
final class RunningApplicationCache {
    private let workspace = NSWorkspace.shared
    private let notificationCenter: NotificationCenter
    private let defaultIcon: NSImage
    private let refreshTTL: TimeInterval

    private var observerTokens: [NSObjectProtocol] = []
    private var records: [RunningApplicationRecord] = []
    private var recordsByPID: [pid_t: RunningApplicationRecord] = [:]
    private var needsRefresh = true
    private var lastRefreshTime: TimeInterval = 0

    init(refreshTTL: TimeInterval = 2.0) {
        self.refreshTTL = refreshTTL
        notificationCenter = workspace.notificationCenter
        defaultIcon = workspace.icon(for: .application)
        installObservers()
    }

    deinit {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
    }

    func allRecords() -> [RunningApplicationRecord] {
        refreshIfNeeded()
        return records
    }

    func record(for pid: pid_t) -> RunningApplicationRecord? {
        refreshIfNeeded()
        return recordsByPID[pid]
    }

    private func installObservers() {
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]

        for name in names {
            let token = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.needsRefresh = true
                }
            }
            observerTokens.append(token)
        }
    }

    private func refreshIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard needsRefresh || now - lastRefreshTime >= refreshTTL else {
            return
        }

        let freshRecords = workspace.runningApplications
            .filter { !$0.isTerminated }
            .map { app in
                RunningApplicationRecord(
                    app: app,
                    icon: app.icon ?? defaultIcon
                )
            }

        records = freshRecords
        recordsByPID = Dictionary(uniqueKeysWithValues: freshRecords.map { ($0.pid, $0) })
        needsRefresh = false
        lastRefreshTime = now
    }
}
