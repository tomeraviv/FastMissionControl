//
//  CaptureAvailabilityMonitor.swift
//  FastMissionControl
//
//  Created by Codex.
//

import AppKit
import ApplicationServices
import Combine
import Foundation

@MainActor
final class CaptureAvailabilityMonitor: ObservableObject {
    @Published private(set) var allowsCapture = true

    private let workspace = NSWorkspace.shared
    private let idleTimeoutSeconds: TimeInterval
    private let idlePollIntervalNanoseconds: UInt64

    private var observerTokens: [NSObjectProtocol] = []
    private var idleMonitorTask: Task<Void, Never>?
    private var sessionActive = true
    private var displaysAwake = true
    private var systemAwake = true

    init(
        idleTimeoutSeconds: TimeInterval = 5.0,
        idlePollIntervalSeconds: TimeInterval = 0.25
    ) {
        self.idleTimeoutSeconds = idleTimeoutSeconds
        idlePollIntervalNanoseconds = UInt64(max(0.1, idlePollIntervalSeconds) * 1_000_000_000)
    }

    func start() {
        installObserversIfNeeded()
        refreshCaptureAvailability()
        startIdleMonitorIfNeeded()
    }

    func stop() {
        idleMonitorTask?.cancel()
        idleMonitorTask = nil

        for token in observerTokens {
            workspace.notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
    }

    private func installObserversIfNeeded() {
        guard observerTokens.isEmpty else {
            return
        }

        addObserver(for: NSWorkspace.sessionDidResignActiveNotification) { monitor in
            monitor.sessionActive = false
            monitor.refreshCaptureAvailability()
        }
        addObserver(for: NSWorkspace.sessionDidBecomeActiveNotification) { monitor in
            monitor.sessionActive = true
            monitor.refreshCaptureAvailability()
        }
        addObserver(for: NSWorkspace.screensDidSleepNotification) { monitor in
            monitor.displaysAwake = false
            monitor.refreshCaptureAvailability()
        }
        addObserver(for: NSWorkspace.screensDidWakeNotification) { monitor in
            monitor.displaysAwake = true
            monitor.refreshCaptureAvailability()
        }
        addObserver(for: NSWorkspace.willSleepNotification) { monitor in
            monitor.systemAwake = false
            monitor.refreshCaptureAvailability()
        }
        addObserver(for: NSWorkspace.didWakeNotification) { monitor in
            monitor.systemAwake = true
            monitor.refreshCaptureAvailability()
        }
    }

    private func startIdleMonitorIfNeeded() {
        guard idleMonitorTask == nil else {
            return
        }

        let idlePollIntervalNanoseconds = idlePollIntervalNanoseconds
        idleMonitorTask = Task { @MainActor [weak self, idlePollIntervalNanoseconds] in
            while !Task.isCancelled {
                self?.refreshCaptureAvailability()

                do {
                    try await Task.sleep(nanoseconds: idlePollIntervalNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    private func addObserver(
        for name: Notification.Name,
        update: @escaping @MainActor (CaptureAvailabilityMonitor) -> Void
    ) {
        let token = workspace.notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                update(self)
            }
        }
        observerTokens.append(token)
    }

    private func refreshCaptureAvailability() {
        let allowsCapture = sessionActive
            && displaysAwake
            && systemAwake
            && secondsSinceLastInput() <= idleTimeoutSeconds

        guard self.allowsCapture != allowsCapture else {
            return
        }

        self.allowsCapture = allowsCapture
    }

    private func secondsSinceLastInput() -> TimeInterval {
        // `kCGAnyInputEventType` is not imported into Swift, so use its raw value.
        let anyInputEventType = CGEventType(rawValue: UInt32.max)!
        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEventType
        )
    }
}
