import Foundation
import Testing
@testable import YapSystem

@Suite("Zoom link handler service")
@MainActor
struct ZoomLinkHandlerTests {
    @Test func readsActualDefaultsAndAvailabilityWithoutChangingThem() {
        let workspace = LinkWorkspace()
        let service = workspace.service()
        #expect(service.status().current == .zoom)
        #expect(service.status().zoomApplicationURL == workspace.zoom)
        #expect(service.status().yapApplicationURL == workspace.yap)
        workspace.handlers["zoommtg"] = workspace.yap
        #expect(service.status().current == .mixed)
        workspace.handlers["zoomus"] = workspace.yap
        #expect(service.status().current == .yap)
        workspace.handlers = ["zoommtg": workspace.other, "zoomus": workspace.other]
        #expect(service.status().current == .other)
        workspace.handlers.removeValue(forKey: "zoomus")
        #expect(service.status().current == .mixed)
        workspace.handlers.removeAll()
        #expect(service.status().current == .unset)
        workspace.available.removeValue(forKey: .zoom)
        #expect(service.status().zoomApplicationURL == nil)
        #expect(workspace.changes.isEmpty)
        #expect(workspace.opens.isEmpty)
    }

    @Test func explicitlySelectsBothSchemesAndSkipsAlreadySelectedLocations() async throws {
        let workspace = LinkWorkspace()
        let service = workspace.service()
        let selected = try await service.select(.yap)
        #expect(selected.current == .yap)
        #expect(workspace.changes == [
            .init(application: workspace.yap, scheme: "zoommtg"),
            .init(application: workspace.yap, scheme: "zoomus")
        ])
        _ = try await service.select(.yap)
        #expect(workspace.changes.count == 2)
        let restored = try await service.select(.zoom)
        #expect(restored.current == .zoom)
        #expect(workspace.changes.count == 4)
        #expect(workspace.opens.isEmpty)
    }

    @Test func selectsRunningYapLocationEvenIfAnOlderCopyHasTheSameBundleID() async throws {
        let workspace = LinkWorkspace()
        let oldCopy = URL(filePath: "/Old/Yap.app")
        workspace.identifiers[oldCopy] = ZoomLinkHandlerService.yapBundleIdentifier
        workspace.handlers = ["zoommtg": oldCopy, "zoomus": oldCopy]
        let service = workspace.service()
        #expect(service.status().current == .yap)
        let status = try await service.select(.yap)
        #expect(status.handlers.allSatisfy { $0.applicationURL == workspace.yap })
        #expect(workspace.changes.count == 2)
    }

    @Test func waitsForDelayedRegistrationWithoutRollingBackSuccessfulSelection() async throws {
        let workspace = LinkWorkspace()
        workspace.set = { _, _, _ in }
        workspace.wait = {
            workspace.handlers = ["zoommtg": workspace.yap, "zoomus": workspace.yap]
        }
        let status = try await workspace.service().select(.yap)
        #expect(status.isApplied(.yap))
        #expect(workspace.changes.count == 2)
    }

    @Test func successfulRollbackWaitsForItsOwnRegistrationToSettle() async throws {
        let workspace = LinkWorkspace()
        var restoring = false
        workspace.set = { application, scheme, call in
            if call == 2 { throw LinkTestError.denied }
            if call == 3 { restoring = true; return }
            workspace.handlers[scheme] = application
        }
        workspace.wait = {
            if restoring { workspace.handlers = ["zoommtg": workspace.zoom, "zoomus": workspace.zoom] }
        }
        do {
            try await workspace.service().select(.yap)
            Issue.record("Expected second-scheme failure")
        } catch let error as ZoomLinkHandlerError {
            #expect(!error.restorationIncomplete)
            #expect(error.status.isApplied(.zoom))
        }
    }

    @Test func missingAppsAreUnavailableWithoutAttemptingChangesOrLaunches() async throws {
        let workspace = LinkWorkspace()
        workspace.available.removeAll()
        let service = workspace.service()
        do {
            try await service.select(.zoom)
            Issue.record("Expected missing Zoom to reject selection")
        } catch let error as ZoomLinkHandlerError {
            #expect(error.reason == .applicationUnavailable(.zoom))
            #expect(error.status.current == .zoom)
            #expect(error.status.zoomApplicationURL == nil)
        }
        do {
            try await service.openInZoom(URL(string: "zoommtg://zoom.us/start?confno=123")!)
            Issue.record("Expected missing Zoom to reject opening")
        } catch let error as ZoomLinkHandlerError {
            #expect(error.reason == .applicationUnavailable(.zoom))
        }
        #expect(workspace.changes.isEmpty)
        #expect(workspace.opens.isEmpty)
    }

    @Test func restoresFirstSchemeWhenSecondFailsAndReportsFreshStatus() async throws {
        let workspace = LinkWorkspace()
        workspace.set = { application, scheme, call in
            if call == 2 { throw LinkTestError.denied }
            workspace.handlers[scheme] = application
        }
        let service = workspace.service()
        do {
            try await service.select(.yap)
            Issue.record("Expected failure")
        } catch let error as ZoomLinkHandlerError {
            #expect(error.status == service.status())
            #expect(error.status.current == .zoom)
            #expect(!error.restorationIncomplete)
        }
        #expect(workspace.changes.last == .init(application: workspace.zoom, scheme: "zoommtg"))
    }

    @Test func verifiesOSAppliedSelectionEvenWhenItReturnsSuccess() async throws {
        let workspace = LinkWorkspace()
        workspace.set = { application, scheme, _ in
            if scheme == "zoommtg" { workspace.handlers[scheme] = application }
        }
        let service = workspace.service()
        do {
            try await service.select(.yap)
            Issue.record("Expected an unapplied default to fail")
        } catch let error as ZoomLinkHandlerError {
            #expect(error.reason == .notApplied)
            #expect(error.status.current == .zoom)
            #expect(!error.restorationIncomplete)
        }
    }

    @Test func reportsPartialStateIfRestoringPreviousDefaultsFails() async throws {
        let workspace = LinkWorkspace()
        workspace.set = { application, scheme, call in
            if call >= 2 { throw LinkTestError.denied }
            workspace.handlers[scheme] = application
        }
        let service = workspace.service()
        do {
            try await service.select(.yap)
            Issue.record("Expected failure")
        } catch let error as ZoomLinkHandlerError {
            #expect(error.status.current == .mixed)
            #expect(error.restorationIncomplete)
            #expect(error.status == service.status())
            #expect(error.localizedDescription.contains("could not be restored"))
        }
    }

    @Test func neverReplacesAnOutsideChangeWhileRestoring() async throws {
        let workspace = LinkWorkspace()
        workspace.set = { application, scheme, call in
            if call == 2 {
                workspace.handlers["zoommtg"] = workspace.other
                throw LinkTestError.denied
            }
            workspace.handlers[scheme] = application
        }
        let service = workspace.service()
        do {
            try await service.select(.yap)
            Issue.record("Expected failure")
        } catch let error as ZoomLinkHandlerError {
            #expect(error.restorationIncomplete)
            #expect(error.status.current == .mixed)
        }
        #expect(workspace.handlers["zoommtg"] == workspace.other)
        #expect(workspace.changes.count == 2)
    }

    @Test func reportsUnrestorableUnsetHandlerTruthfully() async throws {
        let workspace = LinkWorkspace()
        workspace.handlers.removeAll()
        workspace.set = { application, scheme, call in
            if call == 2 { throw LinkTestError.denied }
            workspace.handlers[scheme] = application
        }
        let service = workspace.service()
        do {
            try await service.select(.yap)
            Issue.record("Expected failure")
        } catch let error as ZoomLinkHandlerError {
            #expect(error.restorationIncomplete)
            #expect(error.status.current == .mixed)
            #expect(error.status.handlers.first?.applicationURL == workspace.yap)
        }
        #expect(workspace.changes.count == 2)
    }

    @Test func cancellationRestoresChangesUsingAnUncancelledCleanupTask() async throws {
        let workspace = LinkWorkspace()
        let gate = LinkGate()
        workspace.set = { application, scheme, call in
            try Task.checkCancellation()
            workspace.handlers[scheme] = application
            if call == 1 { await gate.suspend() }
        }
        let service = workspace.service()
        let task = Task { try await service.select(.yap) }
        await gate.waitUntilSuspended()
        task.cancel()
        gate.resume()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch let error as ZoomLinkHandlerError {
            #expect(error.reason == .cancelled)
            #expect(error.status.current == .zoom)
            #expect(!error.restorationIncomplete)
        }
        #expect(workspace.changes.count == 2)
    }

    @Test func rejectsOverlappingSelectionsWhileOneAwaitsMacOS() async throws {
        let workspace = LinkWorkspace()
        let gate = LinkGate()
        workspace.set = { application, scheme, call in
            workspace.handlers[scheme] = application
            if call == 1 { await gate.suspend() }
        }
        let service = workspace.service()
        let first = Task { try await service.select(.yap) }
        await gate.waitUntilSuspended()
        do {
            try await service.select(.zoom)
            Issue.record("Expected concurrent selection to be rejected")
        } catch let error as ZoomLinkHandlerError {
            #expect(error.reason == .operationInProgress)
        }
        gate.resume()
        #expect(try await first.value.current == .yap)
    }

    @Test func opensUnsupportedAppLinksDirectlyInOfficialZoomWithoutChangingDefaults() async throws {
        let workspace = LinkWorkspace()
        workspace.handlers = ["zoommtg": workspace.yap, "zoomus": workspace.yap]
        let service = workspace.service()
        let url = URL(string: "zoommtg://zoom.us/start?confno=123")!
        try await service.openInZoom(url)
        #expect(workspace.opens == [.init(url: url, application: workspace.zoom)])
        #expect(workspace.changes.isEmpty)
        #expect(service.status().current == .yap)
    }

    @Test func validatesExplicitLaunchAndReportsOSFailure() async throws {
        let workspace = LinkWorkspace()
        let service = workspace.service()
        do {
            try await service.openInZoom(URL(filePath: "/tmp/unrelated-file"))
            Issue.record("Expected a non-Zoom link to fail")
        } catch let error as ZoomLinkHandlerError {
            #expect(error.reason == .invalidLink)
        }
        #expect(workspace.opens.isEmpty)
        workspace.openError = LinkTestError.denied
        do {
            try await service.openInZoom(URL(string: "zoomus://zoom.us/signin")!)
            Issue.record("Expected launch failure")
        } catch let error as ZoomLinkHandlerError {
            guard case .systemFailure = error.reason else { Issue.record("Expected system error"); return }
            #expect(error.status == service.status())
        }
        #expect(workspace.changes.isEmpty)
    }
}

