//
//  OverviewWindowController.swift
//  FastMissionControl
//
//  Created by Codex.
//

import AppKit
import Carbon.HIToolbox

@MainActor
final class OverviewWindowController {
    private var panelControllers: [OverviewDisplayPanelController] = []
    private let primaryDisplayID: CGDirectDisplayID?
    private let onDismiss: () -> Void
    private let onHoverChanged: (CGWindowID?) -> Void
    private let onMouseMoving: (Bool) -> Void
    private let onWindowSelected: (WindowDescriptor, Bool) -> Void
    private let onWindowCloseRequested: (WindowDescriptor) -> Void
    private let allWindowDescriptors: [WindowDescriptor]
    private let snapshot: OverviewSnapshot
    private let layoutEngine: SpatialOverviewLayout
    /// AND vs OR for multi-word filtering and whether non-matches dim in place or are hidden by a
    /// re-layout. Captured at open from settings.
    private let matchAllWords: Bool
    private let hideNonMatches: Bool
    private var goneWindowIDs: Set<CGWindowID> = []
    private var hoveredWindowID: CGWindowID?
    private var selectedWindowID: CGWindowID?
    private var filterText: String = ""
    private var hasDismissed = false
    private var mouseIdleTimer: Timer?
    private var isMouseMoving = false

    init(
        snapshot: OverviewSnapshot,
        layoutEngine: SpatialOverviewLayout,
        matchAllWords: Bool,
        hideNonMatches: Bool,
        usesMergedTitleStyle: Bool,
        onDismiss: @escaping () -> Void,
        onHoverChanged: @escaping (CGWindowID?) -> Void,
        onMouseMoving: @escaping (Bool) -> Void,
        onInteractionChanged: @escaping (Bool) -> Void,
        onWindowSelected: @escaping (WindowDescriptor, Bool) -> Void,
        onWindowCloseRequested: @escaping (WindowDescriptor) -> Void,
        onShelfItemSelected: @escaping (AppShelfItem) -> Void,
        onDesktopRequested: @escaping () -> Void,
        onNewWindowSelected: @escaping (CGWindowID, pid_t) -> Void
    ) {
        self.onDismiss = onDismiss
        self.onHoverChanged = onHoverChanged
        self.onMouseMoving = onMouseMoving
        self.onWindowSelected = onWindowSelected
        self.onWindowCloseRequested = onWindowCloseRequested
        self.allWindowDescriptors = snapshot.windows
        self.snapshot = snapshot
        self.layoutEngine = layoutEngine
        self.matchAllWords = matchAllWords
        self.hideNonMatches = hideNonMatches

        let primaryDisplayID = snapshot.cursorDisplayID ?? snapshot.displays.first?.id
        self.primaryDisplayID = primaryDisplayID

        panelControllers = snapshot.displays.map { display in
            OverviewDisplayPanelController(
                display: display,
                snapshot: snapshot,
                showsShelf: display.id == primaryDisplayID,
                usesMergedTitleStyle: usesMergedTitleStyle,
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
                onWindowCloseRequested: onWindowCloseRequested,
                onSearchTextChanged: { [weak self] text in
                    self?.applyFilterTextFromSearchField(text)
                },
                onSearchCommand: { [weak self] selector in
                    self?.handleSearchFieldCommand(selector) ?? false
                },
                onShelfItemSelected: onShelfItemSelected,
                onDesktopRequested: onDesktopRequested,
                onNewWindowSelected: onNewWindowSelected,
                onInteractionChanged: onInteractionChanged
            )
        }

        for panelController in panelControllers {
            panelController.keyHandler = { [weak self] event in
                self?.handleKey(event) ?? false
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
        initializeSelection()
    }

    private func initializeSelection() {
        // Topmost-leftmost window in reading order — matches the Tab cycle so initial selection
        // lands where Tab would.
        guard let first = readingOrderCandidates().first else {
            return
        }
        setSelectedWindow(first.id)
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
        guard !goneWindowIDs.contains(windowID) else { return }
        goneWindowIDs.insert(windowID)

        let matching = matchingWindowIDs()
        let remaining = layoutWindows(matching: matching)
        recomputeLayout(for: remaining)
        for panelController in panelControllers {
            panelController.animateRelayout(closedWindowID: windowID, duration: 0.28)
            if hideNonMatches {
                panelController.applyHideFilter(
                    visibleWindowIDs: Set(remaining.map(\.id)),
                    displayText: filterText
                )
            }
        }

        // If the focused window vanished, move focus to another candidate.
        if selectedWindowID == windowID {
            setSelectedWindow(candidateWindows().min(by: { $0.zIndex < $1.zIndex })?.id)
        }
    }

    func markWindowRestored(_ windowID: CGWindowID) {
        guard goneWindowIDs.remove(windowID) != nil else { return }

        for panelController in panelControllers {
            panelController.markWindowRestored(windowID)
        }

        let matching = matchingWindowIDs()
        let remaining = layoutWindows(matching: matching)
        recomputeLayout(for: remaining)

        for panelController in panelControllers {
            if hideNonMatches {
                panelController.applyHideFilter(
                    visibleWindowIDs: Set(remaining.map(\.id)),
                    displayText: filterText
                )
            } else {
                panelController.animateRelayout(duration: 0.28)
                panelController.setFilter(matchingWindowIDs: matching, displayText: filterText)
            }
        }
    }

    // MARK: - Keyboard

    /// Returns true when the event was handled by the overview (and should not propagate).
    private func handleKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:
            if !filterText.isEmpty {
                setFilterText("")
                return true
            }
            close()
            return true
        case kVK_LeftArrow: navigate(direction: .left); return true
        case kVK_RightArrow: navigate(direction: .right); return true
        case kVK_UpArrow: navigate(direction: .up); return true
        case kVK_DownArrow: navigate(direction: .down); return true
        case kVK_Tab:
            cycleSelection(reverse: event.modifierFlags.contains(.shift))
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            activateSelected(slowAnimation: event.modifierFlags.contains(.shift))
            return true
        case kVK_Space:
            // Outside a filter, Space activates the focused window; mid-filter it's a filter token.
            if filterText.isEmpty {
                activateSelected(slowAnimation: event.modifierFlags.contains(.shift))
                return true
            }
            return appendPrintableCharacters(from: event)
        case kVK_Delete:
            if !filterText.isEmpty {
                setFilterText(String(filterText.dropLast()))
                return true
            }
            return false
        default:
            return appendPrintableCharacters(from: event)
        }
    }

