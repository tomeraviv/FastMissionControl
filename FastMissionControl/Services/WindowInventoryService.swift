//
//  WindowInventoryService.swift
//  FastMissionControl
//
//  Created by Codex.
//

import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import UniformTypeIdentifiers

enum WindowInventoryError: LocalizedError {
    case noDisplays

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            "No displays are available for building the overview."
        }
    }
}

private struct CGWindowRecord {
    let id: CGWindowID
    let pid: pid_t
    let bounds: CGRect
    let layer: Int
    let alpha: Double
    let zIndex: Int
    let title: String?
    let ownerName: String?
}

private struct DisplayGeometry {
    let id: CGDirectDisplayID
    let quartzFrame: CGRect
    let localFrame: CGRect
    let appKitFrame: CGRect
}

final class WindowInventoryService {
    // MARK: - Synchronous snapshot (instant, no SCShareableContent)

    func snapshotSync() throws -> OverviewSnapshot {
        let displayGeometry = buildDisplayGeometry()
        guard !displayGeometry.displays.isEmpty else {
            throw WindowInventoryError.noDisplays
        }

        let cgRecords = loadWindowRecords()
        let runningApps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let appMap = Dictionary(uniqueKeysWithValues: runningApps.map { ($0.processIdentifier, $0) })

        var visibleWindows: [WindowDescriptor] = []
        var visiblePIDs = Set<pid_t>()

        let sortedRecords = cgRecords.values.sorted { $0.zIndex < $1.zIndex }

        for record in sortedRecords {
            guard record.layer == 0, record.alpha > 0.001 else { continue }
            guard record.bounds.width >= 60, record.bounds.height >= 40 else { continue }
            guard let bestDisplay = bestDisplay(for: record.bounds, displays: displayGeometry.displays) else { continue }

            let runningApp = appMap[record.pid]
            // Skip our own app and system UI processes without windows.
            guard let appName = record.ownerName ?? runningApp?.localizedName else { continue }

            let icon = runningApp?.icon ?? NSWorkspace.shared.icon(for: .application)
            let appKitBounds = appKitFrame(
                forQuartzFrame: record.bounds,
                quartzUnionFrame: displayGeometry.quartzUnionFrame,
                appKitUnionFrame: displayGeometry.appKitUnionFrame
            )
            let sourceFrame = CGRect(
                x: record.bounds.minX - displayGeometry.quartzUnionFrame.minX,
                y: record.bounds.minY - displayGeometry.quartzUnionFrame.minY,
                width: record.bounds.width,
                height: record.bounds.height
            )

            let descriptor = WindowDescriptor(
                id: record.id,
                shareableWindow: nil,
                pid: record.pid,
                bundleIdentifier: runningApp?.bundleIdentifier,
                appName: appName,
                title: record.title,
                icon: icon,
                displayID: bestDisplay.id,
                sourceFrame: sourceFrame,
                appKitBounds: appKitBounds,
                zIndex: record.zIndex,
                axWindow: nil
            )

            visibleWindows.append(descriptor)
            visiblePIDs.insert(record.pid)
        }

        // Quick shelf: only check isHidden (sync, free — skip AX for speed).
        let shelfItems = runningApps.compactMap { app -> AppShelfItem? in
            guard !visiblePIDs.contains(app.processIdentifier) else { return nil }
            guard app.isHidden else { return nil }
            return AppShelfItem(
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                appName: app.localizedName ?? app.bundleIdentifier ?? "Application",
                icon: app.icon ?? NSWorkspace.shared.icon(for: .application),
                reason: .hidden,
                restorableWindows: []
            )
        }

        let displays = displayGeometry.displays.map { geometry in
            DisplayOverview(id: geometry.id, localFrame: geometry.localFrame, windowFrame: geometry.appKitFrame)
        }

        let cursorDisplayID = displayIDContainingCursor(from: displayGeometry.displays)
        let displayCount = displayGeometry.displays.count
        let livePreviewLimit = max(6, 14 - max(0, displayCount - 1) * 2)

        return OverviewSnapshot(
            windowFrame: displayGeometry.appKitUnionFrame,
            canvasSize: displayGeometry.quartzUnionFrame.size,
            displays: displays,
            windows: visibleWindows,
            shelfItems: shelfItems,
            cursorDisplayID: cursorDisplayID,
            livePreviewLimit: min(livePreviewLimit, max(visibleWindows.count, 1))
        )
    }

