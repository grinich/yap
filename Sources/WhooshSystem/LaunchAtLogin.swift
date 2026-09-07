import ServiceManagement

@MainActor
public enum LaunchAtLoginService {
    public enum Status: Equatable, Sendable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable
    }

    public static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    /// Only call in response to the person's explicit setting change.
    public static func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try await SMAppService.mainApp.unregister()
        }
    }

    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
