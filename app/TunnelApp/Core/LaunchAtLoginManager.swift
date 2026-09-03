import Foundation
import ServiceManagement

protocol LaunchAtLoginManaging: Sendable {
    func currentState() -> LaunchAtLoginState
    func setEnabled(_ enabled: Bool) throws
}

struct SystemLaunchAtLoginManager: LaunchAtLoginManaging {
    func currentState() -> LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .disabled
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status == .notRegistered else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered, service.status != .notFound else { return }
            try service.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
