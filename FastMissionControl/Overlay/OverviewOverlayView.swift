//
//  OverviewOverlayView.swift
//  FastMissionControl
//
//  Created by Codex.
//

import AppKit
import Combine
import QuartzCore
import ScreenCaptureKit

private struct WallpaperCacheKey: Hashable {
    let displayID: CGDirectDisplayID
    let wallpaperURL: URL
    let frame: CGRect
    let appearanceName: String
}

private struct ResolvedWallpaper {
    let url: URL
    let cacheKey: WallpaperCacheKey
    let wallpaperWindowID: CGWindowID?
    let captureSize: CGSize
    let scale: CGFloat
    let colorSpaceName: String?
    let supportsEDR: Bool
}

@MainActor
final class OverviewDisplayView: NSView {
    var onHoverChanged: ((CGWindowID?) -> Void)?
    var onBackgroundClick: (() -> Void)?
    var onWindowSelected: ((WindowDescriptor, Bool) -> Void)?
    var onWindowCloseRequested: ((WindowDescriptor) -> Void)?
    var onCloseConfirmationDecided: ((Bool) -> Void)?
    var onSearchTextChanged: ((String) -> Void)?
    var onSearchCommand: ((Selector) -> Bool)?
    var onShelfItemSelected: ((AppShelfItem) -> Void)?
    var onDesktopRequested: (() -> Void)?
    var onNewWindowSelected: ((CGWindowID, pid_t) -> Void)?
    /// True while the user is dragging a window card (live previews pause to keep input smooth).
    var onInteractionChanged: ((Bool) -> Void)?
    var onMouseActivity: (() -> Void)?

    private let display: DisplayOverview
    private let snapshot: OverviewSnapshot
    private let showsShelf: Bool
    private let displayOrigin: CGPoint
    private let displaySupportsEDR: Bool
    private let windowDescriptors: [WindowDescriptor]

    private let wallpaperLayer = CALayer()
    private let backgroundDimLayer = CALayer()
    private var cardLayers: [CGWindowID: WindowCardLayer] = [:]
    private var titleLayers: [CGWindowID: WindowTitleLayer] = [:]
    private var previewObservers: [CGWindowID: AnyCancellable] = [:]
    private var pendingPreviewUpdateWindowIDs: Set<CGWindowID> = []
    private var shelfButtons: [ShelfItemButton] = []
    private var newWindowButtons: [NewWindowButton] = []
    private var desktopButton: DesktopButton?
    private var trackingAreaRef: NSTrackingArea?
    private var hoveredWindowID: CGWindowID?
    private var isExpanded = false
    /// Mid-open, the title chip and card body sit in different places, so the focus halo would
    /// render split. Suppress halo updates until the open animation lands.
    private var hasFinishedExpanding = false
    private var mouseIdleTimer: Timer?
    private var goneWindowIDs: Set<CGWindowID> = []
    private var previewUpdatesSuspended = false
    private var filterMatchingWindowIDs: Set<CGWindowID>?
    /// When true, non-matching cards are hidden (and skipped for hit-testing) rather than dimmed.
    private var filterHidesNonMatches = false
    private var searchPill: SearchPillView?
    private var confirmationChip: ConfirmationChipView?
    private var confirmationDescriptor: WindowDescriptor?
    /// Window hit on mouseDown; selection runs on mouseUp only when no drag occurred.
    private var pendingWindowSelect: WindowDescriptor?
    private var pendingCloseDescriptor: WindowDescriptor?
    private var pendingWindowSelectOrigin: CGPoint?
    private var pendingWindowSelectDidDrag = false
    private var lastDragLocalPoint: CGPoint?
    private var dragSavedCardZ: CGFloat?
    private var dragSavedTitleZ: CGFloat?
    private let pendingWindowSelectDragThreshold: CGFloat = 5

    override var isFlipped: Bool {
        true
    }

    init(
        display: DisplayOverview,
        snapshot: OverviewSnapshot,
        showsShelf: Bool
    ) {
        self.display = display
        self.snapshot = snapshot
        self.showsShelf = showsShelf
        displayOrigin = display.localFrame.origin
        displaySupportsEDR = (Self.screen(for: display.id)?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        windowDescriptors = snapshot.windows
            .filter { $0.displayID == display.id }
            .sorted { lhs, rhs in
                lhs.zIndex < rhs.zIndex
            }

        super.init(frame: CGRect(origin: .zero, size: display.localFrame.size))

        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        if displaySupportsEDR {
            layer?.contentsFormat = .RGBA16Float
            layer?.wantsExtendedDynamicRangeContent = true
        }

        // Desktop wallpaper as backdrop (loaded async to avoid blocking open).
        wallpaperLayer.contentsGravity = .resizeAspectFill
        wallpaperLayer.frame = CGRect(origin: .zero, size: display.localFrame.size)
        wallpaperLayer.zPosition = -2
        wallpaperLayer.opacity = 0
        if displaySupportsEDR {
            wallpaperLayer.contentsFormat = .RGBA16Float
            wallpaperLayer.wantsExtendedDynamicRangeContent = true
        }
        // Try cache first (instant on 2nd+ open), else load async.
        if let wallpaper = Self.resolveWallpaper(for: display.id),
           let cached = Self.wallpaperCache[wallpaper.cacheKey] {
            wallpaperLayer.contents = cached
        } else {
            loadWallpaperAsync()
        }
        layer?.addSublayer(wallpaperLayer)

        // Semi-transparent dim over the wallpaper.
        backgroundDimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
        backgroundDimLayer.frame = CGRect(origin: .zero, size: display.localFrame.size)
        backgroundDimLayer.zPosition = -1
        backgroundDimLayer.opacity = 0
        layer?.addSublayer(backgroundDimLayer)

        buildWindowLayers()
        buildShelfButtonsIfNeeded()
        buildDesktopButtonIfNeeded()
        buildSearchPillIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    // MARK: - NSView overrides

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingAreaRef = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaRef)
        self.trackingAreaRef = trackingAreaRef
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
        wallpaperLayer.frame = bounds
        backgroundDimLayer.frame = bounds
        layoutBottomRow()
        layoutSearchPill()
        layoutConfirmationChip()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isExpanded else {
            return
        }
        // Non-key overlay panels often stop receiving `mouseMoved` on secondary displays.
        window?.makeKeyAndOrderFront(nil)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isExpanded else {
            return
        }

        setHoveredWindow(hitTestWindow(at: convert(event.locationInWindow, from: nil))?.id)
        onMouseActivity?()
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredWindow(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)

        guard isExpanded else {
            return
        }

        if let descriptor = hitTestCloseButton(at: localPoint) {
            pendingCloseDescriptor = descriptor
            pendingWindowSelect = nil
            pendingWindowSelectOrigin = nil
            pendingWindowSelectDidDrag = false
            lastDragLocalPoint = nil
            return
        }

        if let descriptor = hitTestWindow(at: localPoint) {
            pendingWindowSelect = descriptor
            pendingWindowSelectOrigin = localPoint
            pendingWindowSelectDidDrag = false
            lastDragLocalPoint = nil
            dragSavedCardZ = nil
            dragSavedTitleZ = nil
            return
        }

        pendingWindowSelect = nil
        pendingWindowSelectOrigin = nil
        pendingWindowSelectDidDrag = false
        lastDragLocalPoint = nil
        dragSavedCardZ = nil
        dragSavedTitleZ = nil
        onBackgroundClick?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isExpanded,
              let descriptor = pendingWindowSelect,
              !goneWindowIDs.contains(descriptor.id),
              pendingWindowSelectOrigin != nil
        else {
            return
        }

        let localPoint = convert(event.locationInWindow, from: nil)

        if !pendingWindowSelectDidDrag, let origin = pendingWindowSelectOrigin {
            let dx = localPoint.x - origin.x
            let dy = localPoint.y - origin.y
            if hypot(dx, dy) >= pendingWindowSelectDragThreshold {
                pendingWindowSelectDidDrag = true
                lastDragLocalPoint = localPoint
                onInteractionChanged?(true)
                bringDraggedWindowToFront(descriptor)
            }
            return
        }

        guard pendingWindowSelectDidDrag, let last = lastDragLocalPoint else {
            return
        }

        let ddx = localPoint.x - last.x
        let ddy = localPoint.y - last.y
        lastDragLocalPoint = localPoint
        guard ddx != 0 || ddy != 0 else {
            return
        }

        descriptor.targetFrame.origin.x += ddx
        descriptor.targetFrame.origin.y += ddy
        descriptor.titleBarFrame.origin.x += ddx
        descriptor.titleBarFrame.origin.y += ddy
        clampWindowFramesWithinBounds(descriptor)
        syncWindowLayerPositions(for: descriptor)
    }

