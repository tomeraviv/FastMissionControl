//
//  GlobalTriggerMonitor.swift
//  FastMissionControl
//
//  Created by Codex.
//

import CoreGraphics
import Foundation

enum GlobalTriggerMonitorError: LocalizedError {
    case failedToCreateTap

    var errorDescription: String? {
        switch self {
        case .failedToCreateTap:
            "Failed to create the global middle-click event tap."
        }
    }
}

final class GlobalTriggerMonitor {
    var onToggle: ((Bool, UInt64) -> Void)?

    // CGEvent button numbers are zero-based: left=0, right=1, middle=2, mouse button 4=3.
    var toggleButtonNumber: Int64 = 3
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var suspendedUntil = Date.distantPast

    func start() throws {
        guard eventTap == nil else {
            return
        }

        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<GlobalTriggerMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(proxy: proxy, type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            throw GlobalTriggerMonitorError.failedToCreateTap
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        runLoopSource = nil
        eventTap = nil
    }

    func suspend(for seconds: TimeInterval) {
        suspendedUntil = Date().addingTimeInterval(seconds)
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }

            return Unmanaged.passUnretained(event)
        }

        guard Date() >= suspendedUntil else {
            return Unmanaged.passUnretained(event)
        }

        guard event.getIntegerValueField(.mouseEventButtonNumber) == toggleButtonNumber else {
            return Unmanaged.passUnretained(event)
        }

        if type == .otherMouseDown {
            let slowAnimation = event.flags.contains(.maskShift)
            let eventTimestampNanoseconds = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async { [weak self] in
                self?.onToggle?(slowAnimation, eventTimestampNanoseconds)
            }
        }

        return nil
    }
}
