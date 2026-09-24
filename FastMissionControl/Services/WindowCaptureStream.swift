import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import ScreenCaptureKit

/// Retain the pixel buffer while its surface is displayed so the capture pool cannot reuse it.
nonisolated struct WindowStreamFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let surface: IOSurface
    let contentsRect: CGRect

    init?(sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let metadata = attachments.first,
              let status = metadata[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return nil }

        self.pixelBuffer = pixelBuffer
        self.surface = surface
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let dictionary = metadata[.contentRect] as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: dictionary),
           let scale = metadata[.scaleFactor] as? CGFloat,
           width > 0, height > 0 {
            let normalized = CGRect(
                x: rect.minX * scale / width, y: rect.minY * scale / height,
                width: rect.width * scale / width, height: rect.height * scale / height
            ).intersection(unitRect)
            contentsRect = normalized.isEmpty || normalized.isNull ? unitRect : normalized
        } else {
            contentsRect = unitRect
        }
    }
}

/// ScreenCaptureKit calls this on a background queue. The bounded channel replaces stale frames
/// instead of creating a main-thread task for every callback.
nonisolated private final class WindowStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let continuation: AsyncThrowingStream<WindowStreamFrame, Error>.Continuation

    init(continuation: AsyncThrowingStream<WindowStreamFrame, Error>.Continuation) {
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, let frame = WindowStreamFrame(sampleBuffer: sampleBuffer) else { return }
        continuation.yield(frame)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation.finish(throwing: error)
    }
}

@MainActor
final class WindowCaptureStream {
    private static let outputQueue = DispatchQueue(
        label: "FastMissionControl.preview-streams", qos: .userInitiated
    )
    private let stream: SCStream
    private let output: WindowStreamOutput
    private var startTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var pendingConfiguration: SCStreamConfiguration?
    private var stopped = false

    init(window: SCWindow, configuration: SCStreamConfiguration,
         onFrame: @escaping (WindowStreamFrame) -> Void,
         onFailure: @escaping (Error) -> Void) throws {
        let (frames, continuation) = AsyncThrowingStream<WindowStreamFrame, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        output = WindowStreamOutput(continuation: continuation)
        stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration, delegate: output
        )
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: Self.outputQueue)

        frameTask = Task { [weak self] in
            do {
                for try await frame in frames {
                    guard let self, !self.stopped, !Task.isCancelled else { return }
                    onFrame(frame)
                }
            } catch {
                guard let self, !self.stopped, !Task.isCancelled else { return }
                onFailure(error)
            }
        }
        let stream = stream
        startTask = Task {
            do {
                try await stream.startCapture()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Serialize configuration changes; rapid hover changes replace the pending request.
    func update(configuration: SCStreamConfiguration) {
        guard !stopped else { return }
        pendingConfiguration = configuration
        guard configurationTask == nil else { return }
        configurationTask = Task { [weak self] in
            guard let self else { return }
            await self.startTask?.value
            while !self.stopped, !Task.isCancelled, let next = self.pendingConfiguration {
                self.pendingConfiguration = nil
                do {
                    try await self.stream.updateConfiguration(next)
                } catch {
                    self.output.continuation.finish(throwing: error)
                    break
                }
            }
            self.configurationTask = nil
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        pendingConfiguration = nil
        configurationTask?.cancel()
        frameTask?.cancel()
        output.continuation.finish()
        let stream = stream
        let startTask = startTask
        Task {
            // A stop racing a start must also stop the session once startup returns.
            await startTask?.value
            try? await stream.stopCapture()
        }
    }
}