    override func mouseUp(with event: NSEvent) {
        let didDrag = pendingWindowSelectDidDrag
        let descriptorForDrag = pendingWindowSelect
        let closeDescriptor = pendingCloseDescriptor

        defer {
            if didDrag {
                onInteractionChanged?(false)
            }
            if didDrag, let descriptor = descriptorForDrag {
                restoreDraggedWindowZOrder(for: descriptor)
            }
            pendingWindowSelect = nil
            pendingWindowSelectOrigin = nil
            pendingWindowSelectDidDrag = false
            lastDragLocalPoint = nil
            pendingCloseDescriptor = nil
        }

        guard isExpanded else { return }

        let localPoint = convert(event.locationInWindow, from: nil)

        // A press that began on the ✕ and ended on the same ✕ requests a close.
        if let closeDescriptor, hitTestCloseButton(at: localPoint)?.id == closeDescriptor.id {
            onWindowCloseRequested?(closeDescriptor)
            return
        }

        guard let descriptor = descriptorForDrag, !didDrag else {
            return
        }

        guard hitTestWindow(at: localPoint)?.id == descriptor.id else {
            return
        }

        onWindowSelected?(descriptor, event.modifierFlags.contains(.shift))
    }

    private func bringDraggedWindowToFront(_ descriptor: WindowDescriptor) {
        guard let card = cardLayers[descriptor.id], let title = titleLayers[descriptor.id] else {
            return
        }
        if dragSavedCardZ == nil {
            dragSavedCardZ = card.zPosition
            dragSavedTitleZ = title.zPosition
        }
        card.zPosition = 100_000
        title.zPosition = 100_001
    }

    private func restoreDraggedWindowZOrder(for descriptor: WindowDescriptor) {
        guard let card = cardLayers[descriptor.id], let title = titleLayers[descriptor.id] else {
            dragSavedCardZ = nil
            dragSavedTitleZ = nil
            return
        }
        if let zc = dragSavedCardZ, let zt = dragSavedTitleZ {
            card.zPosition = zc
            title.zPosition = zt
        }
        dragSavedCardZ = nil
        dragSavedTitleZ = nil
    }

    private func bringWindowToFrontForDismissal(_ windowID: CGWindowID) {
        restoreWindowZOrderForDismissal()

        guard let card = cardLayers[windowID], let title = titleLayers[windowID] else {
            return
        }

        card.zPosition = 200_000
        title.zPosition = 200_001
    }

    private func restoreWindowZOrderForDismissal() {
        for descriptor in windowDescriptors {
            guard let card = cardLayers[descriptor.id], let title = titleLayers[descriptor.id] else {
                continue
            }

            card.zPosition = CGFloat(10_000 - descriptor.zIndex)
            title.zPosition = CGFloat(20_000 - descriptor.zIndex)
        }
    }

    private func clampWindowFramesWithinBounds(_ descriptor: WindowDescriptor) {
        let localCard = descriptor.targetFrame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
        let localTitle = descriptor.titleBarFrame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
        let union = localCard.union(localTitle)
        let clamped = clampRect(union, into: bounds)
        let ddx = clamped.minX - union.minX
        let ddy = clamped.minY - union.minY
        guard ddx != 0 || ddy != 0 else {
            return
        }
        descriptor.targetFrame.origin.x += ddx
        descriptor.targetFrame.origin.y += ddy
        descriptor.titleBarFrame.origin.x += ddx
        descriptor.titleBarFrame.origin.y += ddy
    }

    private func clampRect(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var r = rect
        if r.width <= bounds.width {
            r.origin.x = min(max(r.origin.x, bounds.minX), bounds.maxX - r.width)
        } else {
            r.origin.x = bounds.minX
        }
        if r.height <= bounds.height {
            r.origin.y = min(max(r.origin.y, bounds.minY), bounds.maxY - r.height)
        } else {
            r.origin.y = bounds.minY
        }
        return r
    }

    private func syncWindowLayerPositions(for descriptor: WindowDescriptor) {
        guard let card = cardLayers[descriptor.id], let title = titleLayers[descriptor.id] else {
            return
        }
        let localTarget = descriptor.targetFrame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
        let localTitle = descriptor.titleBarFrame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.position = CGPoint(x: localTarget.midX, y: localTarget.midY)
        title.position = CGPoint(x: localTitle.midX, y: localTitle.midY)
        CATransaction.commit()
    }

    // MARK: - Expand / hover

