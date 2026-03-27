//
//  OverviewOverlayView.swift
//  FastMissionControl
//
//  Created by Codex.
//

import AppKit
import Combine
import QuartzCore

@MainActor
final class OverviewDisplayView: NSView {
    var onHoverChanged: ((CGWindowID?) -> Void)?
    var onBackgroundClick: (() -> Void)?
    var onWindowSelected: ((WindowDescriptor) -> Void)?
    var onShelfItemSelected: ((AppShelfItem) -> Void)?
    var onDesktopRequested: (() -> Void)?
    var onNewWindowSelected: ((CGWindowID, pid_t) -> Void)?

    private let display: DisplayOverview
    private let snapshot: OverviewSnapshot
    private let performance: PreviewPerformanceModel
    private let showsShelf: Bool
    private let showsHUD: Bool
    private let displayOrigin: CGPoint
    private let windowDescriptors: [WindowDescriptor]

    private let wallpaperLayer = CALayer()
    private let backgroundDimLayer = CALayer()
    private var cardLayers: [CGWindowID: WindowCardLayer] = [:]
    private var titleLayers: [CGWindowID: WindowTitleLayer] = [:]
    private var previewObservers: [CGWindowID: AnyCancellable] = [:]
    private var performanceObservers = Set<AnyCancellable>()
    private var shelfButtons: [ShelfItemButton] = []
    private var newWindowButtons: [NewWindowButton] = []
    private var desktopButton: DesktopButton?
    private var hudView: PerformanceHUDView?
    private var trackingAreaRef: NSTrackingArea?
    private var hoveredWindowID: CGWindowID?
    private var isExpanded = false
    private var goneWindowIDs: Set<CGWindowID> = []

    override var isFlipped: Bool {
        true
    }

