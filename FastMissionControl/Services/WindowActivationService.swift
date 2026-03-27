//
//  WindowActivationService.swift
//  FastMissionControl
//
//  Created by Codex.
//

import AppKit
import ApplicationServices

@MainActor
final class WindowActivationService {
    private let matcher = AXWindowMatcher()

    // MARK: - Fast path (call BEFORE hiding overlay)

    /// Bring the *application* to front immediately.  This is a
    /// cheap NSRunningApplication call — no AX involved — so the
    /// target app is visible the instant our overlay hides.
    func activateAppFast(pid: pid_t) {
        let app = NSRunningApplication(processIdentifier: pid)
        _ = app?.activate(options: [.activateAllWindows])
    }

    // MARK: - Slow path (call AFTER overlay is hidden, in background)

    /// Resolve and raise the specific window via Accessibility.
    /// This may block on AX IPC so it must run *after* the overlay
    /// is already hidden to avoid any perceived lag.
    func raiseSpecificWindow(descriptor: WindowDescriptor) {
        let handle = descriptor.axWindow ?? resolveWindowHandle(for: descriptor)
        descriptor.axWindow = handle

        guard let handle else { return }

        let application = AXUIElementCreateApplication(descriptor.pid)

        if handle.isMinimized {
            _ = AXUIElementSetAttributeValue(
                handle.element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }

        _ = AXUIElementSetAttributeValue(handle.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, handle.element)
        _ = AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString)
    }

    /// Resolve and raise the first restorable shelf window.
    func raiseSpecificWindow(shelfItem item: AppShelfItem) {
        guard let handle = item.restorableWindows.first else { return }

        let application = AXUIElementCreateApplication(item.pid)

        if handle.isMinimized {
            _ = AXUIElementSetAttributeValue(
                handle.element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }

        _ = AXUIElementSetAttributeValue(handle.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, handle.element)
        _ = AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString)
    }

    // MARK: - AX helpers

    private func resolveWindowHandle(for descriptor: WindowDescriptor) -> AXWindowHandle? {
        let handles = loadAXWindows(for: descriptor.pid)
        return matcher.match(title: descriptor.title, appKitBounds: descriptor.appKitBounds, candidates: handles)
    }

    private func loadAXWindows(for pid: pid_t) -> [AXWindowHandle] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let rawWindows = value as? [AXUIElement] else {
            return []
        }

        return rawWindows.compactMap { window in
            let title = copyString(attribute: kAXTitleAttribute as CFString, from: window)
            let frame = copyFrame(from: window)
            let isMinimized = copyBool(attribute: kAXMinimizedAttribute as CFString, from: window)
            return AXWindowHandle(element: window, title: title, frame: frame, isMinimized: isMinimized)
        }
    }

    private func copyString(attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private func copyBool(attribute: CFString, from element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    private func copyFrame(from element: AXUIElement) -> CGRect {
        CGRect(
            origin: copyPoint(attribute: kAXPositionAttribute as CFString, from: element),
            size: copySize(attribute: kAXSizeAttribute as CFString, from: element)
        )
    }

    private func copyPoint(attribute: CFString, from element: AXUIElement) -> CGPoint {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else { return .zero }
        var point = CGPoint.zero
        AXValueGetValue(axValue as! AXValue, .cgPoint, &point)
        return point
    }

    private func copySize(attribute: CFString, from element: AXUIElement) -> CGSize {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else { return .zero }
        var size = CGSize.zero
        AXValueGetValue(axValue as! AXValue, .cgSize, &size)
        return size
    }
}