    func expand(duration: CFTimeInterval) {
        guard !isExpanded else {
            return
        }

        isExpanded = true
        hasFinishedExpanding = false

        let titleDuration = max(duration * 1.15, 0)

        backgroundDimLayer.opacity = 1

        // Cap at 0.99 so macOS doesn't consider underlying windows fully occluded —
        // otherwise the compositor stops updating them and ScreenCaptureKit returns stale frames.
        wallpaperLayer.opacity = 0.99

        for titleLayer in titleLayers.values {
            titleLayer.animateToVisible(duration: titleDuration)
        }
        for cardLayer in cardLayers.values {
            cardLayer.animateToExpanded(duration: duration)
        }

        // Once the cards have landed at their target positions, applying the halo is safe.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(duration, 0)) { [weak self] in
            guard let self else { return }
            self.hasFinishedExpanding = true
            self.applyFocusHaloForCurrentState()
        }
    }

    func animateDismiss(selectedWindowID: CGWindowID?, duration: CFTimeInterval) {
        guard isExpanded else {
            return
        }

        isExpanded = false
        hasFinishedExpanding = false
        mouseIdleTimer?.invalidate()
        mouseIdleTimer = nil
        if let selectedWindowID {
            bringWindowToFrontForDismissal(selectedWindowID)
        }
        disableInteractions()

        for button in shelfButtons {
            button.isHidden = true
        }
        for button in newWindowButtons {
            button.isHidden = true
        }
        desktopButton?.isHidden = true

        for titleLayer in titleLayers.values {
            titleLayer.setVisible(false)
        }

        for cardLayer in cardLayers.values {
            cardLayer.animateToCollapsed(duration: duration)
        }
    }

    func setHoveredWindow(_ windowID: CGWindowID?) {
        guard hoveredWindowID != windowID else {
            return
        }

        hoveredWindowID = windowID
        onHoverChanged?(windowID)

        applyFocusHaloForCurrentState()
    }

    private func applyFocusHaloForCurrentState() {
        guard hasFinishedExpanding else { return }

        for (cardWindowID, cardLayer) in cardLayers {
            cardLayer.setHovered(cardWindowID == hoveredWindowID)
        }
        for (titleWindowID, titleLayer) in titleLayers {
            titleLayer.setFocused(titleWindowID == hoveredWindowID)
        }
    }

    /// Sets the keyboard-driven focus. Mirrors the same visual treatment as mouse hover so users
    /// only see one focused card at a time regardless of which input drove it.
    func setKeyboardSelectedWindow(_ windowID: CGWindowID?) {
        setHoveredWindow(windowID)
    }

    /// Hands first-responder back to the window (away from the search field) so x/y/n shortcuts
    /// resume working after a keyboard navigation step.
    func resignSearchFocus() {
        guard let window, window.firstResponder !== window else { return }
        window.makeFirstResponder(nil)
    }

    func setFilter(matchingWindowIDs: Set<CGWindowID>?, displayText: String) {
        filterMatchingWindowIDs = matchingWindowIDs
        applyFilterDimming()

        // The pill is persistent (always shown on the primary panel) so users see the filter
        // affordance up front. Just update its content — text or placeholder.
        searchPill?.setText(displayText)
        layoutSearchPill()
    }

    /// Hide mode: the controller has re-laid-out the matching windows, so animate each visible card
    /// to its new frame and fade the rest out. Hidden cards are skipped for hit-testing.
    func applyHideFilter(visibleWindowIDs: Set<CGWindowID>, displayText: String) {
        filterMatchingWindowIDs = visibleWindowIDs
        filterHidesNonMatches = true

        for descriptor in windowDescriptors {
            guard !goneWindowIDs.contains(descriptor.id) else { continue }
            let visible = visibleWindowIDs.contains(descriptor.id)
            if visible {
                let cardLocal = descriptor.targetFrame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
                let titleLocal = descriptor.titleBarFrame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
                cardLayers[descriptor.id]?.animateToNewFrame(cardLocal, duration: 0.28)
                titleLayers[descriptor.id]?.animateToNewFrame(titleLocal, duration: 0.28)
            }
            cardLayers[descriptor.id]?.setFilteredHidden(!visible)
            titleLayers[descriptor.id]?.setFilteredHidden(!visible)
        }

        searchPill?.setText(displayText)
        layoutSearchPill()
    }

    private func buildSearchPillIfNeeded() {
        guard showsShelf else { return }
        let pill = SearchPillView()
        pill.wantsLayer = true
        pill.layer?.zPosition = 90_000
        pill.onTextChanged = { [weak self] text in
            self?.onSearchTextChanged?(text)
        }
        pill.onCommand = { [weak self] selector in
            self?.onSearchCommand?(selector) ?? false
        }
        addSubview(pill)
        searchPill = pill
    }

    private func layoutSearchPill() {
        guard let searchPill else { return }
        let pillSize = searchPill.intrinsicContentSize
        let maxWidth = bounds.width - 80
        let width = min(pillSize.width, maxWidth)
        let height = pillSize.height

        // Sit just above the bottom button row (shelf / new windows / desktop button).
        let bottomRowTop = max(24, bounds.height - 60 - 28)
        let pillY = max(8, bottomRowTop - height - 14)

        searchPill.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: pillY,
            width: width,
            height: height
        )
    }

    private func applyFilterDimming() {
        let dimOpacity: Float = 0.10
        for descriptor in windowDescriptors {
            let matches = filterMatchingWindowIDs?.contains(descriptor.id) ?? true
            cardLayers[descriptor.id]?.opacity = matches ? 1.0 : dimOpacity
            titleLayers[descriptor.id]?.opacity = matches ? 1.0 : dimOpacity * 0.4
        }
    }

    /// Each panel renders the prompt only when it's for a window on its display. The chip is
    /// centered on the card so the card itself communicates which window is closing.
    func setCloseConfirmation(descriptor: WindowDescriptor?, focusedYes: Bool) {
        guard let descriptor, descriptor.displayID == display.id else {
            confirmationDescriptor = nil
            confirmationChip?.removeFromSuperview()
            confirmationChip = nil
            return
        }

        confirmationDescriptor = descriptor
        if confirmationChip == nil {
            let chip = ConfirmationChipView()
            chip.wantsLayer = true
            // Cards sit at zPosition 10_000+, titles at 20_000+; the chip must render above both.
            chip.layer?.zPosition = 100_000
            chip.onYes = { [weak self] in self?.onCloseConfirmationDecided?(true) }
            chip.onNo = { [weak self] in self?.onCloseConfirmationDecided?(false) }
            addSubview(chip)
            confirmationChip = chip
        }
        confirmationChip?.setFocusedYes(focusedYes)
        layoutConfirmationChip()
    }

    private func layoutConfirmationChip() {
        guard let chip = confirmationChip, let descriptor = confirmationDescriptor else { return }
        let chipSize = chip.intrinsicContentSize
        let cardLocal = descriptor.targetFrame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
        let width = min(chipSize.width, max(160, cardLocal.width - 24))
        let height = chipSize.height
        chip.frame = CGRect(
            x: cardLocal.midX - width / 2,
            y: cardLocal.midY - height / 2,
            width: width,
            height: height
        )
    }

    func disableInteractions() {
        window?.acceptsMouseMovedEvents = false
        setHoveredWindow(nil)
    }

    func notifyMouseActivity() {
        setWallpaperOpaque(true)
    }

    func close() {
        mouseIdleTimer?.invalidate()
        mouseIdleTimer = nil
        previewObservers.removeAll()
    }

    private var wallpaperIsOpaque = false

    private func setWallpaperOpaque(_ opaque: Bool) {
        mouseIdleTimer?.invalidate()
        mouseIdleTimer = nil

        if opaque != wallpaperIsOpaque {
            wallpaperIsOpaque = opaque
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            wallpaperLayer.opacity = opaque ? 1.0 : 0.99
            CATransaction.commit()
        }

        if opaque, isExpanded {
            mouseIdleTimer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setWallpaperOpaque(false)
                }
            }
        }
    }

    // MARK: - Live inventory updates

    /// A window closed (via its ✕ or externally, detected by the live-refresh loop). Fade its card
    /// out and re-flow the survivors into the freed space — the controller has already recomputed
    /// each survivor's target frame.
    func animateRelayout(closedWindowID: CGWindowID, duration: CFTimeInterval) {
        guard !goneWindowIDs.contains(closedWindowID) else { return }
        goneWindowIDs.insert(closedWindowID)

        if hoveredWindowID == closedWindowID {
            hoveredWindowID = nil
        }
        cardLayers[closedWindowID]?.setFilteredHidden(true)
        titleLayers[closedWindowID]?.setFilteredHidden(true)

        for descriptor in windowDescriptors {
            guard descriptor.id != closedWindowID, !goneWindowIDs.contains(descriptor.id) else { continue }
            let cardLocal = descriptor.targetFrame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
            let titleLocal = descriptor.titleBarFrame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
            cardLayers[descriptor.id]?.animateToNewFrame(cardLocal, duration: duration)
            titleLayers[descriptor.id]?.animateToNewFrame(titleLocal, duration: duration)
        }
    }

    func markWindowRestored(_ windowID: CGWindowID) {
        guard goneWindowIDs.contains(windowID) else { return }
        goneWindowIDs.remove(windowID)
        cardLayers[windowID]?.setFilteredHidden(false)
        titleLayers[windowID]?.setFilteredHidden(false)
    }

    func addNewWindowIcons(_ icons: [(windowID: CGWindowID, pid: pid_t, appName: String, icon: NSImage)]) {
        guard showsShelf else { return }

        for info in icons {
            // Skip duplicates.
            guard !newWindowButtons.contains(where: { $0.windowID == info.windowID }) else { continue }
            let button = NewWindowButton(windowID: info.windowID, pid: info.pid, icon: info.icon, appName: info.appName)
            button.target = self
            button.action = #selector(selectNewWindow(_:))
            addSubview(button)
            newWindowButtons.append(button)
        }

        layoutBottomRow()
    }

    // MARK: - Wallpaper

    private static var wallpaperCache: [WallpaperCacheKey: CGImage] = [:]

    private static let desktopWallpaperLayer = -2147483624

    private static func resolveWallpaper(for displayID: CGDirectDisplayID) -> ResolvedWallpaper? {
        guard let screen = screen(for: displayID),
        let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return nil
        }

        let cacheKey = WallpaperCacheKey(
            displayID: displayID,
            wallpaperURL: url,
            frame: screen.frame.integral,
            appearanceName: currentAppearanceCacheComponent()
        )
        return ResolvedWallpaper(
            url: url,
            cacheKey: cacheKey,
            wallpaperWindowID: currentWallpaperWindowID(for: screen),
            captureSize: screen.frame.size,
            scale: max(screen.backingScaleFactor, 1),
            colorSpaceName: screen.colorSpace?.cgColorSpace?.name as String?,
            supportsEDR: screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
        )
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == UInt32(displayID)
        }
    }

    /// Loads the wallpaper on a background thread and sets it when ready.
    /// Result is cached so subsequent opens are instant.
    private func loadWallpaperAsync() {
        let displayID = display.id

        // Resolve the URL on the main thread (fast, needs NSScreen).
        guard let wallpaper = Self.resolveWallpaper(for: displayID) else { return }
        if let cached = Self.wallpaperCache[wallpaper.cacheKey] {
            wallpaperLayer.contents = cached
            return
        }

        // Decode on a background thread to avoid blocking the open.
        Task { [weak self] in
            let cgImage = await Self.captureRenderedWallpaper(for: wallpaper)
            let resolvedImage: CGImage?
            if let cgImage {
                resolvedImage = cgImage
            } else {
                resolvedImage = await Self.decodeWallpaperImage(from: wallpaper.url)
            }
            guard let self, let resolvedImage else { return }
            guard let currentWallpaper = Self.resolveWallpaper(for: displayID),
                  currentWallpaper.cacheKey == wallpaper.cacheKey else {
                return
            }
            Self.wallpaperCache[wallpaper.cacheKey] = resolvedImage
            self.wallpaperLayer.contents = resolvedImage
        }
    }

    private static func currentAppearanceCacheComponent() -> String {
        if let appearance = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
            return appearance.rawValue
        }

        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            ? NSAppearance.Name.darkAqua.rawValue
            : NSAppearance.Name.aqua.rawValue
    }

    private static func currentWallpaperWindowID(for screen: NSScreen) -> CGWindowID? {
        guard let rawWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let targetFrame = screen.frame.integral
        var bestMatch: (windowID: CGWindowID, overlapArea: CGFloat)?

        for info in rawWindows {
            guard let ownerName = info[kCGWindowOwnerName as String] as? String,
                  ownerName == "Dock",
                  let layerNumber = info[kCGWindowLayer as String] as? NSNumber,
                  layerNumber.intValue == desktopWallpaperLayer,
                  let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
                continue
            }

            let overlap = targetFrame.intersection(bounds)
            let overlapArea = overlap.isNull ? 0 : overlap.width * overlap.height
            guard overlapArea > 0 else { continue }

            if let bestMatch, bestMatch.overlapArea >= overlapArea {
                continue
            }

            bestMatch = (CGWindowID(windowNumber.uint32Value), overlapArea)
        }

        return bestMatch?.windowID
    }

    private nonisolated static func captureRenderedWallpaper(for wallpaper: ResolvedWallpaper) async -> CGImage? {
        guard let wallpaperWindowID = wallpaper.wallpaperWindowID,
              let shareableContent = await shareableContentIncludingDesktopWindows(),
              let shareableWindow = shareableContent.windows.first(where: { $0.windowID == wallpaperWindowID }) else {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
        let configuration: SCStreamConfiguration
        if #available(macOS 15.0, *), wallpaper.supportsEDR {
            configuration = SCStreamConfiguration(preset: .captureHDRScreenshotLocalDisplay)
            configuration.captureDynamicRange = .hdrLocalDisplay
        } else {
            configuration = SCStreamConfiguration()
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            if let colorSpaceName = wallpaper.colorSpaceName {
                configuration.colorSpaceName = colorSpaceName as CFString
            }
        }
        configuration.width = max(1, size_t(wallpaper.captureSize.width * wallpaper.scale))
        configuration.height = max(1, size_t(wallpaper.captureSize.height * wallpaper.scale))
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private nonisolated static func shareableContentIncludingDesktopWindows() async -> SCShareableContent? {
        await withCheckedContinuation { cont in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
                cont.resume(returning: content)
            }
        }
    }

    private nonisolated static func decodeWallpaperImage(from url: URL) async -> CGImage? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let nsImage = NSImage(contentsOf: url)
                let cgImage = nsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                cont.resume(returning: cgImage)
            }
        }
    }

    // MARK: - Layer construction

    private func buildWindowLayers() {
        guard let rootLayer = layer else {
            return
        }

        for descriptor in windowDescriptors.reversed() {
            let cardLayer = WindowCardLayer(
                descriptor: descriptor,
                displayOrigin: displayOrigin,
                displaySupportsEDR: displaySupportsEDR
            )
            cardLayer.zPosition = CGFloat(10_000 - descriptor.zIndex)
            rootLayer.addSublayer(cardLayer)
            cardLayers[descriptor.id] = cardLayer

            let titleLayer = WindowTitleLayer(descriptor: descriptor, displayOrigin: displayOrigin)
            titleLayer.zPosition = CGFloat(20_000 - descriptor.zIndex)
            rootLayer.addSublayer(titleLayer)
            titleLayers[descriptor.id] = titleLayer

            cardLayer.setPreviewImage(descriptor.previewImage)

            previewObservers[descriptor.id] = descriptor.$previewImageRevision
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    if self.previewUpdatesSuspended {
                        self.pendingPreviewUpdateWindowIDs.insert(descriptor.id)
                        return
                    }
                    self.cardLayers[descriptor.id]?.setPreviewImage(descriptor.previewImage)
                }
        }
    }

    func setPreviewUpdatesSuspended(_ suspended: Bool) {
        guard previewUpdatesSuspended != suspended else {
            return
        }

        previewUpdatesSuspended = suspended
        guard !suspended else {
            return
        }

        let pendingWindowIDs = pendingPreviewUpdateWindowIDs
        pendingPreviewUpdateWindowIDs.removeAll()
        for windowID in pendingWindowIDs {
            guard let descriptor = windowDescriptors.first(where: { $0.id == windowID }) else {
                continue
            }
            cardLayers[windowID]?.setPreviewImage(descriptor.previewImage)
        }
    }

    private func buildShelfButtonsIfNeeded() {
        guard showsShelf else {
            return
        }

        for item in snapshot.shelfItems {
            let button = ShelfItemButton(item: item)
            button.target = self
            button.action = #selector(selectShelfItem(_:))
            addSubview(button)
            shelfButtons.append(button)
        }
    }

    private func buildDesktopButtonIfNeeded() {
        guard showsShelf else { return }

        let button = DesktopButton()
        button.target = self
        button.action = #selector(desktopButtonClicked)
        addSubview(button)
        desktopButton = button
    }

    /// Lays out the bottom row: shelf buttons + new window icons + desktop button.
    private func layoutBottomRow() {
        let buttonSize = CGSize(width: 60, height: 60)
        let smallButtonSize = CGSize(width: 44, height: 44)
        let spacing: CGFloat = 16
        let y = max(24, bounds.height - buttonSize.height - 28)

        // Collect all bottom items: shelf + new window icons.
        let shelfCount = shelfButtons.count
        let newCount = newWindowButtons.count
        let hasDesktop = desktopButton != nil
        let totalItems = shelfCount + newCount + (hasDesktop ? 1 : 0)

        guard totalItems > 0 else { return }

        // Total width: shelf and new window buttons are 60, desktop is 44.
        let bigButtonCount = shelfCount + newCount
        let totalWidth = CGFloat(bigButtonCount) * buttonSize.width
            + (hasDesktop ? smallButtonSize.width : 0)
            + CGFloat(max(0, totalItems - 1)) * spacing

        var x = (bounds.width - totalWidth) / 2

        for button in shelfButtons {
            button.frame = CGRect(origin: CGPoint(x: x, y: y), size: buttonSize)
            x += buttonSize.width + spacing
        }

        for button in newWindowButtons {
            button.frame = CGRect(origin: CGPoint(x: x, y: y), size: buttonSize)
            x += buttonSize.width + spacing
        }

        if let desktopButton {
            let desktopY = y + (buttonSize.height - smallButtonSize.height) / 2
            desktopButton.frame = CGRect(origin: CGPoint(x: x, y: desktopY), size: smallButtonSize)
        }
    }

    /// The ✕ lives on the title bar and is only hit-active while its card is focused, so a click on
    /// the corner of an unfocused card doesn't close that window.
    private func hitTestCloseButton(at localPoint: CGPoint) -> WindowDescriptor? {
        guard let hoveredWindowID,
              let descriptor = windowDescriptors.first(where: { $0.id == hoveredWindowID }),
              !goneWindowIDs.contains(descriptor.id) else {
            return nil
        }
        let titleLocal = descriptor.titleBarFrame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
        let xSize = WindowTitleLayer.closeButtonSize
        let xMargin = WindowTitleLayer.closeButtonMargin
        let xRect = CGRect(
            x: titleLocal.maxX - xMargin - xSize,
            y: titleLocal.minY + (titleLocal.height - xSize) / 2,
            width: xSize,
            height: xSize
        )
        return xRect.contains(localPoint) ? descriptor : nil
    }

    private func hitTestWindow(at localPoint: CGPoint) -> WindowDescriptor? {
        windowDescriptors.first { descriptor in
            // Skip gone (closed) windows — they're not clickable.
            guard !goneWindowIDs.contains(descriptor.id) else { return false }
            // In hide mode, non-matching cards are faded out and not clickable.
            if filterHidesNonMatches, filterMatchingWindowIDs?.contains(descriptor.id) == false {
                return false
            }
            let target = descriptor.targetFrame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
            let title = descriptor.titleBarFrame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
            return target.union(title).contains(localPoint)
        }
    }

    @objc
    private func selectShelfItem(_ sender: ShelfItemButton) {
        onShelfItemSelected?(sender.item)
    }

    @objc
    private func selectNewWindow(_ sender: NewWindowButton) {
        onNewWindowSelected?(sender.windowID, sender.pid)
    }

    @objc
    private func desktopButtonClicked() {
        onDesktopRequested?()
    }
}