    private func cycleSelection(reverse: Bool) {
        let candidates = readingOrderCandidates()
        guard !candidates.isEmpty else { return }
        guard let currentID = selectedWindowID,
              let currentIndex = candidates.firstIndex(where: { $0.id == currentID }) else {
            setSelectedWindow(candidates.first?.id)
            return
        }
        let count = candidates.count
        let nextIndex = reverse
            ? (currentIndex - 1 + count) % count
            : (currentIndex + 1) % count
        setSelectedWindow(candidates[nextIndex].id)
    }

    /// Visual reading order — top-to-bottom rows, left-to-right within each row.
    private func readingOrderCandidates() -> [WindowDescriptor] {
        let candidates = candidateWindows()
        guard !candidates.isEmpty else { return [] }

        let rowBucket: CGFloat = 60
        return candidates.sorted { lhs, rhs in
            let lhsRow = Int(lhs.targetFrame.midY / rowBucket)
            let rhsRow = Int(rhs.targetFrame.midY / rowBucket)
            if lhsRow != rhsRow { return lhsRow < rhsRow }
            return lhs.targetFrame.midX < rhs.targetFrame.midX
        }
    }

    // MARK: - Search field input

    /// User typed into (or pasted into) the SearchPillView's editable text field — push the new
    /// text through the same filter pipeline the keyboard path uses.
    private func applyFilterTextFromSearchField(_ text: String) {
        guard filterText != text else { return }
        setFilterText(text)
    }

