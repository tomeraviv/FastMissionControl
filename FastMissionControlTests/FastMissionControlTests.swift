//
//  FastMissionControlTests.swift
//  FastMissionControlTests
//
//  Created by Tomer Aviv on 27/03/2026.
//

import Testing
import AppKit
@testable import FastMissionControl

struct FastMissionControlTests {

    @Test func secondaryDisplayClusteredWindowsSpreadAcrossColumns() {
        let settings = makeIsolatedSettings(testName: #function)
        let primaryDisplay = DisplayOverview(
            id: 1,
            localFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            windowFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        let secondaryDisplay = DisplayOverview(
            id: 2,
            localFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            windowFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        )

        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let clusteredSourceFrame = CGRect(x: 2280, y: 120, width: 980, height: 720)

        let windows: [WindowDescriptor] = (0..<4).map { index in
            WindowDescriptor(
                id: CGWindowID(10_000 + index),
                shareableWindow: nil,
                pid: 1,
                bundleIdentifier: "com.example.app\(index)",
                appName: "App \(index)",
                title: "Window \(index)",
                icon: icon,
                displayID: secondaryDisplay.id,
                sourceFrame: clusteredSourceFrame,
                appKitBounds: clusteredSourceFrame,
                zIndex: index,
                axWindow: nil
            )
        }

        let snapshot = OverviewSnapshot(
            windowFrame: CGRect(x: 0, y: 0, width: 3840, height: 1080),
            canvasSize: CGSize(width: 3840, height: 1080),
            displays: [primaryDisplay, secondaryDisplay],
            windows: windows,
            shelfItems: [],
            cursorDisplayID: secondaryDisplay.id,
            livePreviewLimit: 8
        )

        SpatialOverviewLayout(settings: settings).apply(to: snapshot)

        let centerXs = windows.map(\.targetFrame.midX)
        let spanX = (centerXs.max() ?? 0) - (centerXs.min() ?? 0)
        #expect(spanX > 300)

        let coarseColumns = Set(centerXs.map { Int(($0 / 50).rounded()) })
        #expect(coarseColumns.count >= 2)
    }

    @Test func clusteredLargeWindowsFillMostOfOverviewSpace() {
        let settings = makeIsolatedSettings(testName: #function)
        let display = DisplayOverview(
            id: 1,
            localFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            windowFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117)
        )
        let icon = NSImage(size: NSSize(width: 16, height: 16))

        let windows: [WindowDescriptor] = (0..<10).map { index in
            let source = CGRect(x: 180, y: 140, width: 1320, height: 860)
            return WindowDescriptor(
                id: CGWindowID(20_000 + index),
                shareableWindow: nil,
                pid: 1,
                bundleIdentifier: "com.example.fill\(index)",
                appName: "Fill App \(index)",
                title: "Fill Window \(index)",
                icon: icon,
                displayID: display.id,
                sourceFrame: source,
                appKitBounds: source,
                zIndex: index,
                axWindow: nil
            )
        }

        let snapshot = OverviewSnapshot(
            windowFrame: display.windowFrame,
            canvasSize: display.windowFrame.size,
            displays: [display],
            windows: windows,
            shelfItems: [],
            cursorDisplayID: display.id,
            livePreviewLimit: 10
        )

        SpatialOverviewLayout(settings: settings).apply(to: snapshot)

        let union = windows.reduce(CGRect.null) { partial, window in
            partial.union(window.targetFrame)
        }

        let expectedContentRect = CGRect(
            x: 48,
            y: 48 + 46, // top padding + title reserve
            width: 1728 - 96,
            height: 1117 - 48 - 130 - 46
        )

        let horizontalFill = union.width / expectedContentRect.width
        let verticalFill = union.height / expectedContentRect.height

        #expect(horizontalFill > 0.82)
        #expect(verticalFill > 0.82)
    }

}

private func makeIsolatedSettings(testName: String) -> AppSettings {
    let suiteName = "FastMissionControlTests.\(testName)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated UserDefaults suite for \(testName)")
        return AppSettings()
    }

    defaults.removePersistentDomain(forName: suiteName)
    return AppSettings(defaults: defaults)
}