// MARK: - Window Card

private final class WindowCardLayer: CALayer {
    private let sourceRect: CGRect
    private let targetRect: CGRect
    private let previewLayer = CALayer()
    private let borderLayer = CAShapeLayer()

    init(descriptor: WindowDescriptor, displayOrigin: CGPoint, displaySupportsEDR: Bool) {
        sourceRect = descriptor.sourceFrame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
        targetRect = descriptor.targetFrame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)

        super.init()

        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        bounds = CGRect(origin: .zero, size: targetRect.size)
        position = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
        transform = collapsedTransform
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.28
        shadowRadius = 18
        shadowOffset = CGSize(width: 0, height: 8)
        backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        masksToBounds = false

        previewLayer.contentsGravity = .resizeAspectFill
        previewLayer.cornerRadius = 12
        // Square the top edge so it meets the title chip above as one continuous shape.
        // (The flipped parent NSView means maxY-side corners render at the visual bottom.)
        previewLayer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        previewLayer.masksToBounds = true
        previewLayer.minificationFilter = .trilinear
        previewLayer.magnificationFilter = .trilinear
        if displaySupportsEDR {
            previewLayer.contentsFormat = .RGBA16Float
            previewLayer.wantsExtendedDynamicRangeContent = true
        }
        addSublayer(previewLayer)

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.clear.cgColor
        borderLayer.lineWidth = 1
        addSublayer(borderLayer)

