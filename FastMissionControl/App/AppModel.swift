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

    let permissions = PermissionCoordinator()

    private let triggerMonitor = GlobalTriggerMonitor()
    private let inventoryService = WindowInventoryService()
    private let layoutEngine = SpatialOverviewLayout()
    private let previewController = WindowPreviewController()
    private let activationService = WindowActivationService()

    private var overviewController: OverviewWindowController?
    private var currentSnapshot: OverviewSnapshot?
    private var cancellables = Set<AnyCancellable>()
    private var startLivePreviewsTask: Task<Void, Never>?
    private var startStillPreviewLoadingTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var liveRefreshTimer: Timer?
    private var openWindowIDs: Set<CGWindowID> = []
    private var goneWindowIDs: Set<CGWindowID> = []
    private var newWindowIDs: Set<CGWindowID> = []
    private var desktopHiddenPIDs: Set<pid_t> = []

    private let prewarmIntervalNanoseconds: UInt64 = 3_000_000_000
    private let liveRefreshInterval: TimeInterval = 1.5
    private let livePreviewStartupDelayNanoseconds: UInt64 = 2_000_000_000

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

        triggerMonitor.onToggle = { [weak self] in
            self?.toggleOverview()
        }

        refreshPermissions()
    }

    func shutdown() {
        prewarmTask?.cancel()
        prewarmTask = nil
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

    // MARK: - Toggle (always synchronous, always instant)

    func toggleOverview() {
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
            showOverview(controller: controller, snapshot: snapshot)
        } catch {
            lastStatus = error.localizedDescription
        }
    }

    func closeOverview() {
        dismissOverviewImmediately()
    }

    // MARK: - Show

    private func showOverview(controller: OverviewWindowController, snapshot: OverviewSnapshot) {
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

        controller.show()
        schedulePostShowWork(snapshot: snapshot)
        startLiveRefresh()
    }

    private func schedulePostShowWork(snapshot: OverviewSnapshot) {
        // Fire-and-forget: resolve SCWindow objects in background
        // (needed for preview captures, not needed for display).
        Task { [weak self] in
            await self?.inventoryService.resolveShareableWindows(for: snapshot)
        }

        startStillPreviewLoadingTask?.cancel()
        startStillPreviewLoadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Wait for animation + give SCWindow resolution time.
                try await Task.sleep(nanoseconds: max(
                    OverviewWindowController.openAnimationDurationNanoseconds + 50_000_000,
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
                try await Task.sleep(nanoseconds: self.livePreviewStartupDelayNanoseconds)
            } catch { return }
            guard !Task.isCancelled else { return }
            self.previewController.startLivePreviews()
        }
    }

    // MARK: - Live Refresh (poll for new/gone windows while open)

    private func startLiveRefresh() {
        stopLiveRefresh()
        liveRefreshTimer = Timer.scheduledTimer(withTimeInterval: liveRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollWindowChanges()
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
            let appMap = Dictionary(
                uniqueKeysWithValues: NSWorkspace.shared.runningApplications
                    .filter { !$0.isTerminated }
                    .map { ($0.processIdentifier, $0) }
            )

            var icons: [(windowID: CGWindowID, pid: pid_t, appName: String, icon: NSImage)] = []
            for id in brandNew {
                guard let info = current[id] else { continue }
                newWindowIDs.insert(id)
                let app = appMap[info.pid]
                let appName = info.appName ?? app?.localizedName ?? "Application"
                let icon = app?.icon ?? NSWorkspace.shared.icon(for: .application)
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
            performance: previewController.performance,
            onDismiss: { [weak self] in
                guard let self else { return }
                self.startLivePreviewsTask?.cancel()
                self.startLivePreviewsTask = nil
                self.startStillPreviewLoadingTask?.cancel()
                self.startStillPreviewLoadingTask = nil
                self.stopLiveRefresh()
                self.previewController.stopAll()
                self.overviewController = nil
                self.isOverviewVisible = false
            },
            onHoverChanged: { [weak self] windowID in
                self?.previewController.setHoveredWindow(windowID)
            },
            onWindowSelected: { [weak self] descriptor in
                guard let self else { return }
                self.triggerMonitor.suspend(for: 0.30)
                // Fast path: bring the app to front immediately (no AX).
                self.activationService.activateAppFast(pid: descriptor.pid)
                self.dismissOverviewImmediately()
                // Slow path: resolve & raise the specific window via AX
                // after the overlay is already gone.
                Task { self.activationService.raiseSpecificWindow(descriptor: descriptor) }
            },
            onShelfItemSelected: { [weak self] item in
                guard let self else { return }
                self.triggerMonitor.suspend(for: 0.30)
                self.activationService.activateAppFast(pid: item.pid)
                self.dismissOverviewImmediately()
                Task { self.activationService.raiseSpecificWindow(shelfItem: item) }
            },
            onDesktopRequested: { [weak self] in
                self?.showDesktop()
            },
            onNewWindowSelected: { [weak self] windowID, pid in
                guard let self else { return }
                self.triggerMonitor.suspend(for: 0.30)
                self.activationService.activateAppFast(pid: pid)
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
                    try await Task.sleep(nanoseconds: self?.prewarmIntervalNanoseconds ?? 3_000_000_000)
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

            await previewController.prewarm(snapshot: snapshot, forceRefresh: false)
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
        controller.close()
        updatePrewarmLoop()
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
            lastStatus = "Ready. Mouse button 4 toggles the overview."
        }
    }
}
