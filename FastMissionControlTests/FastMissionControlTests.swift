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

        SpatialOverviewLayout().apply(to: snapshot)

        let centerXs = windows.map(\.targetFrame.midX)
        let spanX = (centerXs.max() ?? 0) - (centerXs.min() ?? 0)
        #expect(spanX > 300)

        let coarseColumns = Set(centerXs.map { Int(($0 / 50).rounded()) })
        #expect(coarseColumns.count >= 2)
    }

}
