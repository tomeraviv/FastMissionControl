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

    // MARK: - Pre-resolution (call while overlay is still open)

    private var cachedHandlesByPID: [pid_t: [AXWindowHandle]] = [:]

    /// Batch-resolve AX handles for every window in the snapshot so that
    /// subsequent raise calls are nearly instant (no AX query at click time).
    /// Queries AX once per unique PID, then matches each descriptor.
    func preResolveAXHandles(for snapshot: OverviewSnapshot) {
        cachedHandlesByPID.removeAll()
        for descriptor in snapshot.windows where descriptor.axWindow == nil {
            if cachedHandlesByPID[descriptor.pid] == nil {
                cachedHandlesByPID[descriptor.pid] = loadAXWindows(for: descriptor.pid)
            }
            descriptor.axWindow = matcher.match(
                title: descriptor.title,
                appKitBounds: descriptor.appKitBounds,
                candidates: cachedHandlesByPID[descriptor.pid]!
            )
        }
    }

    /// Eagerly resolve the AX handle for a single descriptor on hover
    /// so the click path has zero AX cost.
    func ensureAXHandle(for descriptor: WindowDescriptor) {
        guard descriptor.axWindow == nil else { return }
        if cachedHandlesByPID[descriptor.pid] == nil {
            cachedHandlesByPID[descriptor.pid] = loadAXWindows(for: descriptor.pid)
        }
        descriptor.axWindow = matcher.match(
            title: descriptor.title,
            appKitBounds: descriptor.appKitBounds,
            candidates: cachedHandlesByPID[descriptor.pid]!
        )
    }

    // MARK: - Raise (call AFTER overlay is hidden, synchronously)

    /// Raise the specific window via its pre-resolved (or lazily resolved)
    /// AX handle.  Call synchronously right after dismiss — the overlay is
    /// already invisible so the few ms of AX IPC is imperceptible.
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

    /// Raise a window identified only by its CGWindowID and owning pid.
    /// Used for brand-new windows discovered while the overview is open,
    /// where no WindowDescriptor exists.
    func raiseSpecificWindow(windowID: CGWindowID, pid: pid_t) {
        guard let cgFrame = cgWindowFrame(for: windowID) else { return }
        let handles = loadAXWindows(for: pid)
        guard let best = closestHandle(to: cgFrame, among: handles) else { return }

        let application = AXUIElementCreateApplication(pid)

        if best.isMinimized {
            _ = AXUIElementSetAttributeValue(
                best.element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }

        _ = AXUIElementSetAttributeValue(best.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, best.element)
        _ = AXUIElementPerformAction(best.element, kAXRaiseAction as CFString)
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

    /// Look up the Quartz frame for a specific CGWindowID.
    private func cgWindowFrame(for windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any] else {
            return nil
        }
        return CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
    }

    /// Pick the AX handle whose frame is closest to the given Quartz frame.
    private func closestHandle(to quartzFrame: CGRect, among handles: [AXWindowHandle]) -> AXWindowHandle? {
        handles.min { lhs, rhs in
            frameDelta(lhs.frame, quartzFrame) < frameDelta(rhs.frame, quartzFrame)
        }
    }

    private func frameDelta(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.origin.x - b.origin.x) + abs(a.origin.y - b.origin.y)
            + abs(a.width - b.width) + abs(a.height - b.height)
    }
}
