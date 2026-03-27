//
//  PermissionCoordinator.swift
//  FastMissionControl
//
//  Created by Codex.
//

import ApplicationServices
import Combine
import CoreGraphics
import Foundation

@MainActor
final class PermissionCoordinator: ObservableObject {
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var accessibilityGranted = false

    var isReady: Bool {
        screenRecordingGranted && accessibilityGranted
    }

    func refresh() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrustedWithOptions(nil)
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }
}