        updateGeometry()
    }

    override init(layer: Any) {
        guard let layer = layer as? WindowCardLayer else {
            fatalError("Unsupported layer copy")
        }

        sourceRect = layer.sourceRect
        targetRect = layer.targetRect
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        updateGeometry()
    }

    func setPreviewImage(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.contents = image
        CATransaction.commit()
    }

    func setHovered(_ hovered: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.strokeColor = hovered ? NSColor.systemBlue.cgColor : NSColor.clear.cgColor
        borderLayer.lineWidth = hovered ? 3 : 1
        CATransaction.commit()
    }

    func animateToExpanded(duration: CFTimeInterval) {
        let targetPosition = CGPoint(x: targetRect.midX, y: targetRect.midY)
        let currentPosition = position
        let currentTransform = transform

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        position = targetPosition
        transform = CATransform3DIdentity
        CATransaction.commit()

        if duration <= 0 {
            return
        }

        // Expo ease-out: aggressive deceleration curve.
        let timing = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

        let positionAnimation = CABasicAnimation(keyPath: "position")
        positionAnimation.fromValue = currentPosition
        positionAnimation.toValue = targetPosition
        positionAnimation.duration = duration
        positionAnimation.timingFunction = timing

        let transformAnimation = CABasicAnimation(keyPath: "transform")
        transformAnimation.fromValue = currentTransform
        transformAnimation.toValue = CATransform3DIdentity
        transformAnimation.duration = duration
        transformAnimation.timingFunction = timing

        add(positionAnimation, forKey: "position")
        add(transformAnimation, forKey: "transform")
    }

    func animateToCollapsed(duration: CFTimeInterval) {
        let targetPosition = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
        let currentPosition = presentation()?.position ?? position
        let currentTransform = presentation()?.transform ?? transform

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        position = targetPosition
        transform = collapsedTransform
        CATransaction.commit()

        if duration <= 0 {
            return
        }

        let timing = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

        let positionAnimation = CABasicAnimation(keyPath: "position")
        positionAnimation.fromValue = currentPosition
        positionAnimation.toValue = targetPosition
        positionAnimation.duration = duration
        positionAnimation.timingFunction = timing

        let transformAnimation = CABasicAnimation(keyPath: "transform")
        transformAnimation.fromValue = currentTransform
        transformAnimation.toValue = collapsedTransform
        transformAnimation.duration = duration
        transformAnimation.timingFunction = timing

        add(positionAnimation, forKey: "position")
        add(transformAnimation, forKey: "transform")
    }

    /// Animate the card to a new layout-space frame (used when a filter re-layouts the survivors).
    /// The bounds jump to the final size immediately and a counter-scale transform fakes the visual
    /// growth/shrink, so the preview renders at full resolution rather than re-decoding mid-flight.
    func animateToNewFrame(_ newLocal: CGRect, duration: CFTimeInterval) {
        let newPosition = CGPoint(x: newLocal.midX, y: newLocal.midY)
        let newSize = newLocal.size
        let oldPosition = presentation()?.position ?? position
        let oldSize = bounds.size

        let initialTransform = CATransform3DMakeScale(
            oldSize.width / max(newSize.width, 1),
            oldSize.height / max(newSize.height, 1),
            1
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bounds = CGRect(origin: .zero, size: newSize)
        transform = CATransform3DIdentity
        position = newPosition
        CATransaction.commit()

        guard duration > 0 else { return }

        let timing = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

        let positionAnim = CABasicAnimation(keyPath: "position")
        positionAnim.fromValue = oldPosition
        positionAnim.toValue = newPosition
        positionAnim.duration = duration
        positionAnim.timingFunction = timing

        let transformAnim = CABasicAnimation(keyPath: "transform")
        transformAnim.fromValue = initialTransform
        transformAnim.toValue = CATransform3DIdentity
        transformAnim.duration = duration
        transformAnim.timingFunction = timing

        add(positionAnim, forKey: "relayoutPosition")
        add(transformAnim, forKey: "relayoutTransform")
    }

    /// Fade the card fully out (filter hides it) or back in, with an implicit cross-fade.
    func setFilteredHidden(_ hidden: Bool) {
        opacity = hidden ? 0 : 1
    }

    private var collapsedTransform: CATransform3D {
        CATransform3DMakeScale(
            max(sourceRect.width / max(targetRect.width, 1), 0.01),
            max(sourceRect.height / max(targetRect.height, 1), 0.01),
            1
        )
    }

    private func updateGeometry() {
        previewLayer.frame = bounds
        borderLayer.frame = bounds

        // Border: open at the top — the title chip above draws the matching upper half so the two
        // pieces fuse into one continuous focus ring at the seam.
        let r: CGFloat = 12
        let w = bounds.width
        let h = bounds.height
        let borderPath = CGMutablePath()
        borderPath.move(to: CGPoint(x: 0, y: 0))
        borderPath.addLine(to: CGPoint(x: 0, y: h - r))
        borderPath.addQuadCurve(to: CGPoint(x: r, y: h), control: CGPoint(x: 0, y: h))
        borderPath.addLine(to: CGPoint(x: w - r, y: h))
        borderPath.addQuadCurve(to: CGPoint(x: w, y: h - r), control: CGPoint(x: w, y: h))
        borderPath.addLine(to: CGPoint(x: w, y: 0))
        borderLayer.path = borderPath

        shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
    }
}

