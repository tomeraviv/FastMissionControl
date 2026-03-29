//
//  AppModel.swift
//  FastMissionControl
//
//  Created by Codex.
//

import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isOverviewVisible = false
    @Published private(set) var lastStatus = "Checking permissions…"

    let settings: AppSettings
    let permissions = PermissionCoordinator()

    private let triggerMonitor = GlobalTriggerMonitor()
    private let appCache = RunningApplicationCache()
    private let inventoryService: WindowInventoryService
    private let layoutEngine: SpatialOverviewLayout
    private let previewController: WindowPreviewController
    private let activationService = WindowActivationService()

    private var overviewController: OverviewWindowController?
    private var currentSnapshot: OverviewSnapshot?
    private var cancellables = Set<AnyCancellable>()
    private var resumePreviewUpdatesTask: Task<Void, Never>?
    private var startLivePreviewsTask: Task<Void, Never>?
    private var startStillPreviewLoadingTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var liveRefreshTimer: Timer?
    private var openWindowIDs: Set<CGWindowID> = []
    private var goneWindowIDs: Set<CGWindowID> = []
    private var newWindowIDs: Set<CGWindowID> = []
    private var desktopHiddenPIDs: Set<pid_t> = []

    init(settings: AppSettings) {
        self.settings = settings
        inventoryService = WindowInventoryService(appCache: appCache, settings: settings)
        layoutEngine = SpatialOverviewLayout(settings: settings)
        previewController = WindowPreviewController(settings: settings)
    }

    func start() {
        Publishers.CombineLatest(
            permissions.$screenRecordingGranted,
            permissions.$accessibilityGranted
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateTriggerMonitor()
                self?.updateStatus()
                self?.updatePrewarmLoop()
            }
            .store(in: &cancellables)

        settings.$changeCounter
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applySettings()
            }
            .store(in: &cancellables)

        triggerMonitor.onToggle = { [weak self] slowAnimation in
            self?.toggleOverview(slowAnimation: slowAnimation)
        }

        applySettings()
        refreshPermissions()
    }

    func shutdown() {
        prewarmTask?.cancel()
        prewarmTask = nil
        resumePreviewUpdatesTask?.cancel()
        resumePreviewUpdatesTask = nil
        startStillPreviewLoadingTask?.cancel()
        startStillPreviewLoadingTask = nil
        stopLiveRefresh()
        closeOverview()
        triggerMonitor.stop()
    }

    func refreshPermissions() {
        permissions.refresh()
        updateTriggerMonitor()
        updateStatus()
    }

    func requestScreenRecording() {
        permissions.requestScreenRecording()
        lastStatus = "Screen Recording prompt requested. Re-open the app after granting if macOS keeps access pending."
    }

    func requestAccessibility() {
        permissions.requestAccessibility()
        lastStatus = "Accessibility prompt requested."
    }

    func hideControlWindow() {
        NSApplication.shared.hide(nil)
    }

    // MARK: - Toggle (always synchronous, always instant)

    func toggleOverview(slowAnimation: Bool = NSEvent.modifierFlags.contains(.shift)) {
        if overviewController != nil {
            closeOverview()
            return
        }

        guard permissions.isReady else {
            updateStatus()
            return
        }

        // Restore apps hidden by "Show Desktop" on the previous session.
        restoreDesktopIfNeeded()

        // ── 100% synchronous open ─────────────────────────────────
        // CGWindowListCopyWindowInfo is sync (~5-15ms).
        // Layout computation is sync (~1ms).
        // Controller + layer tree build is sync (~5-10ms).
        // Total: ~15-30ms — well within one frame.
        do {
            let snapshot = try inventoryService.snapshotSync()

            guard !snapshot.windows.isEmpty || !snapshot.shelfItems.isEmpty else {
                lastStatus = "No visible windows were found."
                return
            }

            layoutEngine.apply(to: snapshot)
            previewController.applyCachedPreviews(to: snapshot)

            let controller = makeOverviewController(snapshot: snapshot)
            let openAnimationDuration = slowAnimation
                ? settings.slowOpenAnimationDuration
                : settings.openAnimationDuration
            let openAnimationDurationNanoseconds = slowAnimation
                ? settings.slowOpenAnimationDurationNanoseconds
                : settings.openAnimationDurationNanoseconds
            showOverview(
                controller: controller,
                snapshot: snapshot,
                openAnimationDuration: openAnimationDuration,
                openAnimationDurationNanoseconds: openAnimationDurationNanoseconds
            )
        } catch {
            lastStatus = error.localizedDescription
        }
    }

    func closeOverview() {
        dismissOverviewImmediately()
    }

    // MARK: - Show

    private func showOverview(
        controller: OverviewWindowController,
        snapshot: OverviewSnapshot,
        openAnimationDuration: CFTimeInterval,
        openAnimationDurationNanoseconds: UInt64
    ) {
        prewarmTask?.cancel()
        prewarmTask = nil

        previewController.prepare(snapshot: snapshot, startStillLoading: false)

        currentSnapshot = snapshot
        overviewController = controller
        isOverviewVisible = true
        lastStatus = "Overview open."

        // Track which windows are in the grid (for live diffing).
        openWindowIDs = Set(snapshot.windows.map(\.id))
        goneWindowIDs = []
        newWindowIDs = []

        previewController.setPreviewUpdatesSuspended(true)
        controller.setPreviewUpdatesSuspended(true)
        controller.show(duration: openAnimationDuration)
        schedulePostShowWork(
            controller: controller,
            snapshot: snapshot,
            openAnimationDurationNanoseconds: openAnimationDurationNanoseconds
        )
        startLiveRefresh()
    }

    private func schedulePostShowWork(
        controller: OverviewWindowController,
        snapshot: OverviewSnapshot,
        openAnimationDurationNanoseconds: UInt64
    ) {
        // Pre-resolve AX handles so clicks raise the right window instantly.
        activationService.preResolveAXHandles(for: snapshot)

        // Fire-and-forget: resolve SCWindow objects in background
        // (needed for preview captures, not needed for display).
        Task { [weak self] in
            await self?.inventoryService.resolveShareableWindows(for: snapshot)
            self?.previewController.shareableWindowsDidResolve()
        }

        resumePreviewUpdatesTask?.cancel()
        resumePreviewUpdatesTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: openAnimationDurationNanoseconds)
            } catch { return }
            guard !Task.isCancelled else { return }
            controller.setPreviewUpdatesSuspended(false)
            self.previewController.setPreviewUpdatesSuspended(false)
        }

        startStillPreviewLoadingTask?.cancel()
        startStillPreviewLoadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Wait for animation + give SCWindow resolution time.
                try await Task.sleep(nanoseconds: max(
                    openAnimationDurationNanoseconds + 50_000_000,
                    500_000_000
                ))
            } catch { return }
            guard !Task.isCancelled else { return }
            self.previewController.startStillPreviewLoading()
        }

        startLivePreviewsTask?.cancel()
        startLivePreviewsTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: max(
                    self.settings.livePreviewStartupDelayNanoseconds,
                    openAnimationDurationNanoseconds
                ))
            } catch { return }
            guard !Task.isCancelled else { return }
            self.previewController.startLivePreviews()
        }
    }

    // MARK: - Live Refresh (poll for new/gone windows while open)

    private func startLiveRefresh() {
        stopLiveRefresh()
        liveRefreshTimer = Timer.scheduledTimer(withTimeInterval: settings.liveRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pollWindowChanges()
            }
        }
    }

    private func stopLiveRefresh() {
        liveRefreshTimer?.invalidate()
        liveRefreshTimer = nil
    }

    private func pollWindowChanges() {
        guard isOverviewVisible, let controller = overviewController else { return }

        let current = inventoryService.pollVisibleWindowIDs()
        let currentIDs = Set(current.keys)

        // Windows that disappeared since we opened.
        let newlyGone = openWindowIDs.subtracting(currentIDs).subtracting(goneWindowIDs)
        for id in newlyGone {
            goneWindowIDs.insert(id)
            controller.markWindowGone(id)
        }

        // Windows that came back (e.g. unminimized).
        let restored = goneWindowIDs.intersection(currentIDs)
        for id in restored {
            goneWindowIDs.remove(id)
            controller.markWindowRestored(id)
        }

        // Brand-new windows (not in original grid and not already tracked).
        let brandNew = currentIDs.subtracting(openWindowIDs).subtracting(newWindowIDs)
        if !brandNew.isEmpty {
            var icons: [(windowID: CGWindowID, pid: pid_t, appName: String, icon: NSImage)] = []
            for id in brandNew {
                guard let info = current[id] else { continue }
                newWindowIDs.insert(id)
                let record = appCache.record(for: info.pid)
                let appName = info.appName ?? record?.localizedName ?? "Application"
                let icon = record?.icon ?? NSWorkspace.shared.icon(for: .application)
                icons.append((windowID: id, pid: info.pid, appName: appName, icon: icon))
            }

            if !icons.isEmpty {
                controller.addNewWindowIcons(icons)
            }
        }
    }

    // MARK: - Desktop

    private func showDesktop() {
        let visibleApps = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && !$0.isHidden && $0.activationPolicy == .regular
        }

        desktopHiddenPIDs = Set(visibleApps.map(\.processIdentifier))

        for app in visibleApps {
            app.hide()
        }

        dismissOverviewImmediately()
    }

    private func restoreDesktopIfNeeded() {
        guard !desktopHiddenPIDs.isEmpty else { return }

        let pidsToRestore = desktopHiddenPIDs
        desktopHiddenPIDs = []

        for app in NSWorkspace.shared.runningApplications {
            guard pidsToRestore.contains(app.processIdentifier), !app.isTerminated else { continue }
            app.unhide()
        }
    }

    // MARK: - Controller Factory

    private func makeOverviewController(snapshot: OverviewSnapshot) -> OverviewWindowController {
        OverviewWindowController(
            snapshot: snapshot,
            onDismiss: { [weak self] in
                guard let self else { return }
                self.resumePreviewUpdatesTask?.cancel()
                self.resumePreviewUpdatesTask = nil
                self.startLivePreviewsTask?.cancel()
                self.startLivePreviewsTask = nil
                self.startStillPreviewLoadingTask?.cancel()
                self.startStillPreviewLoadingTask = nil
                self.stopLiveRefresh()
                self.previewController.stopAll()
                self.currentSnapshot = nil
                self.overviewController = nil
                self.isOverviewVisible = false
                self.updatePrewarmLoop()
            },
            onHoverChanged: { [weak self] windowID in
                self?.previewController.setHoveredWindow(windowID)
            },
            onMouseMoving: { [weak self] moving in
                self?.previewController.setUserInteractingWithOverlay(moving)
            },
            onInteractionChanged: { [weak self] interacting in
                self?.previewController.setUserInteractingWithOverlay(interacting)
            },
            onWindowSelected: { [weak self] descriptor, slowAnimation in
                guard let self else { return }
                let duration = slowAnimation
                    ? self.settings.slowSelectionAnimationDuration
                    : self.settings.selectionAnimationDuration
                let durationNanoseconds = slowAnimation
                    ? self.settings.slowSelectionAnimationDurationNanoseconds
                    : self.settings.selectionAnimationDurationNanoseconds
                self.activationService.activateAppFast(pid: descriptor.pid)
                self.dismissOverviewAnimated(
                    selectedWindowID: descriptor.id,
                    duration: duration,
                    durationNanoseconds: durationNanoseconds
                )
                Task { @MainActor [weak self] in
                    self?.activationService.raiseSpecificWindow(descriptor: descriptor)
                }
            },
            onShelfItemSelected: { [weak self] item in
                guard let self else { return }
                self.activationService.activateAppFast(pid: item.pid)
                self.overviewController?.hideImmediately()
                self.activationService.raiseSpecificWindow(shelfItem: item)
                self.dismissOverviewImmediately()
            },
            onDesktopRequested: { [weak self] in
                self?.showDesktop()
            },
            onNewWindowSelected: { [weak self] windowID, pid in
                guard let self else { return }
                self.activationService.activateAppFast(pid: pid)
                self.overviewController?.hideImmediately()
                self.activationService.raiseSpecificWindow(windowID: windowID, pid: pid)
                self.dismissOverviewImmediately()
            }
        )
    }

    // MARK: - Trigger Monitor

    private func updateTriggerMonitor() {
        if permissions.isReady {
            do {
                try triggerMonitor.start()
            } catch {
                lastStatus = error.localizedDescription
            }
        } else {
            triggerMonitor.stop()
        }
    }

    // MARK: - Prewarm (preview cache only — open is always sync now)

    private func updatePrewarmLoop() {
        prewarmTask?.cancel()
        prewarmTask = nil

        guard permissions.isReady else { return }

        prewarmTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self?.settings.prewarmIntervalNanoseconds ?? 3_000_000_000)
                } catch { return }

                await self?.prewarmPreviewCache()
            }
        }
    }

    /// Background preview cache warmer. Captures still images for
    /// each window so that the next open shows thumbnails instantly.
    private func prewarmPreviewCache() async {
        guard permissions.isReady, !isOverviewVisible else { return }

        do {
            let snapshot = try inventoryService.snapshotSync()
            guard !Task.isCancelled, !isOverviewVisible else { return }

            layoutEngine.apply(to: snapshot)

            // Resolve SCWindows (needed for capture).
            await inventoryService.resolveShareableWindows(for: snapshot)
            guard !Task.isCancelled, !isOverviewVisible else { return }

            await previewController.prewarm(snapshot: snapshot, forceRefresh: true)
        } catch {
            // Ignore — cache misses are not fatal.
        }
    }

    // MARK: - Dismiss

    private func dismissOverviewImmediately() {
        if let controller = overviewController {
            controller.hideImmediately()
        }

        startLivePreviewsTask?.cancel()
        startLivePreviewsTask = nil
        resumePreviewUpdatesTask?.cancel()
        resumePreviewUpdatesTask = nil
        startStillPreviewLoadingTask?.cancel()
        startStillPreviewLoadingTask = nil
        stopLiveRefresh()
        previewController.stopAll()

        guard let controller = overviewController else {
            isOverviewVisible = false
            return
        }

        currentSnapshot = nil
        overviewController = nil
        isOverviewVisible = false

        // Defer the heavy panel/layer teardown so the main thread unblocks
        // and the WindowServer can composite the target window sooner.
        Task { @MainActor in
            controller.close()
        }
    }

    private func dismissOverviewAnimated(
        selectedWindowID: CGWindowID?,
        duration: CFTimeInterval,
        durationNanoseconds: UInt64
    ) {
        guard let controller = overviewController else {
            return
        }

        startLivePreviewsTask?.cancel()
        startLivePreviewsTask = nil
        startStillPreviewLoadingTask?.cancel()
        startStillPreviewLoadingTask = nil
        stopLiveRefresh()
        previewController.stopAll()
        controller.setPreviewUpdatesSuspended(true)

        controller.animateDismiss(selectedWindowID: selectedWindowID, duration: duration)

        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: durationNanoseconds)
            } catch {
                return
            }

            controller.close()
        }
    }

    private func updateStatus() {
        if !permissions.screenRecordingGranted && !permissions.accessibilityGranted {
            lastStatus = "Screen Recording and Accessibility are required."
        } else if !permissions.screenRecordingGranted {
            lastStatus = "Screen Recording is required."
        } else if !permissions.accessibilityGranted {
            lastStatus = "Accessibility is required."
        } else if isOverviewVisible {
            lastStatus = "Overview open."
        } else {
            lastStatus = "Ready. Mouse button \(settings.toggleButtonNumber + 1) toggles the overview."
        }
    }

    private func applySettings() {
        triggerMonitor.toggleButtonNumber = Int64(settings.toggleButtonNumber)
        updateStatus()
        updatePrewarmLoop()

        if isOverviewVisible {
            startLiveRefresh()
        }
    }
}
