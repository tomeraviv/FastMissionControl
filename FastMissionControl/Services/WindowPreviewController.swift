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
import Combine
import ScreenCaptureKit

@MainActor
final class PreviewPerformanceModel: ObservableObject {
    @Published private(set) var displayedFPS = 0
    @Published private(set) var liveSessionCount = 0
    @Published private(set) var liveFrozen = true

    private var frameCount = 0
    private var lastFPSUpdate = ContinuousClock.now

    func reset() {
        displayedFPS = 0
        liveSessionCount = 0
        liveFrozen = true
        frameCount = 0
        lastFPSUpdate = ContinuousClock.now
    }

    func setLiveFrozen(_ value: Bool) {
        liveFrozen = value
        if value {
            displayedFPS = 0
            frameCount = 0
            lastFPSUpdate = ContinuousClock.now
        }
    }

    func setLiveSessionCount(_ count: Int) {
        liveSessionCount = count
    }

    func recordLiveFrame() {
        frameCount += 1

        let now = ContinuousClock.now
        let elapsed = now - lastFPSUpdate
        guard elapsed >= .seconds(1) else {
            return
        }

        let elapsedSeconds = max(1.0, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000)
        displayedFPS = Int(Double(frameCount) / elapsedSeconds)
        frameCount = 0
        lastFPSUpdate = now
    }
}

@MainActor
final class WindowPreviewController {
    let performance = PreviewPerformanceModel()

    private var snapshot: OverviewSnapshot?
    private var hoveredWindowID: CGWindowID?
    private var liveSessions: [CGWindowID: WindowStreamSession] = [:]
    private var stillTasks: [CGWindowID: Task<Void, Never>] = [:]
    private var livePreviewsEnabled = false
    private var previewCache: [CGWindowID: CGImage] = [:]
    private var generation: UInt64 = 0

    func prepare(snapshot: OverviewSnapshot, startStillLoading: Bool) {
        stopCurrentWork()
        generation &+= 1
        self.snapshot = snapshot
        hoveredWindowID = nil
        livePreviewsEnabled = false
        performance.reset()

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

            guard let image = await Self.captureStill(for: descriptor) else {
                continue
            }

            previewCache[descriptor.id] = image
            descriptor.previewImage = image
        }
    }

    func startLivePreviews() {
        guard snapshot != nil else {
            return
        }

        livePreviewsEnabled = true
        performance.setLiveFrozen(false)
        refreshLiveSessions()
    }

    func stopAll() {
        stopCurrentWork()
        generation &+= 1
        snapshot = nil
        hoveredWindowID = nil
        livePreviewsEnabled = false
        performance.reset()
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
        refreshLiveSessions()
    }

    private func refreshLiveSessions() {
        guard let snapshot else {
            stopAll()
            return
        }

        guard livePreviewsEnabled else {
            for session in liveSessions.values {
                session.stop()
            }

            liveSessions.removeAll()
            performance.setLiveSessionCount(0)
            return
        }

        let desiredWindows: [WindowDescriptor]
        if let hoveredWindowID,
           let hoveredWindow = snapshot.windows.first(where: { $0.id == hoveredWindowID }) {
            desiredWindows = [hoveredWindow]
        } else {
            desiredWindows = []
        }
        let desiredIDs = Set(desiredWindows.map(\.id))

        for (windowID, session) in liveSessions where !desiredIDs.contains(windowID) {
            session.stop()
            liveSessions.removeValue(forKey: windowID)
        }

        for descriptor in desiredWindows {
            if liveSessions[descriptor.id] != nil {
                continue
            }

            do {
                let session = try WindowStreamSession(
                    descriptor: descriptor,
                    fps: 10,
                    longestEdge: 1600,
                    onFrame: { [weak self] windowID, image in
                        self?.previewCache[windowID] = image
                    },
                    onFrameDelivered: { [weak self] in
                        self?.performance.recordLiveFrame()
                    }
                )
                liveSessions[descriptor.id] = session
                session.start()
            } catch {
                // Still previews remain available even if live capture fails.
            }
        }

        performance.setLiveSessionCount(liveSessions.count)
    }

    private func prewarmPriority(for descriptor: WindowDescriptor, cursorDisplayID: CGDirectDisplayID?) -> Int {
        var score = 1_000 - descriptor.zIndex
        if descriptor.displayID == cursorDisplayID {
            score += 2_000
        }
        return score
    }

    private func stopCurrentWork() {
        for task in stillTasks.values {
            task.cancel()
        }

        stillTasks.removeAll()

        for session in liveSessions.values {
            session.stop()
        }

        liveSessions.removeAll()
        performance.setLiveSessionCount(0)
    }

    /// Assigns cached preview images to the given snapshot's descriptors.
    /// Called during prewarm (before building the overlay controller) so
    /// that card layers start with thumbnails instead of blank rects.
    func applyCachedPreviews(to snapshot: OverviewSnapshot) {
        for descriptor in snapshot.windows {
            if let previewImage = descriptor.previewImage {
                previewCache[descriptor.id] = previewImage
                continue
            }

            if let cachedPreview = previewCache[descriptor.id] {
                descriptor.previewImage = cachedPreview
            }
        }
    }

    private func loadStillPreview(for descriptor: WindowDescriptor, generation: UInt64) async {
        guard !Task.isCancelled else {
            return
        }

        guard let image = await Self.captureStill(for: descriptor) else {
            // Keep the most recent cached frame if a still capture fails.
            stillTasks.removeValue(forKey: descriptor.id)
            return
        }

        guard !Task.isCancelled,
              generation == self.generation,
              snapshot?.windows.contains(where: { $0.id == descriptor.id }) == true else {
            stillTasks.removeValue(forKey: descriptor.id)
            return
        }

        descriptor.previewImage = image
        previewCache[descriptor.id] = image
        stillTasks.removeValue(forKey: descriptor.id)
    }

    private static func captureStill(for descriptor: WindowDescriptor) async -> CGImage? {
        guard let shareableWindow = descriptor.shareableWindow else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
        let configuration = makeStillConfiguration(for: descriptor)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private static func makeStillConfiguration(for descriptor: WindowDescriptor) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        applyResolution(to: configuration, for: descriptor, longestEdge: 1000)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 2
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        return configuration
    }

    private func makeStreamConfiguration(for descriptor: WindowDescriptor, fps: Int) -> SCStreamConfiguration {
        let configuration = Self.makeStillConfiguration(for: descriptor)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        return configuration
    }

    fileprivate static func applyResolution(to configuration: SCStreamConfiguration, for descriptor: WindowDescriptor, longestEdge: CGFloat) {
        let targetLongestEdge = max(descriptor.targetFrame.width, descriptor.targetFrame.height)
        let scale = max(1.0, min(3.0, longestEdge / max(targetLongestEdge, 1)))
        configuration.width = max(320, size_t(descriptor.targetFrame.width * scale))
        configuration.height = max(200, size_t(descriptor.targetFrame.height * scale))
    }
}

