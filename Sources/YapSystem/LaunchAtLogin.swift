import Foundation
import Observation
import ServiceManagement

/// The macOS registration is the source of truth, including changes made in System Settings.
@Observable
@MainActor
public final class LaunchAtLoginService {
    public enum Status: Equatable, Sendable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable
    }

    public private(set) var status: Status
    public private(set) var isChanging = false
    public private(set) var errorMessage: String?
    public var isEnabled: Bool { status == .enabled }

    struct Dependencies {
        var isApplicationBundle: @MainActor () -> Bool
        var status: @MainActor () -> Status
        var register: @MainActor () throws -> Void
        var unregister: @MainActor () async throws -> Void
        var openSystemSettings: @MainActor () -> Void
    }

    private let dependencies: Dependencies

    public convenience init() {
        self.init(dependencies: Dependencies(
            isApplicationBundle: {
                let bundle = Bundle.main
                return bundle.bundleURL.pathExtension.lowercased() == "app"
                    && bundle.bundleIdentifier != nil
                    && bundle.executableURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true
            },
            status: {
                switch SMAppService.mainApp.status {
                case .enabled: .enabled
                case .notRegistered: .disabled
                case .requiresApproval: .requiresApproval
                case .notFound: .unavailable
                @unknown default: .unavailable
                }
            },
            register: { try SMAppService.mainApp.register() },
            unregister: { try await SMAppService.mainApp.unregister() },
            openSystemSettings: { SMAppService.openSystemSettingsLoginItems() }
        ))
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        status = dependencies.status()
    }

    public func refresh() {
        guard !isChanging else { return }
        let current = dependencies.status()
        if current != status { errorMessage = nil }
        status = current
    }

    /// Only call in response to the person's explicit setting change.
    public func setEnabled(_ enabled: Bool) async {
        guard !isChanging else { return }
        isChanging = true
        errorMessage = nil
        defer {
            status = dependencies.status()
            isChanging = false
        }

        guard dependencies.isApplicationBundle() else {
            errorMessage = "Open the installed Yap app to change its login setting. This setting isn’t available when running the executable outside its app bundle."
            return
        }

        status = dependencies.status()
        if enabled && status == .enabled || !enabled && status == .disabled { return }
        if enabled && status == .requiresApproval {
            // Re-registering must not bypass consent revoked in System Settings.
            dependencies.openSystemSettings()
            return
        }

        var operationError: (any Error)?
        do {
            // A missing status must not disable the control: a newly installed or
            // relocated app may not have a background-task record until this call.
            if enabled { try dependencies.register() }
            else { try await dependencies.unregister() }
        } catch {
            operationError = error
        }

        status = dependencies.status()
        if enabled && status == .enabled || !enabled && status == .disabled { return }
        if enabled && status == .requiresApproval {
            dependencies.openSystemSettings()
            return
        }

        if let operationError {
            errorMessage = "macOS couldn’t turn \(enabled ? "on" : "off") Open Yap at login. \(operationError.localizedDescription)"
        } else {
            errorMessage = "macOS hasn’t applied this login setting. Try again, or check Yap in Login Items in System Settings."
        }
    }

    public func openSystemSettings() {
        dependencies.openSystemSettings()
    }
}
