//
//  PermissionCoordinator.swift
//  FastMissionControl
//
//  Created by Codex.
//

import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
final class PermissionCoordinator: ObservableObject {
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var accessibilityGranted = false

    private var pollTask: Task<Void, Never>?

    var isReady: Bool {
        screenRecordingGranted && accessibilityGranted
    }

    func refresh() {
        screenRecordingGranted = Self.screenRecordingIsGranted()
        accessibilityGranted = AXIsProcessTrusted()
    }

    func refreshInBackground() {
        // These TCC checks have to run on the main thread. A detached read of
        // AXIsProcessTrusted / CGPreflightScreenCaptureAccess returns stale results.
        Task { @MainActor [weak self] in
            self?.refresh()
        }
    }

    func requestScreenRecording() {
        guard !screenRecordingGranted else { return }

        // A menu-bar agent is not active, so the system prompt is easy to miss.
        // CGRequestScreenCaptureAccess also often returns without UI on macOS 15+.
        // Fetching shareable content registers this bundle in Screen Recording,
        // and opening the pane gives the click a visible result.
        NSApp.activate()
        _ = CGRequestScreenCaptureAccess()
        SCShareableContent.getWithCompletionHandler { content, _ in
            guard content != nil else { return }
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        openPrivacyPane(.screenCapture)
        beginPolling()
    }

    func requestAccessibility() {
        guard !accessibilityGranted else { return }

        NSApp.activate()
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        guard !accessibilityGranted else { return }

        openPrivacyPane(.accessibility)
        beginPolling()
    }

    private func beginPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            // System Settings is another app. Keep reading until the user toggles
            // access or gives up, so the rows update without a relaunch.
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.refresh()
                if self.isReady {
                    return
                }
            }
        }
    }

    /// `CGPreflightScreenCaptureAccess` remembers the first answer for the life of
    /// the process. Window titles of other apps update as soon as the toggle changes.
    private static func screenRecordingIsGranted() -> Bool {
        switch otherAppWindowTitles() {
        case .visible:
            return true
        case .stripped:
            return false
        case .noOtherWindows:
            return CGPreflightScreenCaptureAccess()
        }
    }

    private enum OtherWindowTitles {
        case visible
        case stripped
        case noOtherWindows
    }

    private static func otherAppWindowTitles() -> OtherWindowTitles {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return .noOtherWindows
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var sawOtherAppWindow = false

        for info in windows {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            sawOtherAppWindow = true
            if let name = info[kCGWindowName as String] as? String, !name.isEmpty {
                return .visible
            }
        }

        return sawOtherAppWindow ? .stripped : .noOtherWindows
    }

    private enum PrivacyPane: String {
        case screenCapture = "Privacy_ScreenCapture"
        case accessibility = "Privacy_Accessibility"
    }

    private func openPrivacyPane(_ pane: PrivacyPane) {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane.rawValue)",
            "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)"
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate), NSWorkspace.shared.open(url) else { continue }
            return
        }
    }
}
