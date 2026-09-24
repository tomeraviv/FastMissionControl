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
import OSLog
import ScreenCaptureKit

@MainActor
final class WindowPreviewController {
    var onStreamFailure: ((Int) -> Void)?
    private struct CaptureDisplayConfiguration {
        let colorSpaceName: String?
        let prefersHDR: Bool
        let backingScale: CGFloat
    }

    private struct CachedPreviewSignature: Equatable {
        let windowID: CGWindowID
        let pid: pid_t
        let displayID: CGDirectDisplayID
        let bundleIdentifier: String?
        let title: String?
        let frame: CGRect
    }

    private struct CachedPreview {
        let image: CGImage?
        let streamFrame: WindowStreamFrame?
        let signature: CachedPreviewSignature
        let capturedAt: TimeInterval
    }

    private final class StreamRecord {
        let token = UUID()
        var descriptor: WindowDescriptor
        var interval: UInt64
        var session: WindowCaptureStream?

        init(descriptor: WindowDescriptor, interval: UInt64) {
            self.descriptor = descriptor
            self.interval = interval
        }
    }

    private let settings: AppSettings
    private let screenshotCapture = WindowScreenshotCapture()
    private var snapshot: OverviewSnapshot?
    private var hoveredWindowID: CGWindowID?
    private var liveRefreshTask: Task<Void, Never>?
    private var stillTasks: [CGWindowID: Task<Void, Never>] = [:]
    private var attemptedStillWindowIDs: Set<CGWindowID> = []
    private var stillLoadingEnabled = false
    private var refreshCachedStillPreviews = false
    private var livePreviewsEnabled = false
    private var previewUpdatesSuspended = false
    private var capturesAllowed = true
    private var previewCache: [CGWindowID: CachedPreview] = [:]
    private var cachedPreviewWindowIDs: Set<CGWindowID> = []
    private var generation: UInt64 = 0
    private var livePreviewIntervalNanoseconds: UInt64
    private let maxPreviewCacheEntries = 48
    private var usesStreaming = false
    private var streams: [CGWindowID: StreamRecord] = [:]
    private var failedStreamIDs: Set<CGWindowID> = []
    private var backgroundSnapshot: OverviewSnapshot?
    private let logger = Logger(subsystem: "FastMissionControl", category: "PreviewCapture")

    init(settings: AppSettings) {
        self.settings = settings
        livePreviewIntervalNanoseconds = settings.defaultLivePreviewIntervalNanoseconds
    }

    func setPreviewUpdatesSuspended(_ suspended: Bool) {
        previewUpdatesSuspended = suspended
        if !suspended, usesStreaming, let snapshot {
            for descriptor in snapshot.windows {
                if let frame = previewCache[descriptor.id]?.streamFrame {
                    descriptor.updateStreamFrame(frame)
                }
            }
        }
    }

    func setCapturesAllowed(_ allowed: Bool) {
        guard capturesAllowed != allowed else {
            return
        }

        capturesAllowed = allowed

        if allowed {
            resumeCaptureWorkIfNeeded()
        } else {
            stopCurrentWork()
            stopStreams()
        }
    }

    func prepare(snapshot: OverviewSnapshot, startStillLoading: Bool) {
        stopCurrentWork()
        selectCaptureEngine()
        failedStreamIDs.removeAll()
        self.snapshot = snapshot
        backgroundSnapshot = nil
        hoveredWindowID = nil
        livePreviewsEnabled = false
        previewUpdatesSuspended = false
        livePreviewIntervalNanoseconds = defaultLivePreviewIntervalNanoseconds()

        cachedPreviewWindowIDs.removeAll()
        prunePreviewCache(keeping: snapshot.windows)
        applyCachedPreviews(to: snapshot)

        if usesStreaming {
            // Rebind warmed streams immediately; never await a stream starting in the open path.
            synchronizeStreams(with: snapshot)
        }

        if startStillLoading, capturesAllowed {
            startStillPreviewLoading()
        }
    }

