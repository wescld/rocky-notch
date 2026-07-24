import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService` for "Open at Login".
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "On"
        case .notRegistered: "Off"
        case .notFound: "Unavailable"
        case .requiresApproval: "Needs approval in System Settings"
        @unknown default: "Unknown"
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) throws -> Bool {
        if enabled {
            if SMAppService.mainApp.status == .enabled { return true }
            try SMAppService.mainApp.register()
        } else {
            if SMAppService.mainApp.status == .notRegistered { return false }
            try SMAppService.mainApp.unregister()
        }
        return isEnabled
    }
}
