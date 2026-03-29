//
//  OverviewWindowController.swift
//  FastMissionControl
//
//  Created by Codex.
//

import AppKit

@MainActor
final class OverviewWindowController {
    private var panelControllers: [OverviewDisplayPanelController] = []
    private let primaryDisplayID: CGDirectDisplayID?
    private let onDismiss: () -> Void
    private let onHoverChanged: (CGWindowID?) -> Void
    private let onMouseMoving: (Bool) -> Void
    private var hoveredWindowID: CGWindowID?
    private var hasDismissed = false
    private var mouseIdleTimer: Timer?
    private var isMouseMoving = false

    init(
        snapshot: OverviewSnapshot,
        onDismiss: @escaping () -> Void,
        onHoverChanged: @escaping (CGWindowID?) -> Void,
        onMouseMoving: @escaping (Bool) -> Void,
        onInteractionChanged: @escaping (Bool) -> Void,
        onWindowSelected: @escaping (WindowDescriptor, Bool) -> Void,
        onShelfItemSelected: @escaping (AppShelfItem) -> Void,
        onDesktopRequested: @escaping () -> Void,
        onNewWindowSelected: @escaping (CGWindowID, pid_t) -> Void
    ) {
        self.onDismiss = onDismiss
        self.onHoverChanged = onHoverChanged
        self.onMouseMoving = onMouseMoving

        let primaryDisplayID = snapshot.cursorDisplayID ?? snapshot.displays.first?.id
        self.primaryDisplayID = primaryDisplayID

        panelControllers = snapshot.displays.map { display in
            OverviewDisplayPanelController(
                display: display,
                snapshot: snapshot,
                showsShelf: display.id == primaryDisplayID,
                onHoverChanged: { [weak self] windowID in
                    self?.setHoveredWindow(windowID)
                },
                onMouseActivity: { [weak self] in
                    self?.broadcastMouseActivity()
                },
                onBackgroundClick: { [weak self] in
                    self?.close()
                },
                onWindowSelected: onWindowSelected,
                onShelfItemSelected: onShelfItemSelected,
                onDesktopRequested: onDesktopRequested,
                onNewWindowSelected: onNewWindowSelected,
                onInteractionChanged: onInteractionChanged
            )
        }

        for panelController in panelControllers {
            panelController.escapeHandler = { [weak self] in
                self?.close()
            }
        }
    }

    func show(duration: CFTimeInterval) {
        NSApp.activate(ignoringOtherApps: true)

        for panelController in panelControllers {
            panelController.show(makeKey: panelController.display.id == primaryDisplayID)
        }

        expand(duration: duration)
        promotePanelUnderCursor()
    }

    /// The overlay under the mouse must be key so `mouseMoved` delivers reliably on
    /// multi-monitor setups (otherwise only the primary panel receives hover updates).
    private func promotePanelUnderCursor() {
        let mouseLocation = NSEvent.mouseLocation
        for panelController in panelControllers {
            guard let frame = panelController.window?.frame, frame.contains(mouseLocation) else {
                continue
            }
            panelController.window?.makeKeyAndOrderFront(nil)
            return
        }
    }

    /// Cleans up a pre-built controller that was never shown, without
    /// firing the onDismiss callback.
    func disposePrewarmed() {
        for panelController in panelControllers {
            panelController.close()
        }
        panelControllers = []
    }

    func hideImmediately() {
        for panelController in panelControllers {
            panelController.hideImmediately()
        }
    }

    func close() {
        guard !hasDismissed else {
            return
        }

        hasDismissed = true
        mouseIdleTimer?.invalidate()
        mouseIdleTimer = nil
        setHoveredWindow(nil)
        onDismiss()

        for panelController in panelControllers {
            panelController.close()
        }
    }

    // MARK: - Live inventory updates

    func markWindowGone(_ windowID: CGWindowID) {
        for panelController in panelControllers {
            panelController.markWindowGone(windowID)
        }
    }

    func markWindowRestored(_ windowID: CGWindowID) {
        for panelController in panelControllers {
            panelController.markWindowRestored(windowID)
        }
    }

    func addNewWindowIcons(_ icons: [(windowID: CGWindowID, pid: pid_t, appName: String, icon: NSImage)]) {
        guard let primary = panelControllers.first(where: { $0.display.id == primaryDisplayID }) else { return }
        primary.addNewWindowIcons(icons)
    }

    private func expand(duration: CFTimeInterval) {
        for panelController in panelControllers {
            panelController.expand(duration: duration)
        }
    }

    func animateDismiss(selectedWindowID: CGWindowID?, duration: CFTimeInterval) {
        for panelController in panelControllers {
            panelController.animateDismiss(selectedWindowID: selectedWindowID, duration: duration)
        }
    }

