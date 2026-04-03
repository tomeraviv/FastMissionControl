//
//  WindowPreviewController.swift
//  FastMissionControl
//
//  Created by Codex.
//

import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

@MainActor
final class WindowPreviewController {
    private struct CaptureDisplayConfiguration {
        let colorSpaceName: String?
        let prefersHDR: Bool
    }

    private let settings: AppSettings
    private var snapshot: OverviewSnapshot?
    private var hoveredWindowID: CGWindowID?
    private var liveRefreshTask: Task<Void, Never>?
    private var stillTasks: [CGWindowID: Task<Void, Never>] = [:]
    private var livePreviewsEnabled = false
    private var userInteractingWithOverlay = false
    private var previewUpdatesSuspended = false
    private var previewCache: [CGWindowID: CGImage] = [:]
    private var generation: UInt64 = 0
    private var livePreviewIntervalNanoseconds: UInt64

    init(settings: AppSettings) {
        self.settings = settings
        livePreviewIntervalNanoseconds = settings.defaultLivePreviewIntervalNanoseconds
    }

    func setUserInteractingWithOverlay(_ interacting: Bool) {
        userInteractingWithOverlay = interacting
    }

    func setPreviewUpdatesSuspended(_ suspended: Bool) {
        previewUpdatesSuspended = suspended
    }

    func prepare(snapshot: OverviewSnapshot, startStillLoading: Bool) {
        stopCurrentWork()
        generation &+= 1
        self.snapshot = snapshot
        hoveredWindowID = nil
        livePreviewsEnabled = false
        userInteractingWithOverlay = false
        previewUpdatesSuspended = false
        livePreviewIntervalNanoseconds = defaultLivePreviewIntervalNanoseconds()

        applyCachedPreviews(to: snapshot)

        if startStillLoading {
            startStillPreviewLoading()
        }
    }

    func prewarm(snapshot: OverviewSnapshot, forceRefresh: Bool = false) async {
        let priorityWindows = snapshot.windows.sorted { lhs, rhs in
            prewarmPriority(for: lhs, cursorDisplayID: snapshot.cursorDisplayID) > prewarmPriority(for: rhs, cursorDisplayID: snapshot.cursorDisplayID)
        }

        for descriptor in priorityWindows where forceRefresh || previewCache[descriptor.id] == nil {
            guard !Task.isCancelled else {
                return
            }

            let displayConfiguration = captureDisplayConfiguration(for: descriptor.displayID)

            guard let image = await Self.captureOffMainActor(
                shareableWindow: descriptor.shareableWindow,
                targetFrame: descriptor.targetFrame,
                longestEdge: 1000,
                displayConfiguration: displayConfiguration
            ) else {
                continue
            }

            previewCache[descriptor.id] = image
            descriptor.updatePreviewImage(image)
        }
    }

    func startLivePreviews() {
        guard snapshot != nil else {
            return
        }

        livePreviewsEnabled = true
        ensureLiveLoopRunning()
    }

    func shareableWindowsDidResolve() {
        guard livePreviewsEnabled else { return }
        ensureLiveLoopRunning()
    }

    func stopAll() {
        stopCurrentWork()
        generation &+= 1
        snapshot = nil
        hoveredWindowID = nil
        livePreviewsEnabled = false
        userInteractingWithOverlay = false
        livePreviewIntervalNanoseconds = defaultLivePreviewIntervalNanoseconds()
    }

    func startStillPreviewLoading() {
        guard let snapshot else {
            return
        }

        let currentGeneration = generation
        for descriptor in snapshot.windows where descriptor.previewImage == nil && stillTasks[descriptor.id] == nil {
            stillTasks[descriptor.id] = Task { [weak self] in
                await self?.loadStillPreview(for: descriptor, generation: currentGeneration)
            }
        }
    }

    func setHoveredWindow(_ windowID: CGWindowID?) {
        guard hoveredWindowID != windowID else {
            return
        }

        hoveredWindowID = windowID
    }

    // MARK: - Live preview polling loop

