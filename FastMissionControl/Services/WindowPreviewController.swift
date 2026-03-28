//
//  WindowPreviewController.swift
//  FastMissionControl
//
//  Created by Codex.
//

import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

@MainActor
final class WindowPreviewController {
    private var snapshot: OverviewSnapshot?
    private var hoveredWindowID: CGWindowID?
    private var liveRefreshTask: Task<Void, Never>?
    private var stillTasks: [CGWindowID: Task<Void, Never>] = [:]
    private var livePreviewsEnabled = false
    private var userInteractingWithOverlay = false
    private var previewCache: [CGWindowID: CGImage] = [:]
    private var generation: UInt64 = 0
    private let livePreviewBatchIntervalNanoseconds: UInt64 = 5_000_000

    func setUserInteractingWithOverlay(_ interacting: Bool) {
        userInteractingWithOverlay = interacting
    }

    func prepare(snapshot: OverviewSnapshot, startStillLoading: Bool) {
        stopCurrentWork()
        generation &+= 1
        self.snapshot = snapshot
        hoveredWindowID = nil
        livePreviewsEnabled = false
        userInteractingWithOverlay = false

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

            guard let image = await Self.captureOffMainActor(
                shareableWindow: descriptor.shareableWindow,
                targetFrame: descriptor.targetFrame,
                longestEdge: 1000
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
                do {
                    try await Task.sleep(nanoseconds: livePreviewBatchIntervalNanoseconds)
                } catch { break }
                continue
            }

            if userInteractingWithOverlay {
                do {
                    try await Task.sleep(nanoseconds: livePreviewBatchIntervalNanoseconds)
                } catch { break }
                continue
            }

            let results = await Self.captureBatch(desiredWindows)

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

            do {
                try await Task.sleep(nanoseconds: livePreviewBatchIntervalNanoseconds)
            } catch { break }
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

    private func loadStillPreview(for descriptor: WindowDescriptor, generation: UInt64) async {
        guard !Task.isCancelled else {
            return
        }

        guard let image = await Self.captureOffMainActor(
            shareableWindow: descriptor.shareableWindow,
            targetFrame: descriptor.targetFrame,
            longestEdge: 1000
        ) else {
            stillTasks.removeValue(forKey: descriptor.id)
            return
        }

        guard !Task.isCancelled,
              generation == self.generation,
              snapshot?.windows.contains(where: { $0.id == descriptor.id }) == true else {
            stillTasks.removeValue(forKey: descriptor.id)
            return
        }

        descriptor.updatePreviewImage(image)
        previewCache[descriptor.id] = image
        stillTasks.removeValue(forKey: descriptor.id)
    }

    /// Captures a batch of windows concurrently. Must be `nonisolated` so `withTaskGroup` child tasks are not MainActor-isolated.
    private nonisolated static func captureBatch(_ descriptors: [WindowDescriptor]) async -> [(WindowDescriptor, CGImage)] {
        await withTaskGroup(of: (WindowDescriptor, CGImage?).self) { group in
            for descriptor in descriptors {
                let sw = descriptor.shareableWindow
                let tf = descriptor.targetFrame
                group.addTask {
                    let image = await captureOffMainActor(shareableWindow: sw, targetFrame: tf, longestEdge: 720)
                    return (descriptor, image)
                }
            }
            var results: [(WindowDescriptor, CGImage)] = []
            for await (descriptor, image) in group {
                if let image {
                    results.append((descriptor, image))
                }
            }
            return results
        }
    }

    /// Runs the actual ScreenCaptureKit call in a detached context so it
    /// never blocks the main actor.
    private nonisolated static func captureOffMainActor(
        shareableWindow: SCWindow?,
        targetFrame: CGRect,
        longestEdge: CGFloat
    ) async -> CGImage? {
        guard let shareableWindow else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
        let configuration = SCStreamConfiguration()
        let targetLongestEdge = max(targetFrame.width, targetFrame.height)
        let scale = max(1.0, min(3.0, longestEdge / max(targetLongestEdge, 1)))
        configuration.width = max(320, size_t(targetFrame.width * scale))
        configuration.height = max(200, size_t(targetFrame.height * scale))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
