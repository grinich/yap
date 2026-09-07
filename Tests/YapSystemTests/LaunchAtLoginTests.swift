import Foundation
import Testing
@testable import YapSystem

@Suite("Launch at login")
@MainActor
struct LaunchAtLoginTests {
    @Test func missingMacOSRecordStillAllowsExplicitRegistration() async {
        let system = LoginItemSystem(status: .unavailable)
        let service = system.service()
        #expect(!service.isEnabled)
        #expect(system.registerCount == 0)

        await service.setEnabled(true)

        #expect(system.registerCount == 1)
        #expect(service.status == .enabled)
        #expect(service.isEnabled)
        #expect(service.errorMessage == nil)
        #expect(!service.isChanging)
    }

    @Test func registrationFailureIsVisibleAndCanBeRetried() async {
        let system = LoginItemSystem(status: .unavailable)
        system.registerAction = { throw LoginItemTestError.signature }
        let service = system.service()

        await service.setEnabled(true)

        #expect(service.status == .unavailable)
        #expect(!service.isEnabled)
        #expect(!service.isChanging)
        #expect(service.errorMessage?.contains("signature") == true)
        system.registerAction = nil
        await service.setEnabled(true)
        #expect(system.registerCount == 2)
        #expect(service.isEnabled)
        #expect(service.errorMessage == nil)
    }

    @Test func deniedApprovalIsNotShownAsEnabledOrBypassedByReregistration() async {
        let system = LoginItemSystem(status: .requiresApproval)
        let service = system.service()
        #expect(!service.isEnabled)

        await service.setEnabled(true)

        #expect(service.status == .requiresApproval)
        #expect(!service.isEnabled)
        #expect(system.settingsOpenCount == 1)
        #expect(system.registerCount == 0)
        #expect(system.unregisterCount == 0)
        #expect(service.errorMessage == nil)

        system.status = .enabled
        service.refresh()
        #expect(service.isEnabled)
        system.status = .disabled
        service.refresh()
        #expect(!service.isEnabled)
        #expect(system.registerCount == 0)
    }

    @Test func registrationThatNeedsApprovalOpensSystemSettingsEvenWhenAPIReturnsAnError() async {
        let system = LoginItemSystem(status: .disabled)
        system.registerAction = {
            system.status = .requiresApproval
            throw LoginItemTestError.denied
        }
        let service = system.service()

        await service.setEnabled(true)

        #expect(service.status == .requiresApproval)
        #expect(!service.isEnabled)
        #expect(service.errorMessage == nil)
        #expect(system.settingsOpenCount == 1)
        #expect(system.unregisterCount == 0)
    }

    @Test func disableWaitsForUnregistrationAndPreventsOverlappingChanges() async {
        let system = LoginItemSystem(status: .enabled)
        let gate = LoginItemGate()
        system.unregisterAction = {
            await gate.suspend()
            system.status = .disabled
        }
        let service = system.service()
        let operation = Task { await service.setEnabled(false) }
        await gate.waitUntilSuspended()

        #expect(service.isChanging)
        #expect(service.isEnabled)
        await service.setEnabled(true)
        #expect(system.registerCount == 0)
        #expect(system.unregisterCount == 1)
        gate.resume()
        await operation.value

        #expect(!service.isChanging)
        #expect(!service.isEnabled)
        #expect(service.status == .disabled)
        #expect(service.errorMessage == nil)
    }

    @Test func failedUnregistrationKeepsTheRealEnabledStatusAndShowsItsError() async {
        let system = LoginItemSystem(status: .enabled)
        system.unregisterAction = { throw LoginItemTestError.denied }
        let service = system.service()

        await service.setEnabled(false)

        #expect(service.isEnabled)
        #expect(!service.isChanging)
        #expect(service.errorMessage?.contains("denied") == true)
        system.status = .disabled
        service.refresh()
        #expect(!service.isEnabled)
        #expect(service.errorMessage == nil)
    }

    @Test func verifiesActualRegistrationInsteadOfReportingAnUnappliedSuccess() async {
        let system = LoginItemSystem(status: .disabled)
        system.registerAction = {}
        let service = system.service()

        await service.setEnabled(true)

        #expect(!service.isEnabled)
        #expect(service.errorMessage?.contains("hasn’t applied") == true)
        #expect(!service.isChanging)
    }

    @Test func concurrentMacOSChangeThatAppliesTheRequestWinsOverAnAPIError() async {
        let system = LoginItemSystem(status: .disabled)
        system.registerAction = {
            system.status = .enabled
            throw LoginItemTestError.alreadyRegistered
        }
        system.unregisterAction = {
            system.status = .disabled
            throw LoginItemTestError.alreadyUnregistered
        }
        let service = system.service()

        await service.setEnabled(true)
        #expect(service.isEnabled)
        #expect(service.errorMessage == nil)
        await service.setEnabled(false)
        #expect(!service.isEnabled)
        #expect(service.errorMessage == nil)
    }

    @Test func matchingRequestsAreIdempotentAndARegisteredPendingItemCanBeRemoved() async {
        let system = LoginItemSystem(status: .enabled)
        let service = system.service()
        await service.setEnabled(true)
        #expect(system.registerCount == 0)
        system.status = .disabled
        await service.setEnabled(false)
        #expect(system.unregisterCount == 0)
        system.status = .requiresApproval
        await service.setEnabled(false)
        #expect(system.unregisterCount == 1)
        #expect(service.status == .disabled)
        #expect(system.settingsOpenCount == 0)
    }

    @Test func unbundledExecutableShowsActionableErrorWithoutMutatingLoginItems() async {
        let system = LoginItemSystem(status: .unavailable)
        system.isApplicationBundle = false
        let service = system.service()

        await service.setEnabled(true)

        #expect(service.errorMessage?.contains("installed Yap app") == true)
        #expect(system.registerCount == 0)
        #expect(system.unregisterCount == 0)
        #expect(!service.isChanging)
    }
}

private enum LoginItemTestError: Error, LocalizedError {
    case signature, denied, alreadyRegistered, alreadyUnregistered
    var errorDescription: String? {
        switch self {
        case .signature: "The app signature is invalid."
        case .denied: "Permission denied."
        case .alreadyRegistered: "Already registered."
        case .alreadyUnregistered: "Already unregistered."
        }
    }
}

@MainActor
private final class LoginItemSystem {
    var status: LaunchAtLoginService.Status
    var isApplicationBundle = true
    var registerCount = 0
    var unregisterCount = 0
    var settingsOpenCount = 0
    var registerAction: (() throws -> Void)?
    var unregisterAction: (() async throws -> Void)?

    init(status: LaunchAtLoginService.Status) { self.status = status }

    func service() -> LaunchAtLoginService {
        LaunchAtLoginService(dependencies: .init(
            isApplicationBundle: { self.isApplicationBundle },
            status: { self.status },
            register: {
                self.registerCount += 1
                if let action = self.registerAction { try action() }
                else { self.status = .enabled }
            },
            unregister: {
                self.unregisterCount += 1
                if let action = self.unregisterAction { try await action() }
                else { self.status = .disabled }
            },
            openSystemSettings: { self.settingsOpenCount += 1 }
        ))
    }
}

@MainActor
private final class LoginItemGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            ready?.resume()
            ready = nil
        }
    }

    func waitUntilSuspended() async {
        if continuation != nil { return }
        await withCheckedContinuation { ready = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