    private func ensureLiveLoopRunning() {
        guard liveRefreshTask == nil else { return }
        let currentGeneration = generation
        liveRefreshTask = Task { [weak self] in
            await self?.runLivePreviewLoop(generation: currentGeneration)
        }
    }

    private func runLivePreviewLoop(generation: UInt64) async {
        while !Task.isCancelled {
            guard livePreviewsEnabled,
                  generation == self.generation,
                  let snapshot else {
                break
            }

            let desiredWindows = livePreviewDescriptors(from: snapshot)

            guard !desiredWindows.isEmpty else {
                if await sleepForCurrentInterval(idlePreviewIntervalNanoseconds) == false {
                    break
                }
                continue
            }

            if userInteractingWithOverlay {
                if await sleepForCurrentInterval(suspendedPreviewIntervalNanoseconds) == false {
                    break
                }
                continue
            }

            if previewUpdatesSuspended {
                if await sleepForCurrentInterval(suspendedPreviewIntervalNanoseconds) == false {
                    break
                }
                continue
            }

            let captureStart = DispatchTime.now().uptimeNanoseconds
            let results = await captureBatch(
                desiredWindows,
                maxConcurrentCaptures: settings.livePreviewCaptureConcurrencyLimit
            )
            let captureDurationNanoseconds = DispatchTime.now().uptimeNanoseconds - captureStart

            guard !Task.isCancelled,
                  generation == self.generation,
                  livePreviewsEnabled else {
                liveRefreshTask = nil
                return
            }

            for (descriptor, image) in results {
                guard snapshot.windows.contains(where: { $0.id == descriptor.id }) else {
                    continue
                }
                descriptor.updatePreviewImage(image)
                previewCache[descriptor.id] = image
            }

            adaptLivePreviewInterval(
                afterCaptureDurationNanoseconds: captureDurationNanoseconds,
                windowCount: desiredWindows.count,
                hoveredWindowID: hoveredWindowID
            )

            let sleepNanoseconds = livePreviewIntervalNanoseconds > captureDurationNanoseconds
                ? livePreviewIntervalNanoseconds - captureDurationNanoseconds
                : 0
            if await sleepForCurrentInterval(sleepNanoseconds) == false {
                break
            }
        }

        liveRefreshTask = nil
    }

    private func livePreviewDescriptors(from snapshot: OverviewSnapshot) -> [WindowDescriptor] {
        let limit = snapshot.livePreviewLimit

        if let hoveredWindowID,
           let hovered = snapshot.windows.first(where: { $0.id == hoveredWindowID }),
           hovered.shareableWindow != nil {
            let rest = windowsForFairShareLivePreview(
                snapshot: snapshot,
                limit: max(0, limit - 1),
                excluding: Set([hoveredWindowID])
            )
            return [hovered] + rest
        }

        return windowsForFairShareLivePreview(snapshot: snapshot, limit: limit, excluding: [])
    }

    /// Interleaves windows across displays (round-robin) so every monitor gets live updates instead of
    /// filling the budget entirely from the cursor display.
    private func windowsForFairShareLivePreview(
        snapshot: OverviewSnapshot,
        limit: Int,
        excluding excluded: Set<CGWindowID>
    ) -> [WindowDescriptor] {
        let shareable = snapshot.windows.filter { $0.shareableWindow != nil && !excluded.contains($0.id) }
        guard !shareable.isEmpty, limit > 0 else {
            return []
        }

        let byDisplay = Dictionary(grouping: shareable, by: \.displayID)
        let displayIDs = byDisplay.keys.sorted()

        var perDisplay: [CGDirectDisplayID: [WindowDescriptor]] = [:]
        for id in displayIDs {
            perDisplay[id] = (byDisplay[id] ?? []).sorted { $0.zIndex < $1.zIndex }
        }

        var nextIndex: [CGDirectDisplayID: Int] = Dictionary(uniqueKeysWithValues: displayIDs.map { ($0, 0) })
        var result: [WindowDescriptor] = []

        while result.count < limit {
            var progressed = false
            for id in displayIDs {
                guard result.count < limit else { break }
                let list = perDisplay[id]!
                let i = nextIndex[id]!
                if i < list.count {
                    result.append(list[i])
                    nextIndex[id] = i + 1
                    progressed = true
                }
            }
            if !progressed {
                break
            }
        }

        return result
    }