    func prewarm(snapshot: OverviewSnapshot, forceRefresh: Bool = false) async {
        guard !Task.isCancelled, capturesAllowed, self.snapshot == nil else {
            return
        }

        prunePreviewCache(keeping: snapshot.windows)
        selectCaptureEngine()
        if usesStreaming {
            backgroundSnapshot = snapshot
            synchronizeStreams(with: snapshot)
            return
        }

        let priorityWindows = snapshot.windows.sorted { lhs, rhs in
            prewarmPriority(for: lhs, cursorDisplayID: snapshot.cursorDisplayID) > prewarmPriority(for: rhs, cursorDisplayID: snapshot.cursorDisplayID)
        }
        let cacheableWindows = priorityWindows.prefix(maxPreviewCacheEntries)

        for descriptor in cacheableWindows where forceRefresh || cachedPreview(for: descriptor) == nil {
            guard !Task.isCancelled, capturesAllowed else {
                return
            }

            guard let image = await captureScreenshot(for: descriptor, longestEdge: 1000) else {
                continue
            }

            guard !Task.isCancelled, capturesAllowed else { return }
            cachePreview(image, for: descriptor, preferredWindowIDs: snapshot.windows.map(\.id))
            descriptor.updatePreviewImage(image)
        }
    }

    func startLivePreviews() {
        guard snapshot != nil else {
            return
        }

        livePreviewsEnabled = true
        guard capturesAllowed else {
            return
        }
        if usesStreaming, let snapshot {
            synchronizeStreams(with: snapshot)
            return
        }
        ensureLiveLoopRunning()
    }

    func shareableWindowsDidResolve() {
        guard capturesAllowed else { return }
        if usesStreaming, let snapshot {
            synchronizeStreams(with: snapshot)
            if settings.bool(.fillMissingPreviewsImmediately) || livePreviewsEnabled {
                startStillPreviewLoading(onlyMissing: previewUpdatesSuspended)
            }
            return
        }
        if settings.bool(.fillMissingPreviewsImmediately) {
            startStillPreviewLoading(onlyMissing: previewUpdatesSuspended)
        } else if livePreviewsEnabled {
            startStillPreviewLoading()
        }
        if livePreviewsEnabled { ensureLiveLoopRunning() }
    }

    func stopAll() {
        stopCurrentWork()
        backgroundSnapshot = snapshot ?? backgroundSnapshot
        snapshot = nil
        hoveredWindowID = nil
        livePreviewsEnabled = false
        livePreviewIntervalNanoseconds = defaultLivePreviewIntervalNanoseconds()
        if usesStreaming, capturesAllowed, let backgroundSnapshot {
            synchronizeStreams(with: backgroundSnapshot)
        } else {
            stopStreams()
        }
    }

    func shutdown() {
        stopCurrentWork()
        stopStreams()
        snapshot = nil
        backgroundSnapshot = nil
    }

    func settingsDidChange() {
        // A running overview keeps its engine until the next open so comparisons are consistent.
        guard snapshot == nil else { return }
        selectCaptureEngine()
    }

    func startStillPreviewLoading(onlyMissing: Bool = false) {
        if usesStreaming, let snapshot { synchronizeStreams(with: snapshot) }
        stillLoadingEnabled = true
        if !onlyMissing { refreshCachedStillPreviews = true }
        scheduleStillPreviews()
    }

