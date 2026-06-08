//
//  MenuBarController.swift
//  FastMissionControl
//

import AppKit

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let onOpenOverview: () -> Void
    private let onOpenSettings: () -> Void

    init(onOpenOverview: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.onOpenOverview = onOpenOverview
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "square.grid.2x2",
                accessibilityDescription: "Fast Mission Control"
            )
            button.toolTip = "Fast Mission Control"
        }

        buildMenu()
        statusItem.menu = menu
    }

    private func buildMenu() {
        let openOverview = NSMenuItem(
            title: "Open Overview",
            action: #selector(handleOpenOverview),
            keyEquivalent: ""
        )
        openOverview.target = self
        menu.addItem(openOverview)

        let openSettings = NSMenuItem(
            title: "Settings…",
            action: #selector(handleOpenSettings),
            keyEquivalent: ","
        )
        openSettings.target = self
        menu.addItem(openSettings)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit Fast Mission Control",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    @objc
    private func handleOpenOverview() {
        onOpenOverview()
    }

    @objc
    private func handleOpenSettings() {
        onOpenSettings()
    }

    @objc
    private func handleQuit() {
        NSApp.terminate(nil)
    }
}