private enum LinkTestError: Error { case denied }

@MainActor
private final class LinkWorkspace {
    struct Change: Equatable { let application: URL; let scheme: String }
    struct Open: Equatable { let url: URL; let application: URL }
    let yap = URL(filePath: "/Applications/Yap.app")
    let zoom = URL(filePath: "/Applications/zoom.us.app")
    let other = URL(filePath: "/Applications/Other.app")
    var available: [ZoomLinkHandlerChoice: URL] = [:]
    var handlers: [String: URL] = [:]
    var identifiers: [URL: String] = [:]
    var changes: [Change] = []
    var opens: [Open] = []
    var set: (@MainActor (URL, String, Int) async throws -> Void)?
    var openError: (any Error)?
    var wait: (@MainActor () async throws -> Void)?

    init() {
        available = [.yap: yap, .zoom: zoom]
        handlers = ["zoommtg": zoom, "zoomus": zoom]
        identifiers = [yap: ZoomLinkHandlerService.yapBundleIdentifier,
            zoom: ZoomLinkHandlerService.zoomBundleIdentifier, other: "com.example.other"]
    }

    func service() -> ZoomLinkHandlerService {
        ZoomLinkHandlerService(dependencies: .init(
            applicationURL: { self.available[$0] },
            handlerURL: { self.handlers[$0] },
            bundleIdentifier: { self.identifiers[$0] },
            setHandler: { application, scheme in
                self.changes.append(.init(application: application, scheme: scheme))
                if let set = self.set { try await set(application, scheme, self.changes.count) }
                else { self.handlers[scheme] = application }
            },
            open: { url, application in
                self.opens.append(.init(url: url, application: application))
                if let error = self.openError { throw error }
            },
            waitForRegistration: { try await self.wait?() }
        ))
    }
}

@MainActor
private final class LinkGate {
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