    init(
        display: DisplayOverview,
        snapshot: OverviewSnapshot,
        performance: PreviewPerformanceModel,
        showsShelf: Bool,
        showsHUD: Bool
    ) {
        self.display = display
        self.snapshot = snapshot
        self.performance = performance
        self.showsShelf = showsShelf
        self.showsHUD = showsHUD
        displayOrigin = display.localFrame.origin
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

        // Desktop wallpaper as backdrop (loaded async to avoid blocking open).
        wallpaperLayer.contentsGravity = .resizeAspectFill
        wallpaperLayer.frame = CGRect(origin: .zero, size: display.localFrame.size)
        wallpaperLayer.zPosition = -2
        wallpaperLayer.opacity = 0
        // Try cache first (instant on 2nd+ open), else load async.
        if let cached = Self.wallpaperCache[display.id] {
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
        buildHUDIfNeeded()
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
        layoutHUDIfNeeded()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isExpanded else {
            return
        }

        setHoveredWindow(hitTestWindow(at: convert(event.locationInWindow, from: nil))?.id)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredWindow(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)

        guard isExpanded else {
            return
        }

        if let descriptor = hitTestWindow(at: localPoint) {
            onWindowSelected?(descriptor)
            return
        }

        onBackgroundClick?()
    }

    // MARK: - Expand / hover

    func expand(duration: CFTimeInterval) {
        guard !isExpanded else {
            return
        }

        isExpanded = true

        let dimAnimation = CABasicAnimation(keyPath: "opacity")
        dimAnimation.fromValue = Float(0)
        dimAnimation.toValue = Float(1)
        dimAnimation.duration = min(duration, 0.12)
        dimAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        backgroundDimLayer.opacity = 1
        backgroundDimLayer.add(dimAnimation, forKey: "dimOpacity")

        let wallpaperAnimation = CABasicAnimation(keyPath: "opacity")
        wallpaperAnimation.fromValue = Float(0)
        wallpaperAnimation.toValue = Float(1)
        wallpaperAnimation.duration = min(duration, 0.12)
        wallpaperAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        wallpaperLayer.opacity = 1
        wallpaperLayer.add(wallpaperAnimation, forKey: "wallpaperOpacity")

        for titleLayer in titleLayers.values {
            titleLayer.setVisible(true)
        }
        for cardLayer in cardLayers.values {
            cardLayer.animateToExpanded(duration: duration)
        }
    }

    func setHoveredWindow(_ windowID: CGWindowID?) {
        guard hoveredWindowID != windowID else {
            return
        }

        hoveredWindowID = windowID
        onHoverChanged?(windowID)

        for (cardWindowID, cardLayer) in cardLayers {
            cardLayer.setHovered(cardWindowID == windowID)
        }
    }

    func disableInteractions() {
        window?.acceptsMouseMovedEvents = false
        setHoveredWindow(nil)
    }

    func close() {
        for observer in previewObservers.values {
            observer.cancel()
        }
        previewObservers.removeAll()
        performanceObservers.removeAll()
    }

    // MARK: - Live inventory updates

    func markWindowGone(_ windowID: CGWindowID) {
        guard !goneWindowIDs.contains(windowID) else { return }
        goneWindowIDs.insert(windowID)

        if let card = cardLayers[windowID],
           let descriptor = windowDescriptors.first(where: { $0.id == windowID }) {
            card.setGone(true, appIcon: descriptor.iconCGImage)
        }
    }

    func markWindowRestored(_ windowID: CGWindowID) {
        guard goneWindowIDs.contains(windowID) else { return }
        goneWindowIDs.remove(windowID)

        if let card = cardLayers[windowID] {
            card.setGone(false, appIcon: nil)
        }
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

    private static var wallpaperCache: [CGDirectDisplayID: CGImage] = [:]

    /// Loads the wallpaper on a background thread and sets it when ready.
    /// Result is cached so subsequent opens are instant.
    private func loadWallpaperAsync() {
        let displayID = display.id

        // Resolve the URL on the main thread (fast, needs NSScreen).
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == UInt32(displayID)
        }
        guard let url = screen.flatMap({ NSWorkspace.shared.desktopImageURL(for: $0) }) else { return }

        // Decode on a background thread to avoid blocking the open.
        Task { [weak self] in
            let cgImage: CGImage? = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let nsImage = NSImage(contentsOf: url)
                    let cg = nsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    cont.resume(returning: cg)
                }
            }
            guard let self, let cgImage else { return }
            Self.wallpaperCache[displayID] = cgImage
            self.wallpaperLayer.contents = cgImage
        }
    }

    // MARK: - Layer construction

    private func buildWindowLayers() {
        guard let rootLayer = layer else {
            return
        }

        for descriptor in windowDescriptors.reversed() {
            let cardLayer = WindowCardLayer(descriptor: descriptor, displayOrigin: displayOrigin)
            cardLayer.zPosition = CGFloat(10_000 - descriptor.zIndex)
            rootLayer.addSublayer(cardLayer)
            cardLayers[descriptor.id] = cardLayer

            let titleLayer = WindowTitleLayer(descriptor: descriptor, displayOrigin: displayOrigin)
            titleLayer.zPosition = CGFloat(20_000 - descriptor.zIndex)
            rootLayer.addSublayer(titleLayer)
            titleLayers[descriptor.id] = titleLayer

            previewObservers[descriptor.id] = descriptor.$previewImage
                .sink { [weak cardLayer] image in
                    cardLayer?.setPreviewImage(image)
                }

            cardLayer.setPreviewImage(descriptor.previewImage)
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

    private func buildHUDIfNeeded() {
        guard showsHUD else {
            return
        }

        let hudView = PerformanceHUDView(frame: CGRect(x: 16, y: 16, width: 132, height: 56))
        addSubview(hudView)
        self.hudView = hudView
        hudView.update(fps: performance.displayedFPS, liveSessionCount: performance.liveSessionCount, liveFrozen: performance.liveFrozen)

        performance.$displayedFPS
            .combineLatest(performance.$liveSessionCount, performance.$liveFrozen)
            .receive(on: RunLoop.main)
            .sink { [weak hudView] fps, liveCount, liveFrozen in
                hudView?.update(fps: fps, liveSessionCount: liveCount, liveFrozen: liveFrozen)
            }
            .store(in: &performanceObservers)
    }

    private func layoutHUDIfNeeded() {
        guard let hudView else {
            return
        }

        hudView.frame.origin = CGPoint(x: 16, y: 16)
    }

    private func hitTestWindow(at localPoint: CGPoint) -> WindowDescriptor? {
        windowDescriptors.first { descriptor in
            // Skip gone (closed) windows — they're not clickable.
            guard !goneWindowIDs.contains(descriptor.id) else { return false }
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
    private let goneOverlayLayer = CALayer()
    private let goneIconLayer = CALayer()

    init(descriptor: WindowDescriptor, displayOrigin: CGPoint) {
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
        previewLayer.masksToBounds = true
        previewLayer.minificationFilter = .trilinear
        previewLayer.magnificationFilter = .trilinear
        addSublayer(previewLayer)

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.clear.cgColor
        borderLayer.lineWidth = 1
        addSublayer(borderLayer)

        // Gone-state layers (hidden by default).
        goneOverlayLayer.backgroundColor = NSColor.black.withAlphaComponent(0.40).cgColor
        goneOverlayLayer.cornerRadius = 12
        goneOverlayLayer.isHidden = true
        addSublayer(goneOverlayLayer)

        goneIconLayer.contentsGravity = .resizeAspect
        goneIconLayer.isHidden = true
        addSublayer(goneIconLayer)

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

    func setGone(_ gone: Bool, appIcon: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        goneOverlayLayer.isHidden = !gone
        goneIconLayer.isHidden = !gone
        if gone, let appIcon {
            goneIconLayer.contents = appIcon
        }
        shadowOpacity = gone ? 0.08 : 0.28
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
        goneOverlayLayer.frame = bounds

        let iconSize = min(bounds.width, bounds.height) * 0.35
        goneIconLayer.frame = CGRect(
            x: (bounds.width - iconSize) / 2,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )

        let roundedPath = CGPath(
            roundedRect: bounds,
            cornerWidth: 12,
            cornerHeight: 12,
            transform: nil
        )
        borderLayer.path = roundedPath
        shadowPath = roundedPath
    }
}

// MARK: - Window Title

private final class WindowTitleLayer: CALayer {
    private let iconLayer = CALayer()
    private let textLayer = CATextLayer()

    init(descriptor: WindowDescriptor, displayOrigin: CGPoint) {
        let localFrame = descriptor.titleBarFrame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)

        super.init()

        bounds = CGRect(origin: .zero, size: localFrame.size)
        position = CGPoint(x: localFrame.midX, y: localFrame.midY)
        cornerRadius = 10
        backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        borderWidth = 1
        isHidden = true
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        iconLayer.contents = descriptor.iconCGImage
        iconLayer.contentsGravity = .resizeAspectFill
        iconLayer.cornerRadius = 5
        iconLayer.masksToBounds = true
        addSublayer(iconLayer)

        textLayer.string = descriptor.displayTitle
        textLayer.font = NSFont.systemFont(ofSize: 0, weight: .medium)
        textLayer.fontSize = 14
        textLayer.foregroundColor = NSColor.white.withAlphaComponent(0.94).cgColor
        textLayer.alignmentMode = .left
        textLayer.truncationMode = .end
        textLayer.contentsScale = contentsScale
        addSublayer(textLayer)

        updateGeometry()
    }

    override init(layer: Any) {
        guard let layer = layer as? WindowTitleLayer else {
            fatalError("Unsupported layer copy")
        }

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
        CATransaction.commit()
    }

    private func updateGeometry() {
        let iconSize: CGFloat = 24
        iconLayer.frame = CGRect(x: 10, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let textX: CGFloat = 10 + iconSize + 8
        textLayer.frame = CGRect(x: textX, y: (bounds.height - 20) / 2, width: max(32, bounds.width - textX - 10), height: 20)
    }
}

// MARK: - Performance HUD

private final class PerformanceHUDView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 10

        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .left
        label.maximumNumberOfLines = 3
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 10, dy: 8)
    }

    func update(fps: Int, liveSessionCount: Int, liveFrozen: Bool) {
        label.stringValue = "FPS \(fps)\nLive \(liveSessionCount)\n\(liveFrozen ? "Live frozen" : "Live streaming")"
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