    private func scheduleStillPreviews() {
        guard stillLoadingEnabled, capturesAllowed, let snapshot else { return }
        let limit = settings.bool(.limitStillCaptureConcurrency)
            ? settings.livePreviewCaptureConcurrencyLimit
            : max(snapshot.windows.count, 1)
        let availableSlots = max(0, limit - stillTasks.count)
        guard availableSlots > 0 else { return }
        let candidates = snapshot.windows.filter { shouldLoadStillPreview(for: $0) }.sorted {
            if $0.hasPreview != $1.hasPreview {
                return !$0.hasPreview
            }
            return prewarmPriority(for: $0, cursorDisplayID: snapshot.cursorDisplayID)
                > prewarmPriority(for: $1, cursorDisplayID: snapshot.cursorDisplayID)
        }
        let currentGeneration = generation
        for descriptor in candidates.prefix(availableSlots) {
            attemptedStillWindowIDs.insert(descriptor.id)
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
        if usesStreaming, let snapshot { synchronizeStreams(with: snapshot) }
    }

    // MARK: - Live preview polling loop

    private func ensureLiveLoopRunning() {
        guard !usesStreaming else { return }
        guard liveRefreshTask == nil else { return }
        let currentGeneration = generation
        liveRefreshTask = Task { [weak self] in
            await self?.runLivePreviewLoop(generation: currentGeneration)
        }
    }

    private func runLivePreviewLoop(generation: UInt64) async {
        defer {
            if generation == self.generation { liveRefreshTask = nil }
        }
        while !Task.isCancelled {
            guard livePreviewsEnabled,
                  capturesAllowed,
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

            if previewUpdatesSuspended {
                if await sleepForCurrentInterval(suspendedPreviewIntervalNanoseconds) == false {
                    break
                }
                continue
            }

            if settings.bool(.limitStillCaptureConcurrency), !stillTasks.isEmpty {
                // Let the bounded initial queue finish before spending more capture slots on
                // live updates of the same windows.
                if await sleepForCurrentInterval(suspendedPreviewIntervalNanoseconds) == false {
                    break
                }
                continue
            }

            let captureStart = DispatchTime.now().uptimeNanoseconds
            await captureBatch(
                desiredWindows,
                generation: generation,
                maxConcurrentCaptures: settings.livePreviewCaptureConcurrencyLimit
            )
            let captureDurationNanoseconds = DispatchTime.now().uptimeNanoseconds - captureStart

            guard !Task.isCancelled,
                  generation == self.generation,
                  livePreviewsEnabled else {
                return
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

    private func selectCaptureEngine() {
        let enabled = settings.bool(.streamingPreviews)
        guard enabled != usesStreaming else { return }
        stopStreams()
        failedStreamIDs.removeAll()
        usesStreaming = enabled
    }

    private func stopStreams() {
        let oldStreams = streams.values.map(\.session)
        streams.removeAll()
        for session in oldStreams { session?.stop() }
    }

    private func synchronizeStreams(with source: OverviewSnapshot) {
        guard usesStreaming, capturesAllowed else { return }
        // Fairly share the budget across displays, including warmed windows whose SCWindow
        // handles are still resolving in the new snapshot.
        let eligible = source.windows.filter { $0.shareableWindow != nil || streams[$0.id] != nil }
        let byDisplay = Dictionary(grouping: eligible, by: \.displayID)
        let displayIDs = byDisplay.keys.sorted()
        var targets: [WindowDescriptor] = []
        var offset = 0
        while targets.count < maxPreviewCacheEntries {
            let row = displayIDs.compactMap { id -> WindowDescriptor? in
                guard let windows = byDisplay[id], offset < windows.count else { return nil }
                return windows[offset]
            }
            guard !row.isEmpty else { break }
            targets.append(contentsOf: row.prefix(maxPreviewCacheEntries - targets.count))
            offset += 1
        }
        if let hoveredWindowID,
           !targets.contains(where: { $0.id == hoveredWindowID }),
           let hovered = eligible.first(where: { $0.id == hoveredWindowID }) {
            if targets.count == maxPreviewCacheEntries { targets.removeLast() }
            targets.append(hovered)
        }

        let wantedIDs = Set(targets.map(\.id))
        for id in Array(streams.keys) where !wantedIDs.contains(id) {
            streams.removeValue(forKey: id)?.session?.stop()
        }
        let liveIDs = Set(livePreviewDescriptors(from: source).map(\.id))
        for descriptor in targets {
            guard !failedStreamIDs.contains(descriptor.id) else { continue }
            let interval: UInt64
            if snapshot == nil || !livePreviewsEnabled {
                interval = 1_000_000_000
            } else if descriptor.id == hoveredWindowID {
                interval = settings.livePreviewMinIntervalNanoseconds
            } else if liveIDs.contains(descriptor.id) {
                interval = settings.defaultLivePreviewIntervalNanoseconds
            } else {
                interval = 200_000_000
            }

            if let existing = streams[descriptor.id] {
                let old = existing.descriptor
                if old.pid == descriptor.pid,
                   old.bundleIdentifier == descriptor.bundleIdentifier,
                   old.sourceFrame.size == descriptor.sourceFrame.size,
                   old.displayID == descriptor.displayID {
                    existing.descriptor = descriptor
                    if existing.interval != interval {
                        existing.interval = interval
                        existing.session?.update(configuration: streamConfiguration(for: descriptor, interval: interval))
                    }
                    continue
                }
                streams.removeValue(forKey: descriptor.id)?.session?.stop()
            }
            guard let window = descriptor.shareableWindow else { continue }
            let record = StreamRecord(descriptor: descriptor, interval: interval)
            let id = descriptor.id
            let token = record.token
            streams[id] = record
            do {
                record.session = try WindowCaptureStream(
                    window: window,
                    configuration: streamConfiguration(for: descriptor, interval: interval),
                    onFrame: { [weak self] frame in
                        self?.receiveStreamFrame(frame, windowID: id, token: token)
                    },
                    onFailure: { [weak self] error in
                        self?.streamFailed(windowID: id, token: token, error: error)
                    }
                )
            } catch {
                streamFailed(windowID: id, token: token, error: error)
            }
        }
    }

    private func receiveStreamFrame(_ frame: WindowStreamFrame, windowID: CGWindowID, token: UUID) {
        guard capturesAllowed, usesStreaming,
              let record = streams[windowID], record.token == token else { return }
        let descriptor = record.descriptor
        previewCache[windowID] = CachedPreview(
            image: nil, streamFrame: frame, signature: cacheSignature(for: descriptor),
            capturedAt: ProcessInfo.processInfo.systemUptime
        )
        cachedPreviewWindowIDs.remove(windowID)
        if let snapshot,
           snapshot.windows.contains(where: { $0 === descriptor }),
           !previewUpdatesSuspended
               || (settings.bool(.fillMissingPreviewsImmediately) && !descriptor.hasPreview) {
            descriptor.updateStreamFrame(frame)
        }
        if previewCache.count > maxPreviewCacheEntries {
            enforcePreviewCacheLimit(preferredWindowIDs: Array(streams.keys).sorted())
        }
    }

    private func streamFailed(windowID: CGWindowID, token: UUID, error: Error) {
        guard let record = streams[windowID], record.token == token else { return }
        failedStreamIDs.insert(windowID)
        streams.removeValue(forKey: windowID)?.session?.stop()
        onStreamFailure?(failedStreamIDs.count)
        logger.error("Preview stream failed for window \(windowID): \(error.localizedDescription, privacy: .public)")
        // Retry streams next time the overview opens; keep this session usable with stills.
        if snapshot != nil {
            cachedPreviewWindowIDs.insert(windowID)
            stillLoadingEnabled = true
            refreshCachedStillPreviews = true
            scheduleStillPreviews()
        }
    }

    private func streamConfiguration(for descriptor: WindowDescriptor, interval: UInt64) -> SCStreamConfiguration {
        let display = captureDisplayConfiguration(for: descriptor.displayID)
        let configuration: SCStreamConfiguration
        if #available(macOS 15.0, *), display.prefersHDR {
            configuration = SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)
        } else {
            configuration = SCStreamConfiguration()
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            if let colorSpaceName = display.colorSpaceName {
                configuration.colorSpaceName = colorSpaceName as CFString
            }
        }
        // Keep resolution stable across layout and hover changes to avoid reallocating the pool.
        let size = descriptor.sourceFrame.size
        let scale = min(1, 1000 / max(size.width, size.height, 1))
        configuration.width = max(2, Int(ceil(size.width * scale / 2)) * 2)
        configuration.height = max(2, Int(ceil(size.height * scale / 2)) * 2)
        configuration.minimumFrameInterval = CMTime(value: Int64(interval), timescale: 1_000_000_000)
        configuration.queueDepth = 4
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        return configuration
    }

    private func stopCurrentWork() {
        generation &+= 1
        stillLoadingEnabled = false
        refreshCachedStillPreviews = false
        attemptedStillWindowIDs.removeAll()
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
            if descriptor.streamFrame != nil {
                cachedPreviewWindowIDs.insert(descriptor.id)
                continue
            }
            if let previewImage = descriptor.previewImage {
                if previewCache[descriptor.id] == nil {
                    cachePreview(previewImage, for: descriptor, preferredWindowIDs: snapshot.windows.map(\.id))
                } else {
                    cachedPreviewWindowIDs.insert(descriptor.id)
                }
                continue
            }

            if let cachedPreview = cachedPreview(for: descriptor) {
                if let frame = cachedPreview.streamFrame {
                    descriptor.updateStreamFrame(frame)
                } else {
                    descriptor.updatePreviewImage(cachedPreview.image)
                }
                cachedPreviewWindowIDs.insert(descriptor.id)
            }
        }
        enforcePreviewCacheLimit(preferredWindowIDs: snapshot.windows.map(\.id))
    }

    private func shouldLoadStillPreview(for descriptor: WindowDescriptor) -> Bool {
        // Streams provide their own first frames. Keep screenshots only as a fallback for a
        // failed stream or windows beyond the stream budget.
        guard !usesStreaming || streams[descriptor.id] == nil else { return false }
        guard descriptor.shareableWindow != nil,
              stillTasks[descriptor.id] == nil,
              !attemptedStillWindowIDs.contains(descriptor.id) else {
            return false
        }

        return !descriptor.hasPreview
            || (refreshCachedStillPreviews && cachedPreviewWindowIDs.contains(descriptor.id))
    }

    private func cachedPreview(for descriptor: WindowDescriptor) -> CachedPreview? {
        guard let cached = previewCache[descriptor.id] else {
            return nil
        }

        guard canReuse(cached, for: cacheSignature(for: descriptor)) else {
            previewCache.removeValue(forKey: descriptor.id)
            cachedPreviewWindowIDs.remove(descriptor.id)
            return nil
        }

        return cached
    }

    private func cachePreview(
        _ image: CGImage,
        for descriptor: WindowDescriptor,
        preferredWindowIDs: [CGWindowID]
    ) {
        previewCache[descriptor.id] = CachedPreview(
            image: image,
            streamFrame: nil,
            signature: cacheSignature(for: descriptor),
            capturedAt: ProcessInfo.processInfo.systemUptime
        )
        cachedPreviewWindowIDs.remove(descriptor.id)
        enforcePreviewCacheLimit(preferredWindowIDs: preferredWindowIDs)
    }

    private func cacheSignature(for descriptor: WindowDescriptor) -> CachedPreviewSignature {
        CachedPreviewSignature(
            windowID: descriptor.id,
            pid: descriptor.pid,
            displayID: descriptor.displayID,
            bundleIdentifier: descriptor.bundleIdentifier,
            title: descriptor.title,
            frame: descriptor.sourceFrame.integral
        )
    }

    private func prunePreviewCache(keeping descriptors: [WindowDescriptor]) {
        let signaturesByWindowID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, cacheSignature(for: $0)) })
        previewCache = previewCache.filter { windowID, cached in
            guard let signature = signaturesByWindowID[windowID] else { return false }
            return canReuse(cached, for: signature)
        }
        cachedPreviewWindowIDs = cachedPreviewWindowIDs.intersection(Set(signaturesByWindowID.keys))
        enforcePreviewCacheLimit(preferredWindowIDs: descriptors.map(\.id))
    }

    private func canReuse(_ cached: CachedPreview, for signature: CachedPreviewSignature) -> Bool {
        if cached.signature == signature { return true }
        guard settings.bool(.reuseRecentPreviews),
              ProcessInfo.processInfo.systemUptime - cached.capturedAt <= 10 else { return false }
        // Reuse only the same window and owning app, at the same dimensions.
        return cached.signature.windowID == signature.windowID
            && cached.signature.pid == signature.pid
            && cached.signature.bundleIdentifier == signature.bundleIdentifier
            && cached.signature.frame.size == signature.frame.size
    }

    private func enforcePreviewCacheLimit(preferredWindowIDs: [CGWindowID]) {
        guard previewCache.count > maxPreviewCacheEntries else {
            return
        }

        let preferred = Array(preferredWindowIDs.prefix(maxPreviewCacheEntries))
        let keep = Set(preferred)
        previewCache = previewCache.filter { keep.contains($0.key) }
        cachedPreviewWindowIDs = cachedPreviewWindowIDs.intersection(keep)

        guard previewCache.count > maxPreviewCacheEntries else {
            return
        }

        for key in previewCache.keys.sorted().dropFirst(maxPreviewCacheEntries) {
            previewCache.removeValue(forKey: key)
            cachedPreviewWindowIDs.remove(key)
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
        defer {
            // A cancelled capture must not remove a replacement task from a newer overview.
            if generation == self.generation {
                stillTasks.removeValue(forKey: descriptor.id)
                scheduleStillPreviews()
            }
        }
        guard !Task.isCancelled, capturesAllowed else {
            return
        }

        guard let image = await captureScreenshot(for: descriptor, longestEdge: 1000) else {
            return
        }

        guard !Task.isCancelled,
              capturesAllowed,
              generation == self.generation,
              snapshot?.windows.contains(where: { $0.id == descriptor.id }) == true else {
            return
        }

        descriptor.updatePreviewImage(image)
        cachePreview(image, for: descriptor, preferredWindowIDs: snapshot?.windows.map(\.id) ?? [descriptor.id])
    }

    /// Bound capture work, but publish each completed image without a batch-wide presentation barrier.
    private func captureBatch(
        _ descriptors: [WindowDescriptor],
        generation: UInt64,
        maxConcurrentCaptures: Int
    ) async {
        guard capturesAllowed else { return }
        let concurrencyLimit = max(1, maxConcurrentCaptures)
        let publishImmediately = settings.bool(.publishScreenshotsImmediately)
        let preferredWindowIDs = snapshot?.windows.map(\.id) ?? []

        await withTaskGroup(of: (WindowDescriptor, CGImage?).self) { group in
            var pending = descriptors
            var inFlight = 0
            var results: [(WindowDescriptor, CGImage)] = []

            @MainActor func nextDescriptor() -> WindowDescriptor? {
                guard !pending.isEmpty else { return nil }
                // Pointer movement never pauses capture. Give a newly hovered window the next
                // available slot instead of making it wait behind the rest of the batch.
                if let index = pending.firstIndex(where: { $0.id == hoveredWindowID }) {
                    return pending.remove(at: index)
                }
                return pending.removeFirst()
            }

            while inFlight < concurrencyLimit, let descriptor = nextDescriptor() {
                addCaptureTask(for: descriptor, to: &group)
                inFlight += 1
            }

            while let (descriptor, image) = await group.next() {
                inFlight -= 1
                guard !Task.isCancelled, capturesAllowed,
                      generation == self.generation, livePreviewsEnabled else {
                    group.cancelAll()
                    return
                }
                if let image {
                    if publishImmediately {
                        publishLiveScreenshot(image, for: descriptor, preferredWindowIDs: preferredWindowIDs)
                    } else {
                        results.append((descriptor, image))
                    }
                }
                if !previewUpdatesSuspended, let next = nextDescriptor() {
                    addCaptureTask(for: next, to: &group)
                    inFlight += 1
                }
            }

            for (descriptor, image) in results {
                publishLiveScreenshot(image, for: descriptor, preferredWindowIDs: preferredWindowIDs)
            }
        }
    }

    private func publishLiveScreenshot(
        _ image: CGImage, for descriptor: WindowDescriptor, preferredWindowIDs: [CGWindowID]
    ) {
        // Identity prevents results from a replaced descriptor being applied after inventory refresh.
        guard snapshot?.windows.contains(where: { $0 === descriptor }) == true else { return }
        if !previewUpdatesSuspended { descriptor.updatePreviewImage(image) }
        cachePreview(image, for: descriptor, preferredWindowIDs: preferredWindowIDs)
    }

    private func addCaptureTask(
        for descriptor: WindowDescriptor,
        to group: inout TaskGroup<(WindowDescriptor, CGImage?)>
    ) {
        let window = descriptor.shareableWindow
        let configuration = screenshotConfiguration(for: descriptor, longestEdge: 720)
        let reuseSetup = settings.bool(.reuseScreenshotSetup)
        let capture = screenshotCapture
        group.addTask {
            guard !Task.isCancelled, let window else { return (descriptor, nil) }
            let image = await capture.capture(window: window, configuration: configuration, reuseSetup: reuseSetup)
            return (descriptor, image)
        }
    }

    private func captureScreenshot(for descriptor: WindowDescriptor, longestEdge: CGFloat) async -> CGImage? {
        guard !Task.isCancelled, let window = descriptor.shareableWindow else { return nil }
        return await screenshotCapture.capture(
            window: window,
            configuration: screenshotConfiguration(for: descriptor, longestEdge: longestEdge),
            reuseSetup: settings.bool(.reuseScreenshotSetup)
        )
    }

    private func screenshotConfiguration(for descriptor: WindowDescriptor, longestEdge: CGFloat) -> ScreenshotConfiguration {
        let display = captureDisplayConfiguration(for: descriptor.displayID)
        let target = descriptor.targetFrame.size
        let width: Int
        let height: Int
        if settings.bool(.rightSizeScreenshots) {
            // Layout uses points. Respect Retina pixels, then enforce the actual pixel budget.
            // Prewarming can precede layout; fall back to source dimensions in that case.
            let size = target.width > 0 && target.height > 0 ? target : descriptor.sourceFrame.size
            let pixelWidth = max(1, size.width * display.backingScale)
            let pixelHeight = max(1, size.height * display.backingScale)
            let scale = min(1, longestEdge / max(pixelWidth, pixelHeight))
            width = max(1, Int((pixelWidth * scale).rounded(.down)))
            height = max(1, Int((pixelHeight * scale).rounded(.down)))
        } else {
            let scale = max(1.0, min(3.0, longestEdge / max(target.width, target.height, 1)))
            width = max(320, Int(target.width * scale))
            height = max(200, Int(target.height * scale))
        }
        return ScreenshotConfiguration(
            width: width, height: height, colorSpaceName: display.colorSpaceName, prefersHDR: display.prefersHDR
        )
    }

    private func captureDisplayConfiguration(for displayID: CGDirectDisplayID) -> CaptureDisplayConfiguration {
        guard let screen = screen(for: displayID) else {
            return CaptureDisplayConfiguration(colorSpaceName: nil, prefersHDR: false, backingScale: 1)
        }

        return CaptureDisplayConfiguration(
            colorSpaceName: screen.colorSpace?.cgColorSpace?.name as String?,
            prefersHDR: screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0,
            backingScale: screen.backingScaleFactor
        )
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == UInt32(displayID)
        }
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

    private func resumeCaptureWorkIfNeeded() {
        guard snapshot != nil else {
            return
        }

        startStillPreviewLoading()

        if usesStreaming, let snapshot {
            synchronizeStreams(with: snapshot)
            return
        }

        guard livePreviewsEnabled else {
            return
        }

        ensureLiveLoopRunning()
    }
}
