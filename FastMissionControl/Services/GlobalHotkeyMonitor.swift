//
//  GlobalHotkeyMonitor.swift
//  FastMissionControl
//

import AppKit
import Carbon.HIToolbox

enum GlobalHotkeyMonitorError: LocalizedError {
    case failedToInstallHandler(OSStatus)
    case failedToRegister(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .failedToInstallHandler(status):
            "Failed to install global hotkey handler (status \(status))."
        case let .failedToRegister(status):
            "Failed to register Option+Tab hotkey (status \(status))."
        }
    }
}

/// Registers Option+Tab (and Option+Shift+Tab for the slow-animation variant) as system-wide hotkeys.
///
/// Uses Carbon's `RegisterEventHotKey` rather than a `CGEventTap` on `.keyDown` because the
/// event-tap route would receive every keystroke the user types system-wide. Carbon hotkeys only
/// fire for the exact registered combinations, so this service never sees any other key.
final class GlobalHotkeyMonitor {
    var onTrigger: ((Bool, UInt64) -> Void)?

    // 'FMCT' as ASCII — identifies events that belong to this app's hotkeys.
    private static let signature: OSType = 0x46_4D_43_54
    private static let normalID: UInt32 = 1
    private static let slowID: UInt32 = 2

    private var eventHandlerRef: EventHandlerRef?
    private var hotkeyRefs: [EventHotKeyRef] = []

    func start() throws {
        guard eventHandlerRef == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, eventRef, userData -> OSStatus in
            guard let eventRef, let userData else {
                return OSStatus(eventNotHandledErr)
            }
            let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            return monitor.handle(eventRef: eventRef)
        }

        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &handlerRef
        )

        guard installStatus == noErr, let handlerRef else {
            throw GlobalHotkeyMonitorError.failedToInstallHandler(installStatus)
        }
        eventHandlerRef = handlerRef

        do {
            try registerHotKey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey), id: Self.normalID)
            try registerHotKey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey | shiftKey), id: Self.slowID)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        for ref in hotkeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotkeyRefs.removeAll()

        if let handlerRef = eventHandlerRef {
            RemoveEventHandler(handlerRef)
            eventHandlerRef = nil
        }
    }

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32, id: UInt32) throws {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            throw GlobalHotkeyMonitorError.failedToRegister(status)
        }
        hotkeyRefs.append(hotKeyRef)
    }

    private func handle(eventRef: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == Self.signature else {
            return OSStatus(eventNotHandledErr)
        }

        let timestamp = DispatchTime.now().uptimeNanoseconds
        let slowAnimation = hotKeyID.id == Self.slowID
        DispatchQueue.main.async { [weak self] in
            self?.onTrigger?(slowAnimation, timestamp)
        }
        return noErr
    }
}