private final class WindowStreamSession: NSObject, SCStreamOutput {
    private enum State {
        case idle
        case starting
        case running
        case stopping
        case stopped
    }

    private let descriptor: WindowDescriptor
    private let outputQueue: DispatchQueue
    private let imageHandler: @MainActor (CGImage) -> Void
    private let frameDeliveredHandler: @MainActor () -> Void
    private let stream: SCStream
    private var state: State = .idle
    private var outputAdded = false
    private var didStartCapture = false
    private var startTask: Task<Void, Never>?

    private static let ciContext = CIContext(options: [
        .cacheIntermediates: false
    ])

    init(
        descriptor: WindowDescriptor,
        fps: Int,
        longestEdge: CGFloat,
        onFrame: @escaping @MainActor (CGWindowID, CGImage) -> Void,
        onFrameDelivered: @escaping @MainActor () -> Void
    ) throws {
        self.descriptor = descriptor
        self.outputQueue = DispatchQueue(label: "FastMissionControl.WindowStream.\(descriptor.id)", qos: .userInteractive)
        let windowID = descriptor.id
        self.imageHandler = { [weak descriptor] image in
            descriptor?.previewImage = image
            onFrame(windowID, image)
        }
        self.frameDeliveredHandler = onFrameDelivered

        guard let shareableWindow = descriptor.shareableWindow else {
            throw NSError(domain: "FastMissionControl", code: -1, userInfo: [NSLocalizedDescriptionKey: "No shareable window"])
        }
        let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
        let configuration = SCStreamConfiguration()
        WindowPreviewController.applyResolution(to: configuration, for: descriptor, longestEdge: longestEdge)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 2
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true

        stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        super.init()
    }

    func start() {
        guard state == .idle || state == .stopped else {
            return
        }

        state = .starting
        didStartCapture = false

        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
            outputAdded = true
        } catch {
            cleanupStopped()
            return
        }

        startTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await self.stream.startCapture()
                await MainActor.run {
                    self.didStartCapture = true
                    if self.state == .starting {
                        self.state = .running
                    }
                }
            } catch {
                await MainActor.run {
                    if self.state == .starting {
                        self.cleanupStopped()
                    }
                }
            }
        }
    }

    func stop() {
        guard state == .starting || state == .running else {
            return
        }

        state = .stopping
        let startTask = self.startTask

        Task { [weak self] in
            guard let self else {
                return
            }

            await startTask?.value
            let didStartCapture = await MainActor.run { self.didStartCapture }

            if didStartCapture {
                try? await self.stream.stopCapture()
            }

            await MainActor.run {
                self.cleanupStopped()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard state == .running,
              outputType == .screen,
              let imageBuffer = sampleBuffer.imageBuffer else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }

        Task { @MainActor in
            self.imageHandler(cgImage)
            self.frameDeliveredHandler()
        }
    }

    @MainActor
    private func cleanupStopped() {
        startTask = nil
        didStartCapture = false

        if outputAdded {
            try? stream.removeStreamOutput(self, type: .screen)
            outputAdded = false
        }

        state = .stopped
    }
}
