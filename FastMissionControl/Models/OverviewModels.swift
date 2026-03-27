//
//  OverviewModels.swift
//  FastMissionControl
//
//  Created by Codex.
//

import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import ScreenCaptureKit
import SwiftUI

enum AppShelfReason {
    case hidden
    case minimized
    case hiddenAndMinimized
}

final class AXWindowHandle {
    let element: AXUIElement
    let title: String?
    let frame: CGRect
    let isMinimized: Bool

    init(element: AXUIElement, title: String?, frame: CGRect, isMinimized: Bool) {
        self.element = element
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
    }
}

final class WindowDescriptor: ObservableObject, Identifiable {
    let id: CGWindowID
    var shareableWindow: SCWindow?
    let pid: pid_t
    let bundleIdentifier: String?
    let appName: String
    let title: String?
    let icon: NSImage
    let iconCGImage: CGImage?
    let displayID: CGDirectDisplayID
    let sourceFrame: CGRect
    let appKitBounds: CGRect
    let zIndex: Int
    var axWindow: AXWindowHandle?

    var targetFrame: CGRect = .zero
    var titleBarFrame: CGRect = .zero

    @Published var previewImage: CGImage?

    init(
        id: CGWindowID,
        shareableWindow: SCWindow?,
        pid: pid_t,
        bundleIdentifier: String?,
        appName: String,
        title: String?,
        icon: NSImage,
        displayID: CGDirectDisplayID,
        sourceFrame: CGRect,
        appKitBounds: CGRect,
        zIndex: Int,
        axWindow: AXWindowHandle?,
        previewImage: CGImage? = nil
    ) {
        self.id = id
        self.shareableWindow = shareableWindow
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.title = title
        self.icon = icon
        self.iconCGImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
        self.displayID = displayID
        self.sourceFrame = sourceFrame
        self.appKitBounds = appKitBounds
        self.zIndex = zIndex
        self.axWindow = axWindow
        self.previewImage = previewImage
    }

    var sortTitle: String {
        if let title, !title.isEmpty {
            return title
        }

        return appName
    }

    var previewAspectRatio: CGFloat {
        max(sourceFrame.width / max(sourceFrame.height, 1), 0.55)
    }

    var displayTitle: String {
        let base = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (base?.isEmpty == false) ? base! : appName
    }
}

struct DisplayOverview: Identifiable {
    let id: CGDirectDisplayID
    let localFrame: CGRect
    let windowFrame: CGRect
}

struct AppShelfItem: Identifiable {
    let pid: pid_t
    let bundleIdentifier: String?
    let appName: String
    let icon: NSImage
    let reason: AppShelfReason
    let restorableWindows: [AXWindowHandle]

    var id: String {
        bundleIdentifier ?? "pid-\(pid)"
    }
}

struct OverviewSnapshot {
    let windowFrame: CGRect
    let canvasSize: CGSize
    let displays: [DisplayOverview]
    let windows: [WindowDescriptor]
    let shelfItems: [AppShelfItem]
    let cursorDisplayID: CGDirectDisplayID?
    let livePreviewLimit: Int
}

enum OverviewPhase {
    case collapsed
    case expanded
}