    /// Intercepts the field editor's commands so the overlay's keyboard semantics still apply
    /// while the user is typing in the search field. After handling, the field is defocused so
    /// Space activation resumes working — matching the type → see → navigate flow.
    private func handleSearchFieldCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveLeft(_:)): navigate(direction: .left)
        case #selector(NSResponder.moveRight(_:)): navigate(direction: .right)
        case #selector(NSResponder.moveUp(_:)): navigate(direction: .up)
        case #selector(NSResponder.moveDown(_:)): navigate(direction: .down)
        case #selector(NSResponder.insertTab(_:)): cycleSelection(reverse: false)
        case #selector(NSResponder.insertBacktab(_:)): cycleSelection(reverse: true)
        case #selector(NSResponder.insertNewline(_:)):
            activateSelected(slowAnimation: NSEvent.modifierFlags.contains(.shift))
        case #selector(NSResponder.cancelOperation(_:)):
            if !filterText.isEmpty {
                setFilterText("")
            } else {
                close()
            }
        default:
            return false
        }
        resignAllSearchFocus()
        return true
    }

    private func resignAllSearchFocus() {
        for panelController in panelControllers {
            panelController.resignSearchFocus()
        }
    }

    private func appendPrintableCharacters(from event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Ignore command/control combos — those are not filter input.
        guard !modifiers.contains(.command), !modifiers.contains(.control) else {
            return false
        }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return false
        }
        let allowed = characters.filter { character in
            character.isLetter || character.isNumber || character == " "
        }
        guard !allowed.isEmpty else { return false }
        setFilterText(filterText + allowed)
        return true
    }

    private func setFilterText(_ text: String) {
        filterText = text
        let matching = matchingWindowIDs()

        if hideNonMatches {
            applyHideLayout(matching: matching, displayText: text)
        } else {
            for panelController in panelControllers {
                panelController.setFilter(matchingWindowIDs: matching, displayText: text)
            }
        }

        // Re-anchor selection to a still-matching window.
        if let selectedWindowID,
           let matching,
           !matching.contains(selectedWindowID) {
            let next = candidateWindows().min(by: { $0.zIndex < $1.zIndex })
            setSelectedWindow(next?.id)
        } else if selectedWindowID == nil {
            let next = candidateWindows().min(by: { $0.zIndex < $1.zIndex })
            if next != nil {
                setSelectedWindow(next?.id)
            }
        }
    }

    /// Hide mode: re-layout only the matching windows so they fill the freed space, then animate
    /// the survivors to their new frames while the non-matching cards fade out.
    private func applyHideLayout(matching: Set<CGWindowID>?, displayText: String) {
        let visible = layoutWindows(matching: matching)
        recomputeLayout(for: visible)

        let visibleIDs = Set(visible.map(\.id))
        for panelController in panelControllers {
            panelController.applyHideFilter(visibleWindowIDs: visibleIDs, displayText: displayText)
        }
    }

    private func recomputeLayout(for windows: [WindowDescriptor]) {
        guard !windows.isEmpty else { return }
        let relayoutSnapshot = OverviewSnapshot(
            windowFrame: snapshot.windowFrame,
            canvasSize: snapshot.canvasSize,
            displays: snapshot.displays,
            windows: windows,
            shelfItems: snapshot.shelfItems,
            cursorDisplayID: snapshot.cursorDisplayID,
            livePreviewLimit: snapshot.livePreviewLimit
        )
        layoutEngine.apply(to: relayoutSnapshot)
    }

    private func candidateWindows() -> [WindowDescriptor] {
        let tokens = filterTokens(filterText)
        return allWindowDescriptors.filter { descriptor in
            guard !goneWindowIDs.contains(descriptor.id) else { return false }
            return windowMatches(descriptor, tokens: tokens)
        }
    }

    private func matchingWindowIDs() -> Set<CGWindowID>? {
        let tokens = filterTokens(filterText)
        guard !tokens.isEmpty else { return nil }
        return Set(allWindowDescriptors.filter { windowMatches($0, tokens: tokens) }.map(\.id))
    }

    private func layoutWindows(matching: Set<CGWindowID>?) -> [WindowDescriptor] {
        allWindowDescriptors.filter { descriptor in
            guard !goneWindowIDs.contains(descriptor.id) else { return false }
            return !hideNonMatches || matching == nil || matching?.contains(descriptor.id) == true
        }
    }

    private func filterTokens(_ text: String) -> [String] {
        text.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// A window matches when, depending on the Match-All-Words setting, every token appears (AND)
    /// or any token appears (OR) in its app name or title. No tokens → matches.
    private func windowMatches(_ descriptor: WindowDescriptor, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let haystack = "\(descriptor.appName) \(descriptor.title ?? "")".lowercased()
        return matchAllWords
            ? tokens.allSatisfy { haystack.contains($0) }
            : tokens.contains { haystack.contains($0) }
    }

    private enum NavDirection { case left, right, up, down }

    private func navigate(direction: NavDirection) {
        let candidates = candidateWindows()
        guard !candidates.isEmpty else { return }

        guard let currentID = selectedWindowID,
              let current = candidates.first(where: { $0.id == currentID }) else {
            setSelectedWindow(candidates.min(by: { $0.zIndex < $1.zIndex })?.id)
            return
        }

        let currentCenter = navigationCenter(for: current)

        var best: (descriptor: WindowDescriptor, score: CGFloat)?
        for candidate in candidates where candidate.id != current.id {
            let candidateCenter = navigationCenter(for: candidate)
            let dx = candidateCenter.x - currentCenter.x
            let dy = candidateCenter.y - currentCenter.y

            let primaryAxisDelta: CGFloat
            let perpendicularDelta: CGFloat
            switch direction {
            case .left:
                primaryAxisDelta = -dx
                perpendicularDelta = abs(dy)
            case .right:
                primaryAxisDelta = dx
                perpendicularDelta = abs(dy)
            case .up:
                primaryAxisDelta = -dy
                perpendicularDelta = abs(dx)
            case .down:
                primaryAxisDelta = dy
                perpendicularDelta = abs(dx)
            }

            // Must lie in the half-plane in the direction of travel.
            guard primaryAxisDelta > 1 else { continue }

            let score = primaryAxisDelta + perpendicularDelta * 1.5
            if best == nil || score < best!.score {
                best = (candidate, score)
            }
        }

        if let best {
            setSelectedWindow(best.descriptor.id)
        }
    }

    /// Nav uses the thumbnail's position in the overview canvas, not the original on-screen window
    /// position — three windows shown side-by-side in the overview can come from anywhere on screen.
    /// `targetFrame` uses flipped (top-origin) coordinates so "down" means larger y.
    private func navigationCenter(for descriptor: WindowDescriptor) -> CGPoint {
        CGPoint(x: descriptor.targetFrame.midX, y: descriptor.targetFrame.midY)
    }

    private func setSelectedWindow(_ windowID: CGWindowID?) {
        guard selectedWindowID != windowID else { return }
        selectedWindowID = windowID
        for panelController in panelControllers {
            panelController.setKeyboardSelectedWindow(windowID)
        }
        if let windowID {
            onHoverChanged(windowID)
        }
    }

    private func activateSelected(slowAnimation: Bool) {
        guard let windowID = selectedWindowID,
              let descriptor = allWindowDescriptors.first(where: { $0.id == windowID }),
              !goneWindowIDs.contains(windowID) else {
            return
        }
        onWindowSelected(descriptor, slowAnimation)
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

        // When the mouse moves onto a card, that card becomes the keyboard nav anchor too. We don't
        // clear the anchor when the mouse moves off all cards — keyboard nav should be able to
        // resume from the last focused window without the user re-hovering it.
        if let windowID {
            selectedWindowID = windowID
        }

    }
}