// MARK: - Window Title

private final class WindowTitleLayer: CALayer {
    static let closeButtonSize: CGFloat = 26
    static let closeButtonMargin: CGFloat = 7

    private let iconLayer = CALayer()
    private let textLayer = CATextLayer()
    private let borderLayer = CAShapeLayer()
    private let closeButtonLayer = CALayer()
    private let closeGlyphLayer = CAShapeLayer()
    private let appName: String
    private let windowTitle: String?

    init(descriptor: WindowDescriptor, displayOrigin: CGPoint) {
        let localFrame = descriptor.titleBarFrame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
        self.appName = descriptor.appName
        self.windowTitle = descriptor.title

        super.init()

        bounds = CGRect(origin: .zero, size: localFrame.size)
        position = CGPoint(x: localFrame.midX, y: localFrame.midY)
        cornerRadius = 12
        maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        // The default per-layer border draws all four sides; the borderLayer below replaces it
        // with an open-bottom path so it fuses with the card's open-top border at the seam.
        borderColor = NSColor.clear.cgColor
        borderWidth = 0
        isHidden = true
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        iconLayer.contents = descriptor.iconCGImage
        iconLayer.contentsGravity = .resizeAspectFill
        iconLayer.cornerRadius = 5
        iconLayer.masksToBounds = true
        addSublayer(iconLayer)

        // NSAttributedString: do not set CATextLayer fontSize/font/foregroundColor — they override attributes.
        textLayer.alignmentMode = .left
        textLayer.truncationMode = .end
        textLayer.isWrapped = false
        textLayer.masksToBounds = true
        textLayer.contentsScale = contentsScale
        addSublayer(textLayer)

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
        borderLayer.lineWidth = 1
        addSublayer(borderLayer)

        closeButtonLayer.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        closeButtonLayer.cornerRadius = Self.closeButtonSize / 2
        closeButtonLayer.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        closeButtonLayer.borderWidth = 1
        closeButtonLayer.isHidden = true
        addSublayer(closeButtonLayer)

        closeGlyphLayer.strokeColor = NSColor.white.withAlphaComponent(0.92).cgColor
        closeGlyphLayer.fillColor = NSColor.clear.cgColor
        closeGlyphLayer.lineWidth = 1.6
        closeGlyphLayer.lineCap = .round
        closeButtonLayer.addSublayer(closeGlyphLayer)

        updateGeometry()
    }