    private func prewarmPriority(for descriptor: WindowDescriptor, cursorDisplayID: CGDirectDisplayID?) -> Int {
        var score = 1_000 - descriptor.zIndex
        if descriptor.displayID == cursorDisplayID {
            score += 2_000
        }
        return score
    }

    // MARK: - Teardown

    private func stopCurrentWork() {
        liveRefreshTask?.cancel()
        liveRefreshTask = nil

        for task in stillTasks.values {
            task.cancel()
        }
        stillTasks.removeAll()
    }

    /// Assigns cached preview images to the given snapshot's descriptors.
    func applyCachedPreviews(to snapshot: OverviewSnapshot) {
        for descriptor in snapshot.windows {
            if let previewImage = descriptor.previewImage {
                previewCache[descriptor.id] = previewImage
                continue
            }

            if let cachedPreview = previewCache[descriptor.id] {
                descriptor.updatePreviewImage(cachedPreview)
            }
        }
    }

    // MARK: - Capture helpers

    private func defaultLivePreviewIntervalNanoseconds() -> UInt64 {
        settings.defaultLivePreviewIntervalNanoseconds
    }

    private func baselineIntervalNanoseconds(windowCount: Int, hoveredWindowID: CGWindowID?) -> UInt64 {
        if hoveredWindowID != nil {
            return livePreviewMinIntervalNanoseconds
        }

        switch windowCount {
        case ...2:
            return livePreviewMinIntervalNanoseconds
        case 3...4:
            return 50_000_000
        case 5...8:
            return 66_000_000
        default:
            return 83_000_000
        }
    }

    private func adaptLivePreviewInterval(
        afterCaptureDurationNanoseconds duration: UInt64,
        windowCount: Int,
        hoveredWindowID: CGWindowID?
    ) {
        let baseline = baselineIntervalNanoseconds(windowCount: windowCount, hoveredWindowID: hoveredWindowID)
        let pressured = min(
            livePreviewMaxIntervalNanoseconds,
            max(baseline, duration + duration / 4)
        )

        if pressured >= livePreviewIntervalNanoseconds {
            livePreviewIntervalNanoseconds = pressured
            return
        }

        livePreviewIntervalNanoseconds = max(
            baseline,
            (livePreviewIntervalNanoseconds * 3 + pressured) / 4
        )
    }

