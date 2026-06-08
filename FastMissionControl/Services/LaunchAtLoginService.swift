//
//  LaunchAtLoginService.swift
//  FastMissionControl
//

import ServiceManagement

/// Reconciles the macOS "Login Items" registration for the app with the user's
/// desired state, using the modern `SMAppService` API (no helper bundle).
@MainActor
final class LaunchAtLoginService {
    enum LaunchAtLoginError: LocalizedError {
        case updateFailed(enabling: Bool, underlying: Error)

        var errorDescription: String? {
            switch self {
            case let .updateFailed(enabling, underlying):
                let verb = enabling ? "enable" : "disable"
                return "Couldn't \(verb) Launch at Login: \(underlying.localizedDescription)"
            }
        }
    }

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a Login Item so the system state
    /// matches `enabled`. No-op when already in the desired state.
    func apply(enabled: Bool) throws {
        let service = SMAppService.mainApp
        guard (service.status == .enabled) != enabled else { return }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            throw LaunchAtLoginError.updateFailed(enabling: enabled, underlying: error)
        }
    }
}