    /// The ✕ is shown only while the card is focused (hover or keyboard selection).
    func setFocused(_ focused: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.strokeColor = focused
            ? NSColor.systemBlue.cgColor
            : NSColor.white.withAlphaComponent(0.10).cgColor
        borderLayer.lineWidth = focused ? 3 : 1
        closeButtonLayer.isHidden = !focused
        CATransaction.commit()
    }

    override init(layer: Any) {
        guard let layer = layer as? WindowTitleLayer else {
            fatalError("Unsupported layer copy")
        }
        self.appName = layer.appName
        self.windowTitle = layer.windowTitle
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        updateGeometry()
    }

    func setVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = !visible
        opacity = visible ? 1 : 0
        CATransaction.commit()
    }

    func animateToVisible(duration: CFTimeInterval) {
        let timing = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = false
        opacity = 0
        CATransaction.commit()

        guard duration > 0 else {
            opacity = 1
            return
        }

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = Float(0)
        opacityAnimation.toValue = Float(1)
        opacityAnimation.duration = duration
        opacityAnimation.timingFunction = timing
        opacity = 1
        add(opacityAnimation, forKey: "opacityIn")
    }

    /// Animate the title chip to follow its card to a new layout-space frame (filter re-layout).
    func animateToNewFrame(_ newLocal: CGRect, duration: CFTimeInterval) {
        let newPosition = CGPoint(x: newLocal.midX, y: newLocal.midY)
        let oldPosition = presentation()?.position ?? position

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        position = newPosition
        bounds = CGRect(origin: .zero, size: newLocal.size)
        CATransaction.commit()

        guard duration > 0 else { return }

        let positionAnim = CABasicAnimation(keyPath: "position")
        positionAnim.fromValue = oldPosition
        positionAnim.toValue = newPosition
        positionAnim.duration = duration
        positionAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        add(positionAnim, forKey: "relayoutPosition")
    }

    /// Fade the title fully out (filter hides its card) or back in.
    func setFilteredHidden(_ hidden: Bool) {
        opacity = hidden ? 0 : 1
    }

    private func updateGeometry() {
        let iconSize: CGFloat = 28
        iconLayer.frame = CGRect(x: 10, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)

        let xSize = Self.closeButtonSize
        let xMargin = Self.closeButtonMargin
        closeButtonLayer.frame = CGRect(
            x: bounds.width - xMargin - xSize,
            y: (bounds.height - xSize) / 2,
            width: xSize,
            height: xSize
        )
        let glyphInset: CGFloat = 8
        let glyphRect = CGRect(
            x: glyphInset,
            y: glyphInset,
            width: xSize - 2 * glyphInset,
            height: xSize - 2 * glyphInset
        )
        let glyphPath = CGMutablePath()
        glyphPath.move(to: CGPoint(x: glyphRect.minX, y: glyphRect.minY))
        glyphPath.addLine(to: CGPoint(x: glyphRect.maxX, y: glyphRect.maxY))
        glyphPath.move(to: CGPoint(x: glyphRect.maxX, y: glyphRect.minY))
        glyphPath.addLine(to: CGPoint(x: glyphRect.minX, y: glyphRect.maxY))
        closeGlyphLayer.frame = closeButtonLayer.bounds
        closeGlyphLayer.path = glyphPath

        // Reserve room on the right for the ✕ so the text doesn't reflow when it appears on focus.
        let textX: CGFloat = 10 + iconSize + 10
        let textRightInset = xMargin + xSize + 6
        let textHeight: CGFloat = 22
        let textWidth = max(32, bounds.width - textX - textRightInset)
        textLayer.frame = CGRect(
            x: textX,
            y: (bounds.height - textHeight) / 2,
            width: textWidth,
            height: textHeight
        )
        textLayer.string = Self.makeTitleString(
            appName: appName,
            windowTitle: windowTitle,
            maxWidth: textWidth
        )

        // Inverted-U border: top + sides only, leaving the bottom open to meet the card's
        // open-top border at the seam. Same corner radius as the card.
        let r: CGFloat = 12
        let w = bounds.width
        let h = bounds.height
        let borderPath = CGMutablePath()
        borderPath.move(to: CGPoint(x: 0, y: h))
        borderPath.addLine(to: CGPoint(x: 0, y: r))
        borderPath.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
        borderPath.addLine(to: CGPoint(x: w - r, y: 0))
        borderPath.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
        borderPath.addLine(to: CGPoint(x: w, y: h))
        borderLayer.frame = bounds
        borderLayer.path = borderPath
    }

    private static func attributedWidth(_ attr: NSAttributedString, height: CGFloat) -> CGFloat {
        attr.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: height),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).width
    }

    private static func truncatedTail(
        _ text: String,
        attributes: [NSAttributedString.Key: Any],
        maxWidth: CGFloat,
        height: CGFloat
    ) -> NSAttributedString {
        guard maxWidth > 0, !text.isEmpty else { return NSAttributedString() }
        let full = NSAttributedString(string: text, attributes: attributes)
        if attributedWidth(full, height: height) <= maxWidth { return full }
        let ellipsis = "…"
        let ellipsisAttr = NSAttributedString(string: ellipsis, attributes: attributes)
        let ellipsisW = attributedWidth(ellipsisAttr, height: height)
        if maxWidth < ellipsisW { return ellipsisAttr }
        var low = 0
        var high = text.count
        while low < high {
            let mid = (low + high + 1) / 2
            let prefix = String(text.prefix(mid))
            let test = NSAttributedString(string: prefix + ellipsis, attributes: attributes)
            if attributedWidth(test, height: height) <= maxWidth { low = mid } else { high = mid - 1 }
        }
        if low == 0 { return ellipsisAttr }
        return NSAttributedString(string: String(text.prefix(low)) + ellipsis, attributes: attributes)
    }

    private static func makeTitleString(appName: String, windowTitle: String?, maxWidth: CGFloat) -> NSAttributedString {
        let appAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.98)
        ]
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.82)
        ]
        let separatorAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ]

        let measureHeight: CGFloat = 26
        let trimmedTitle = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedTitle.isEmpty, trimmedTitle != appName else {
            return truncatedTail(appName, attributes: appAttributes, maxWidth: maxWidth, height: measureHeight)
        }

        let prefix = NSMutableAttributedString(string: appName, attributes: appAttributes)
        prefix.append(NSAttributedString(string: " — ", attributes: separatorAttributes))
        let prefixWidth = attributedWidth(prefix, height: measureHeight)
        if prefixWidth >= maxWidth {
            return truncatedTail(appName, attributes: appAttributes, maxWidth: maxWidth, height: measureHeight)
        }

        let titleBudget = max(0, maxWidth - prefixWidth)
        let titlePart = truncatedTail(trimmedTitle, attributes: titleAttributes, maxWidth: titleBudget, height: measureHeight)
        prefix.append(titlePart)
        return prefix
    }
}