@MainActor
private final class OverviewDisplayPanelController: NSWindowController, NSWindowDelegate {
    let display: DisplayOverview

    var keyHandler: ((NSEvent) -> Bool)?

    private let overlayView: OverviewDisplayView

    init(
        display: DisplayOverview,
        snapshot: OverviewSnapshot,
        showsShelf: Bool,
        usesMergedTitleStyle: Bool,
        onHoverChanged: @escaping (CGWindowID?) -> Void,
        onMouseActivity: @escaping () -> Void,
        onBackgroundClick: @escaping () -> Void,
        onWindowSelected: @escaping (WindowDescriptor, Bool) -> Void,
        onWindowCloseRequested: @escaping (WindowDescriptor) -> Void,
        onSearchTextChanged: @escaping (String) -> Void,
        onSearchCommand: @escaping (Selector) -> Bool,
        onShelfItemSelected: @escaping (AppShelfItem) -> Void,
        onDesktopRequested: @escaping () -> Void,
        onNewWindowSelected: @escaping (CGWindowID, pid_t) -> Void,
        onInteractionChanged: @escaping (Bool) -> Void
    ) {
        self.display = display
        overlayView = OverviewDisplayView(
            display: display,
            snapshot: snapshot,
            showsShelf: showsShelf,
            usesMergedTitleStyle: usesMergedTitleStyle
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
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == UInt32(display.id)
        }) {
            panel.colorSpace = screen.colorSpace
        }

        super.init(window: panel)

        panel.delegate = self
        panel.keyHandler = { [weak self] event in
            self?.keyHandler?(event) ?? false
        }

        overlayView.frame = CGRect(origin: .zero, size: display.localFrame.size)
        overlayView.autoresizingMask = [.width, .height]
        overlayView.onHoverChanged = onHoverChanged
        overlayView.onMouseActivity = onMouseActivity
        overlayView.onBackgroundClick = onBackgroundClick
        overlayView.onWindowSelected = onWindowSelected
        overlayView.onWindowCloseRequested = onWindowCloseRequested
        overlayView.onSearchTextChanged = onSearchTextChanged
        overlayView.onSearchCommand = onSearchCommand
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

    func setKeyboardSelectedWindow(_ windowID: CGWindowID?) {
        overlayView.setKeyboardSelectedWindow(windowID)
    }

    func setFilter(matchingWindowIDs: Set<CGWindowID>?, displayText: String) {
        overlayView.setFilter(matchingWindowIDs: matchingWindowIDs, displayText: displayText)
    }

    func applyHideFilter(visibleWindowIDs: Set<CGWindowID>, displayText: String) {
        overlayView.applyHideFilter(visibleWindowIDs: visibleWindowIDs, displayText: displayText)
    }

    func resignSearchFocus() {
        overlayView.resignSearchFocus()
    }

    func notifyMouseActivity() {
        overlayView.notifyMouseActivity()
    }

    func animateRelayout(closedWindowID: CGWindowID, duration: CFTimeInterval) {
        overlayView.animateRelayout(closedWindowID: closedWindowID, duration: duration)
    }

    func animateRelayout(duration: CFTimeInterval) {
        overlayView.animateRelayout(duration: duration)
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
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true {
            return
        }

        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        // Escape — synthesize a keyDown so it flows through the same handler as other keys.
        if let event = NSApp.currentEvent, event.type == .keyDown {
            _ = keyHandler?(event)
        }
    }
}
