import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit

nonisolated struct ScreenshotConfiguration: Hashable, Sendable {
    let width: Int
    let height: Int
    let colorSpaceName: String?
    let prefersHDR: Bool
}

/// Owns capture setup away from the UI actor. Cached configurations are immutable after creation;
/// overlapping captures retain their own references even when a cache entry is replaced or evicted.
actor WindowScreenshotCapture {
    private struct Entry {
        let token = UUID()
        let pid: pid_t?
        let bundleIdentifier: String?
        let sourceFrame: CGRect
        let filter: SCContentFilter
        var configurations: [ScreenshotConfiguration: SCStreamConfiguration] = [:]
        var lastUsed: UInt64
    }

    private var entries: [CGWindowID: Entry] = [:]
    private var accessCounter: UInt64 = 0

    func capture(
        window: SCWindow,
        configuration: ScreenshotConfiguration,
        reuseSetup: Bool
    ) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        accessCounter &+= 1
        let windowID = window.windowID
        let pid = window.owningApplication?.processID
        let bundleIdentifier = window.owningApplication?.bundleIdentifier
        var entry: Entry
        if reuseSetup, let cached = entries[windowID],
           cached.pid == pid, cached.bundleIdentifier == bundleIdentifier,
           cached.sourceFrame == window.frame {
            entry = cached
        } else {
            entry = Entry(
                pid: pid, bundleIdentifier: bundleIdentifier, sourceFrame: window.frame,
                filter: SCContentFilter(desktopIndependentWindow: window), lastUsed: accessCounter
            )
        }
        let streamConfiguration: SCStreamConfiguration
        if let cached = entry.configurations[configuration] {
            streamConfiguration = cached
        } else {
            streamConfiguration = Self.makeConfiguration(configuration)
            // Keep both still and live resolutions, without retaining every historical layout.
            if entry.configurations.count >= 2 { entry.configurations.removeAll() }
            entry.configurations[configuration] = streamConfiguration
        }
        entry.lastUsed = accessCounter
        if reuseSetup {
            entries[windowID] = entry
            if entries.count > 48, let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                entries.removeValue(forKey: oldest.key)
            }
        } else {
            entries.removeValue(forKey: windowID)
        }

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: entry.filter, configuration: streamConfiguration
            )
            return Task.isCancelled ? nil : image
        } catch {
            // A closed window or stale filter must not poison later attempts. Do not evict a
            // replacement entry installed while this capture was awaiting the system.
            if entries[windowID]?.token == entry.token { entries.removeValue(forKey: windowID) }
            return nil
        }
    }

    private static func makeConfiguration(_ options: ScreenshotConfiguration) -> SCStreamConfiguration {
        let configuration: SCStreamConfiguration
        if #available(macOS 15.0, *), options.prefersHDR {
            configuration = SCStreamConfiguration(preset: .captureHDRScreenshotLocalDisplay)
            configuration.captureDynamicRange = .hdrLocalDisplay
        } else {
            configuration = SCStreamConfiguration()
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            if let name = options.colorSpaceName { configuration.colorSpaceName = name as CFString }
        }
        configuration.width = options.width
        configuration.height = options.height
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        return configuration
    }
}