// MARK: - Shelf Button

private final class ShelfItemButton: NSButton {
    let item: AppShelfItem

    init(item: AppShelfItem) {
        self.item = item
        super.init(frame: .zero)

        image = item.icon
        imageScaling = .scaleProportionallyUpOrDown
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.60).cgColor
        layer?.cornerRadius = 18
        toolTip = item.appName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

// MARK: - New Window Button

private final class NewWindowButton: NSButton {
    let windowID: CGWindowID
    let pid: pid_t

    init(windowID: CGWindowID, pid: pid_t, icon: NSImage, appName: String) {
        self.windowID = windowID
        self.pid = pid
        super.init(frame: .zero)

        image = icon
        imageScaling = .scaleProportionallyUpOrDown
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.25).cgColor
        layer?.cornerRadius = 18
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.5).cgColor
        toolTip = "New: \(appName)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

// MARK: - Search Pill

/// Persistent search affordance anchored to the bottom of the primary panel. Magnifying glass +
/// "Type to filter…" placeholder at rest; clicking it (or just typing anywhere) makes it active.
/// When focused, typing inserts directly into the field; special commands (arrows, Tab, Return,
/// Escape) are intercepted via NSTextField's `doCommandBy` delegate hook and bubbled back up.
private final class SearchPillView: NSView, NSTextFieldDelegate {
    private static let collapsedMinWidth: CGFloat = 200
    private static let placeholder = "Type to filter…"

    var onTextChanged: ((String) -> Void)?
    /// Returns true if the controller consumed the command (don't let the field editor process it).
    var onCommand: ((Selector) -> Bool)?

    private let iconView = NSImageView()
    private let textField = NSTextField()
    private let blurView = NSVisualEffectView()
    private var hasText = false
    private var isProgrammaticTextChange = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        layer?.borderWidth = 1

        blurView.material = .hudWindow
        blurView.state = .active
        blurView.blendingMode = .behindWindow
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Filter")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.60)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        textField.font = .systemFont(ofSize: 13, weight: .medium)
        textField.textColor = NSColor.white.withAlphaComponent(0.95)
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.isEditable = true
        textField.isSelectable = true
        textField.lineBreakMode = .byTruncatingTail
        textField.delegate = self
        textField.placeholderAttributedString = NSAttributedString(
            string: Self.placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.45),
                .font: NSFont.systemFont(ofSize: 13, weight: .medium)
            ]
        )
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let textWidth = textField.intrinsicContentSize.width
        let contentWidth = 14 + 16 + 10 + max(40, textWidth) + 14
        return NSSize(width: max(Self.collapsedMinWidth, contentWidth), height: 36)
    }

    /// Updates the field's displayed text without firing the change-callback back at the
    /// controller (avoids a feedback loop when the controller broadcasts a filter update).
    func setText(_ text: String) {
        let newHasText = !text.isEmpty
        hasText = newHasText
        if textField.stringValue != text {
            isProgrammaticTextChange = true
            textField.stringValue = text
            isProgrammaticTextChange = false
        }
        applyVisualState()
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
    }

    private func applyVisualState() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hasText {
            iconView.contentTintColor = NSColor.white.withAlphaComponent(0.92)
            layer?.borderColor = NSColor.white.withAlphaComponent(0.32).cgColor
        } else {
            iconView.contentTintColor = NSColor.white.withAlphaComponent(0.60)
            layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        }
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        // Become first responder so typing flows directly into the field; the field editor
        // handles the click position (cursor placement, text selection) afterward.
        window?.makeFirstResponder(textField)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard !isProgrammaticTextChange else { return }
        onTextChanged?(textField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        return onCommand?(commandSelector) ?? false
    }
}

// MARK: - Confirmation Chip

private final class ConfirmationChipView: NSView {
    var onYes: (() -> Void)?
    var onNo: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Close window?")
    private let yesButton = ConfirmationButton(title: "Yes", style: .destructive)
    private let noButton = ConfirmationButton(title: "No", style: .defaultAction)
    private let blurView = NSVisualEffectView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1

        blurView.material = .hudWindow
        blurView.state = .active
        blurView.blendingMode = .behindWindow
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        yesButton.target = self
        yesButton.action = #selector(handleYes)
        yesButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(yesButton)

        noButton.target = self
        noButton.action = #selector(handleNo)
        noButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(noButton)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            yesButton.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 14),
            yesButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            noButton.leadingAnchor.constraint(equalTo: yesButton.trailingAnchor, constant: 8),
            noButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            noButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setFocusedYes(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let titleWidth = titleLabel.intrinsicContentSize.width
        let buttonWidth = yesButton.intrinsicContentSize.width + 8 + noButton.intrinsicContentSize.width
        return NSSize(width: 16 + titleWidth + 14 + buttonWidth + 10, height: 48)
    }

    /// Highlight whichever button the keyboard focus sits on (Yes when `true`, else No).
    func setFocusedYes(_ focusedYes: Bool) {
        yesButton.setFocused(focusedYes)
        noButton.setFocused(!focusedYes)
    }

    /// Swallow clicks on the chip's empty area so the card beneath isn't activated. Clicks on the
    /// Yes / No buttons hit them first via normal subview hit-testing.
    override func mouseDown(with event: NSEvent) {}

    @objc
    private func handleYes() {
        onYes?()
    }

    @objc
    private func handleNo() {
        onNo?()
    }
}

private final class ConfirmationButton: NSButton {
    enum Style {
        case defaultAction
        case destructive
    }

    private let style: Style

    init(title: String, style: Style) {
        self.style = style
        super.init(frame: .zero)

        self.title = title
        self.isBordered = false
        self.wantsLayer = true
        self.contentTintColor = .white
        self.font = .systemFont(ofSize: 13, weight: .semibold)
        self.layer?.cornerRadius = 7

        setFocused(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 60, height: 28)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Keep the fill constant on mouse hover / press — only the keyboard focus ring changes the
    /// look, so the background never flashes the system accent color.
    override func highlight(_ flag: Bool) {}

    /// Keyboard focus brightens the border (same hue); the fill stays steady.
    func setFocused(_ focused: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch style {
        case .destructive:
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.30).cgColor
            layer?.borderColor = NSColor.systemRed.withAlphaComponent(focused ? 0.95 : 0.50).cgColor
        case .defaultAction:
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(focused ? 0.95 : 0.45).cgColor
        }
        layer?.borderWidth = focused ? 2 : 1
        CATransaction.commit()
    }
}

// MARK: - Desktop Button

private final class DesktopButton: NSButton {
    init() {
        super.init(frame: .zero)

        image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "Show Desktop")
        imageScaling = .scaleProportionallyUpOrDown
        contentTintColor = .white
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        layer?.cornerRadius = 12
        toolTip = "Show Desktop"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