    // MARK: - Live polling (cheap, for diffing while overlay is open)

    struct VisibleWindowInfo {
        let pid: pid_t
        let appName: String?
    }

    func pollVisibleWindowIDs() -> [CGWindowID: VisibleWindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var result: [CGWindowID: VisibleWindowInfo] = [:]

        for info in raw {
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber else {
                continue
            }

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard layer == 0, alpha > 0.001 else { continue }

            let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any]
            let bounds = boundsDictionary.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            guard bounds.width >= 60, bounds.height >= 40 else { continue }

            let windowID = CGWindowID(number.uint32Value)
            let pid = pid_t(pidNumber.int32Value)
            let ownerName = info[kCGWindowOwnerName as String] as? String

            result[windowID] = VisibleWindowInfo(pid: pid, appName: ownerName)
        }

        return result
    }

    // MARK: - Resolve SCWindows (async, needed for preview captures)

    func resolveShareableWindows(for snapshot: OverviewSnapshot) async {
        guard let content = try? await SCShareableContent.current else { return }
        let scWindowsByID = Dictionary(
            content.windows.compactMap { w -> (CGWindowID, SCWindow)? in
                guard w.windowID != 0 else { return nil }
                return (w.windowID, w)
            },
            uniquingKeysWith: { first, _ in first }
        )

        for descriptor in snapshot.windows where descriptor.shareableWindow == nil {
            descriptor.shareableWindow = scWindowsByID[descriptor.id]
        }
    }

    // MARK: - Full async snapshot (legacy, used by prewarm for preview caching)

    func snapshot() async throws -> OverviewSnapshot {
        let displayGeometry = buildDisplayGeometry()
        guard !displayGeometry.displays.isEmpty else {
            throw WindowInventoryError.noDisplays
        }

        let shareableContent = try await SCShareableContent.current
        let cgRecords = loadWindowRecords()
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated }

        let appMap = Dictionary(uniqueKeysWithValues: runningApps.map { ($0.processIdentifier, $0) })

        let visibleWindows = shareableContent.windows.compactMap { window -> WindowDescriptor? in
            guard window.windowID != 0 else {
                return nil
            }

            guard let owner = window.owningApplication else {
                return nil
            }

            guard let cgRecord = cgRecords[window.windowID] else {
                return nil
            }

            guard cgRecord.layer == 0, cgRecord.alpha > 0.001 else {
                return nil
            }

            guard cgRecord.bounds.width >= 60, cgRecord.bounds.height >= 40 else {
                return nil
            }

            guard let bestDisplay = bestDisplay(for: cgRecord.bounds, displays: displayGeometry.displays) else {
                return nil
            }

            let runningApp = appMap[owner.processID]
            let icon = runningApp?.icon ?? NSWorkspace.shared.icon(for: .application)
            let appKitBounds = appKitFrame(
                forQuartzFrame: cgRecord.bounds,
                quartzUnionFrame: displayGeometry.quartzUnionFrame,
                appKitUnionFrame: displayGeometry.appKitUnionFrame
            )
            let sourceFrame = CGRect(
                x: cgRecord.bounds.minX - displayGeometry.quartzUnionFrame.minX,
                y: cgRecord.bounds.minY - displayGeometry.quartzUnionFrame.minY,
                width: cgRecord.bounds.width,
                height: cgRecord.bounds.height
            )
            return WindowDescriptor(
                id: window.windowID,
                shareableWindow: window,
                pid: owner.processID,
                bundleIdentifier: runningApp?.bundleIdentifier ?? owner.bundleIdentifier,
                appName: owner.applicationName,
                title: window.title,
                icon: icon,
                displayID: bestDisplay.id,
                sourceFrame: sourceFrame,
                appKitBounds: appKitBounds,
                zIndex: cgRecord.zIndex,
                axWindow: nil
            )
        }
        .reduce(into: [CGWindowID: WindowDescriptor]()) { partial, window in
            partial[window.id] = window
        }
        .values
        .sorted { lhs, rhs in
            lhs.zIndex < rhs.zIndex
        }

        let visiblePIDs = Set(visibleWindows.map { $0.pid })
        let shelfCandidateApps = runningApps.filter { !visiblePIDs.contains($0.processIdentifier) }
        let axWindowsByPID = loadAXWindows(for: shelfCandidateApps)
        let shelfItems = runningApps.compactMap { app -> AppShelfItem? in
            let axWindows = axWindowsByPID[app.processIdentifier] ?? []
            let hasVisibleWindow = visiblePIDs.contains(app.processIdentifier)
            let hasMinimizedWindow = axWindows.contains(where: \.isMinimized)

            guard !hasVisibleWindow, app.isHidden || hasMinimizedWindow else {
                return nil
            }

            let reason: AppShelfReason
            switch (app.isHidden, hasMinimizedWindow) {
            case (true, true):
                reason = .hiddenAndMinimized
            case (true, false):
                reason = .hidden
            case (false, true):
                reason = .minimized
            case (false, false):
                return nil
            }

            return AppShelfItem(
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                appName: app.localizedName ?? app.bundleIdentifier ?? "Application",
                icon: app.icon ?? NSWorkspace.shared.icon(for: .application),
                reason: reason,
                restorableWindows: axWindows
            )
        }

        let displays = displayGeometry.displays.map { geometry in
            DisplayOverview(id: geometry.id, localFrame: geometry.localFrame, windowFrame: geometry.appKitFrame)
        }

        let cursorDisplayID = displayIDContainingCursor(from: displayGeometry.displays)
        let displayCount = displayGeometry.displays.count
        let livePreviewLimit = max(6, 14 - max(0, displayCount - 1) * 2)

        return OverviewSnapshot(
            windowFrame: displayGeometry.appKitUnionFrame,
            canvasSize: displayGeometry.quartzUnionFrame.size,
            displays: displays,
            windows: visibleWindows,
            shelfItems: shelfItems,
            cursorDisplayID: cursorDisplayID,
            livePreviewLimit: min(livePreviewLimit, max(visibleWindows.count, 1))
        )
    }

    private func buildDisplayGeometry() -> (displays: [DisplayGeometry], quartzUnionFrame: CGRect, appKitUnionFrame: CGRect) {
        let screens = NSScreen.screens
        let appKitUnion = screens.reduce(into: CGRect.null) { partial, screen in
            partial = partial.union(screen.frame)
        }

        let screenEntries = screens.compactMap { screen -> (CGDirectDisplayID, CGRect, CGRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            let id = CGDirectDisplayID(number.uint32Value)
            return (id, CGDisplayBounds(id), screen.frame)
        }

        let quartzUnion = screenEntries.reduce(into: CGRect.null) { partial, entry in
            partial = partial.union(entry.1)
        }

        let displays = screenEntries.map { id, frame, appKitFrame in
            DisplayGeometry(
                id: id,
                quartzFrame: frame,
                localFrame: localCanvasFrame(forQuartzFrame: frame, inside: quartzUnion),
                appKitFrame: appKitFrame
            )
        }
        .sorted { lhs, rhs in
            if lhs.quartzFrame.minY == rhs.quartzFrame.minY {
                return lhs.quartzFrame.minX < rhs.quartzFrame.minX
            }

            return lhs.quartzFrame.minY < rhs.quartzFrame.minY
        }

        return (displays, quartzUnion, appKitUnion)
    }

    private func displayIDContainingCursor(from displays: [DisplayGeometry]) -> CGDirectDisplayID? {
        let location = NSEvent.mouseLocation

        for screen in NSScreen.screens {
            if screen.frame.contains(location),
               let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                return CGDirectDisplayID(number.uint32Value)
            }
        }

        return displays.first?.id
    }

    private func loadWindowRecords() -> [CGWindowID: CGWindowRecord] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var result: [CGWindowID: CGWindowRecord] = [:]

        for (index, info) in raw.enumerated() {
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }

            let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) ?? .zero
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1

            let title = info[kCGWindowName as String] as? String
            let ownerName = info[kCGWindowOwnerName as String] as? String

            let record = CGWindowRecord(
                id: CGWindowID(number.uint32Value),
                pid: pid_t(pidNumber.int32Value),
                bounds: bounds,
                layer: layer,
                alpha: alpha,
                zIndex: index,
                title: title,
                ownerName: ownerName
            )

            result[record.id] = record
        }

        return result
    }

    private func loadAXWindows(for apps: [NSRunningApplication]) -> [pid_t: [AXWindowHandle]] {
        var result: [pid_t: [AXWindowHandle]] = [:]

        for app in apps {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.05)

            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
            guard status == .success, let rawWindows = value as? [AXUIElement] else {
                result[app.processIdentifier] = []
                continue
            }

            result[app.processIdentifier] = rawWindows.compactMap { window in
                let title = copyString(attribute: kAXTitleAttribute as CFString, from: window)
                let frame = copyFrame(from: window)
                let isMinimized = copyBool(attribute: kAXMinimizedAttribute as CFString, from: window)
                return AXWindowHandle(element: window, title: title, frame: frame, isMinimized: isMinimized)
            }
        }

        return result
    }

    private func copyString(attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private func copyBool(attribute: CFString, from element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return false
        }

        return (value as? Bool) ?? false
    }

    private func copyFrame(from element: AXUIElement) -> CGRect {
        let position = copyPoint(attribute: kAXPositionAttribute as CFString, from: element)
        let size = copySize(attribute: kAXSizeAttribute as CFString, from: element)
        return CGRect(origin: position, size: size)
    }

    private func copyPoint(attribute: CFString, from element: AXUIElement) -> CGPoint {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return .zero
        }

        var point = CGPoint.zero
        AXValueGetValue(axValue as! AXValue, .cgPoint, &point)
        return point
    }

    private func copySize(attribute: CFString, from element: AXUIElement) -> CGSize {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return .zero
        }

        var size = CGSize.zero
        AXValueGetValue(axValue as! AXValue, .cgSize, &size)
        return size
    }

    private func appKitFrame(forQuartzFrame frame: CGRect, quartzUnionFrame: CGRect, appKitUnionFrame: CGRect) -> CGRect {
        CGRect(
            x: appKitUnionFrame.minX + (frame.minX - quartzUnionFrame.minX),
            y: appKitUnionFrame.minY + (quartzUnionFrame.maxY - frame.maxY),
            width: frame.width,
            height: frame.height
        )
    }

    private func localCanvasFrame(forQuartzFrame frame: CGRect, inside quartzUnionFrame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX - quartzUnionFrame.minX,
            y: frame.minY - quartzUnionFrame.minY,
            width: frame.width,
            height: frame.height
        )
    }

    private func bestDisplay(for bounds: CGRect, displays: [DisplayGeometry]) -> DisplayGeometry? {
        displays.max { lhs, rhs in
            intersectionArea(bounds, lhs.quartzFrame) < intersectionArea(bounds, rhs.quartzFrame)
        }
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        lhs.intersection(rhs).isNull ? 0 : lhs.intersection(rhs).width * lhs.intersection(rhs).height
    }
}
