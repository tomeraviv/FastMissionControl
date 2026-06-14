//
//  MenuBarController.swift
//  FastMissionControl
//

import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let onOpenOverview: () -> Void
    private let onOpenSettings: () -> Void
    private let isLaunchAtLoginEnabled: () -> Bool
    private let onLaunchAtLoginChanged: (Bool) -> Void
    private let launchAtLoginItem = NSMenuItem()

    init(
        onOpenOverview: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        isLaunchAtLoginEnabled: @escaping () -> Bool,
        onLaunchAtLoginChanged: @escaping (Bool) -> Void
    ) {
        self.onOpenOverview = onOpenOverview
        self.onOpenSettings = onOpenSettings
        self.isLaunchAtLoginEnabled = isLaunchAtLoginEnabled
        self.onLaunchAtLoginChanged = onLaunchAtLoginChanged
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "square.grid.2x2",
                accessibilityDescription: "Fast Mission Control"
            )
            button.toolTip = "Fast Mission Control"
        }

        buildMenu()
        menu.delegate = self
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

        launchAtLoginItem.action = #selector(handleLaunchAtLogin)
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit Fast Mission Control",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        let enabled = isLaunchAtLoginEnabled()
        launchAtLoginItem.title = "Launch at Login"
        launchAtLoginItem.state = enabled ? .on : .off
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
    private func handleLaunchAtLogin() {
        onLaunchAtLoginChanged(!isLaunchAtLoginEnabled())
    }

    @objc
    private func handleQuit() {
        NSApp.terminate(nil)
    }
}