    private func sleepForCurrentInterval(_ nanoseconds: UInt64) async -> Bool {
        guard nanoseconds > 0 else {
            await Task.yield()
            return !Task.isCancelled
        }

        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return true
        } catch {
            return false
        }
    }

    private func loadStillPreview(for descriptor: WindowDescriptor, generation: UInt64) async {
        guard !Task.isCancelled else {
            return
        }

        let displayConfiguration = captureDisplayConfiguration(for: descriptor.displayID)

        guard let image = await Self.captureOffMainActor(
            shareableWindow: descriptor.shareableWindow,
            targetFrame: descriptor.targetFrame,
            longestEdge: 1000,
            displayConfiguration: displayConfiguration
        ) else {
            stillTasks.removeValue(forKey: descriptor.id)
            return
        }

        guard !Task.isCancelled,
              generation == self.generation,
              !previewUpdatesSuspended,
              snapshot?.windows.contains(where: { $0.id == descriptor.id }) == true else {
            stillTasks.removeValue(forKey: descriptor.id)
            return
        }

        descriptor.updatePreviewImage(image)
        previewCache[descriptor.id] = image
        stillTasks.removeValue(forKey: descriptor.id)
    }

    /// Captures a batch of windows concurrently after reading the per-window
    /// capture inputs on the main actor.
    private func captureBatch(
        _ descriptors: [WindowDescriptor],
        maxConcurrentCaptures: Int
    ) async -> [(WindowDescriptor, CGImage)] {
        let concurrencyLimit = max(1, maxConcurrentCaptures)

        return await withTaskGroup(of: (WindowDescriptor, CGImage?).self) { group in
            var iterator = descriptors.makeIterator()
            var inFlight = 0

            while inFlight < concurrencyLimit, let descriptor = iterator.next() {
                let displayConfiguration = captureDisplayConfiguration(for: descriptor.displayID)
                Self.addCaptureTask(for: descriptor, displayConfiguration: displayConfiguration, to: &group)
                inFlight += 1
            }

            var results: [(WindowDescriptor, CGImage)] = []
            while inFlight > 0 {
                guard let (descriptor, image) = await group.next() else {
                    break
                }
                inFlight -= 1

                if let image {
                    results.append((descriptor, image))
                }

                if let nextDescriptor = iterator.next() {
                    let displayConfiguration = captureDisplayConfiguration(for: nextDescriptor.displayID)
                    Self.addCaptureTask(for: nextDescriptor, displayConfiguration: displayConfiguration, to: &group)
                    inFlight += 1
                }
            }

            return results
        }
    }

    private static func addCaptureTask(
        for descriptor: WindowDescriptor,
        displayConfiguration: CaptureDisplayConfiguration,
        to group: inout TaskGroup<(WindowDescriptor, CGImage?)>
    ) {
        let shareableWindow = descriptor.shareableWindow
        let targetFrame = descriptor.targetFrame
        group.addTask {
            let image = await captureOffMainActor(
                shareableWindow: shareableWindow,
                targetFrame: targetFrame,
                longestEdge: 720,
                displayConfiguration: displayConfiguration
            )
            return (descriptor, image)
        }
    }

    /// Runs the actual ScreenCaptureKit call in a detached context so it
    /// never blocks the main actor.
    private nonisolated static func captureOffMainActor(
        shareableWindow: SCWindow?,
        targetFrame: CGRect,
        longestEdge: CGFloat,
        displayConfiguration: CaptureDisplayConfiguration
    ) async -> CGImage? {
        guard let shareableWindow else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
        let configuration = makeScreenshotConfiguration(
            targetFrame: targetFrame,
            longestEdge: longestEdge,
            displayConfiguration: displayConfiguration
        )
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func captureDisplayConfiguration(for displayID: CGDirectDisplayID) -> CaptureDisplayConfiguration {
        guard let screen = screen(for: displayID) else {
            return CaptureDisplayConfiguration(colorSpaceName: nil, prefersHDR: false)
        }

        return CaptureDisplayConfiguration(
            colorSpaceName: screen.colorSpace?.cgColorSpace?.name as String?,
            prefersHDR: screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
        )
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == UInt32(displayID)
        }
    }

    private nonisolated static func makeScreenshotConfiguration(
        targetFrame: CGRect,
        longestEdge: CGFloat,
        displayConfiguration: CaptureDisplayConfiguration
    ) -> SCStreamConfiguration {
        let configuration: SCStreamConfiguration

        if #available(macOS 15.0, *), displayConfiguration.prefersHDR {
            configuration = SCStreamConfiguration(preset: .captureHDRScreenshotLocalDisplay)
            configuration.captureDynamicRange = .hdrLocalDisplay
        } else {
            configuration = SCStreamConfiguration()
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            if let colorSpaceName = displayConfiguration.colorSpaceName {
                configuration.colorSpaceName = colorSpaceName as CFString
            }
        }

        let targetLongestEdge = max(targetFrame.width, targetFrame.height)
        let scale = max(1.0, min(3.0, longestEdge / max(targetLongestEdge, 1)))
        configuration.width = max(320, size_t(targetFrame.width * scale))
        configuration.height = max(200, size_t(targetFrame.height * scale))
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true

        return configuration
    }

    private var livePreviewMinIntervalNanoseconds: UInt64 {
        settings.livePreviewMinIntervalNanoseconds
    }

    private var livePreviewMaxIntervalNanoseconds: UInt64 {
        settings.livePreviewMaxIntervalNanoseconds
    }

    private var suspendedPreviewIntervalNanoseconds: UInt64 {
        settings.suspendedPreviewIntervalNanoseconds
    }

    private var idlePreviewIntervalNanoseconds: UInt64 {
        settings.idlePreviewIntervalNanoseconds
    }
}