    func setPreviewUpdatesSuspended(_ suspended: Bool) {
        for panelController in panelControllers {
            panelController.setPreviewUpdatesSuspended(suspended)
        }
    }

    private func broadcastMouseActivity() {
        for panelController in panelControllers {
            panelController.notifyMouseActivity()
        }

        mouseIdleTimer?.invalidate()
        if !isMouseMoving {
            isMouseMoving = true
            onMouseMoving(true)
        }
        mouseIdleTimer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isMouseMoving = false
                self.onMouseMoving(false)
            }
        }
    }

    private func setHoveredWindow(_ windowID: CGWindowID?) {
        guard hoveredWindowID != windowID else {
            return
        }

        hoveredWindowID = windowID
        onHoverChanged(windowID)

        for panelController in panelControllers {
            panelController.setHoveredWindow(windowID)
        }
    }
}

@MainActor
private final class OverviewDisplayPanelController: NSWindowController, NSWindowDelegate {
    let display: DisplayOverview

    var escapeHandler: (() -> Void)?

    private let overlayView: OverviewDisplayView

    init(
        display: DisplayOverview,
        snapshot: OverviewSnapshot,
        showsShelf: Bool,
        onHoverChanged: @escaping (CGWindowID?) -> Void,
        onMouseActivity: @escaping () -> Void,
        onBackgroundClick: @escaping () -> Void,
        onWindowSelected: @escaping (WindowDescriptor, Bool) -> Void,
        onShelfItemSelected: @escaping (AppShelfItem) -> Void,
        onDesktopRequested: @escaping () -> Void,
        onNewWindowSelected: @escaping (CGWindowID, pid_t) -> Void,
        onInteractionChanged: @escaping (Bool) -> Void
    ) {
        self.display = display
        overlayView = OverviewDisplayView(
            display: display,
            snapshot: snapshot,
            showsShelf: showsShelf
        )

        let panel = OverviewPanel(
            contentRect: display.windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Sit just below the Dock so the Dock stays visible above us.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        panel.hasShadow = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true

        super.init(window: panel)

        panel.delegate = self
        panel.escapeHandler = { [weak self] in
            self?.escapeHandler?()
        }

        overlayView.frame = CGRect(origin: .zero, size: display.localFrame.size)
        overlayView.autoresizingMask = [.width, .height]
        overlayView.onHoverChanged = onHoverChanged
        overlayView.onMouseActivity = onMouseActivity
        overlayView.onBackgroundClick = onBackgroundClick
        overlayView.onWindowSelected = onWindowSelected
        overlayView.onShelfItemSelected = onShelfItemSelected
        overlayView.onDesktopRequested = onDesktopRequested
        overlayView.onNewWindowSelected = onNewWindowSelected
        overlayView.onInteractionChanged = onInteractionChanged
        panel.contentView = overlayView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show(makeKey: Bool) {
        guard let panel = window as? OverviewPanel else {
            return
        }

        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true

        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }
    }

    func expand(duration: CFTimeInterval) {
        overlayView.expand(duration: duration)
    }

    func setHoveredWindow(_ windowID: CGWindowID?) {
        overlayView.setHoveredWindow(windowID)
    }

    func notifyMouseActivity() {
        overlayView.notifyMouseActivity()
    }

    func markWindowGone(_ windowID: CGWindowID) {
        overlayView.markWindowGone(windowID)
    }

    func markWindowRestored(_ windowID: CGWindowID) {
        overlayView.markWindowRestored(windowID)
    }

    func addNewWindowIcons(_ icons: [(windowID: CGWindowID, pid: pid_t, appName: String, icon: NSImage)]) {
        overlayView.addNewWindowIcons(icons)
    }

    func hideImmediately() {
        guard let panel = window as? OverviewPanel else {
            return
        }

        overlayView.disableInteractions()
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    func animateDismiss(selectedWindowID: CGWindowID?, duration: CFTimeInterval) {
        guard let panel = window as? OverviewPanel else {
            return
        }

        overlayView.animateDismiss(selectedWindowID: selectedWindowID, duration: duration)
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.95, 0.05, 0.795, 0.035)
            panel.animator().alphaValue = 0
        }
    }

    func setPreviewUpdatesSuspended(_ suspended: Bool) {
        overlayView.setPreviewUpdatesSuspended(suspended)
    }

    override func close() {
        overlayView.close()
        window?.delegate = nil
        super.close()
    }
}

private final class OverviewPanel: NSPanel {
    var escapeHandler: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            escapeHandler?()
            return
        }

        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        escapeHandler?()
    }
}
