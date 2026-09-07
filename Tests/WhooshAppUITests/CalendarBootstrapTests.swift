import Dispatch
import Foundation
import Observation
import Synchronization
import Testing
import WhooshCalendar
import WhooshMeetings
@testable import WhooshAppUI

@Suite("Nonblocking calendar bootstrap", .serialized)
@MainActor
struct CalendarBootstrapTests {
    @Test func configurationReadStartsAfterInitializationAndRunsOffMainThread() async throws {
        let gate = ConfigurationReadGate()
        let fixture = BootstrapFixture(loader: { try gate.read() })
        defer { fixture.cleanUp(); gate.release() }
        #expect(!gate.hasStarted)
        #expect(fixture.model.googleConfigurationLoadState == .pending)

        let observedLoading = Mutex(false)
        withObservationTracking {
            _ = fixture.model.googleConfigurationLoadState
        } onChange: { observedLoading.withLock { $0 = true } }
        let startup = Task { await fixture.model.start() }
        await gate.waitUntilStarted()

        #expect(!gate.wasMainThread)
        #expect(fixture.model.googleConfigurationLoadState == .loading)
        #expect(observedLoading.withLock { $0 })
        // The main actor can still handle UI actions while the synchronous store is blocked.
        fixture.model.showJoinSheet = true
        fixture.model.joinLink = "https://zoom.us/j/12345678901"
        #expect(fixture.model.showJoinSheet)
        gate.release()
        await startup.value

        #expect(fixture.model.googleConfigurationLoadState == .loaded)
        #expect(fixture.model.googleConfigured)
        #expect(fixture.model.isCalendarConnected)
        #expect(fixture.model.events.map(\.id) == ["live"])
        #expect(fixture.createdClientIDs == ["saved.apps.googleusercontent.com"])
        #expect(await fixture.initial.credentialsReads == 0)
    }

    @Test func cancellingIgnoresTheLateReadWithoutDeletingCredentials() async throws {
        let gate = ConfigurationReadGate()
        let fixture = BootstrapFixture(loader: { try gate.read() })
        defer { fixture.cleanUp(); gate.release() }
        let startup = Task { await fixture.model.start() }
        await gate.waitUntilStarted()

        fixture.model.cancelGoogleConfigurationLoad()
        #expect(fixture.model.googleConfigurationLoadState == .cancelled)
        fixture.model.showJoinSheet = true
        await startup.value
        #expect(!gate.hasFinished)
        gate.release()

        #expect(fixture.model.googleConfigurationLoadState == .cancelled)
        #expect(fixture.createdClientIDs.isEmpty)
        #expect(fixture.model.events.isEmpty)
        #expect(!fixture.model.isCalendarConnected)
        #expect(await fixture.initial.disconnects == 0)
        #expect(fixture.model.error == nil)
    }

    @Test func disconnectInvalidatesAReadThatCannotBeInterrupted() async throws {
        let gate = ConfigurationReadGate()
        let fixture = BootstrapFixture(loader: { try gate.read() })
        defer { fixture.cleanUp(); gate.release() }
        let startup = Task { await fixture.model.start() }
        await gate.waitUntilStarted()

        await fixture.model.disconnectGoogle()
        gate.release()
        await startup.value

        #expect(fixture.createdClientIDs.isEmpty)
        #expect(!fixture.model.isCalendarConnected)
        #expect(fixture.model.events.isEmpty)
        #expect(await fixture.initial.disconnects == 1)
        #expect(await fixture.configured.credentialsReads == 0)
    }

    @Test func importingAReplacementWinsOverTheOldConfigurationRead() async throws {
        let gate = ConfigurationReadGate()
        let fixture = BootstrapFixture(loader: { try gate.read() })
        defer { fixture.cleanUp(); gate.release() }
        let startup = Task { await fixture.model.start() }
        await gate.waitUntilStarted()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("WhooshBootstrap-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"installed":{"client_id":"replacement.apps.googleusercontent.com"}}"#.utf8).write(to: file)

        await fixture.model.importGoogleConfiguration(from: file)
        gate.release()
        await startup.value

        #expect(fixture.model.googleConfigurationLoadState == .loaded)
        #expect(fixture.createdClientIDs == ["replacement.apps.googleusercontent.com"])
        #expect(fixture.model.googleConfigured)
        #expect(!fixture.model.isCalendarConnected)
        #expect(fixture.model.events.isEmpty)
        #expect(await fixture.initial.disconnects == 1)
        #expect(await fixture.configured.credentialsReads == 0)
    }

    @Test func previewKeepsSampleEventsWhenConfigurationFinishesAndRestoresLiveDataOnExit() async throws {
        let gate = ConfigurationReadGate()
        let fixture = BootstrapFixture(loader: { try gate.read() })
        defer { fixture.cleanUp(); gate.release() }
        let startup = Task { await fixture.model.start() }
        await gate.waitUntilStarted()
        fixture.model.enterPreview()
        gate.release()
        await startup.value

        #expect(fixture.model.isPreview)
        #expect(fixture.model.events.allSatisfy { $0.calendarID == "preview" })
        #expect(await fixture.configured.credentialsReads == 0)
        await fixture.model.exitPreview()

        #expect(!fixture.model.isPreview)
        #expect(fixture.model.events.map(\.id) == ["live"])
        #expect(fixture.createdClientIDs.count == 1)
        #expect(await fixture.configured.credentialsReads == 1)
    }

    @Test func deniedConfigurationReadCanBeRetriedWithoutTreatingItAsMissingSetup() async throws {
        let attempts = Mutex(0)
        let fixture = BootstrapFixture(loader: {
            let attempt = attempts.withLock { $0 += 1; return $0 }
            if attempt == 1 { throw BootstrapFailure.denied }
            return GoogleOAuthConfiguration(clientID: "saved.apps.googleusercontent.com")
        })
        defer { fixture.cleanUp() }
        await fixture.model.start()
        #expect(fixture.model.googleConfigurationLoadState == .failed)
        #expect(!fixture.model.googleConfigured)
        #expect(fixture.model.error != nil)

        await fixture.model.loadGoogleConnection()

        #expect(fixture.model.googleConfigurationLoadState == .loaded)
        #expect(fixture.model.isCalendarConnected)
        #expect(fixture.model.error == nil)
        #expect(attempts.withLock { $0 } == 2)
    }

    @Test func cancelledReadCannotFinishOrClearANewerRetry() async throws {
        let oldRead = ConfigurationReadGate()
        let newRead = ConfigurationReadGate()
        let calls = Mutex(0)
        let fixture = BootstrapFixture(loader: {
            let call = calls.withLock { $0 += 1; return $0 }
            return try (call == 1 ? oldRead : newRead).read()
        })
        defer { fixture.cleanUp(); oldRead.release(); newRead.release() }
        let startup = Task { await fixture.model.start() }
        await oldRead.waitUntilStarted()
        fixture.model.cancelGoogleConfigurationLoad()
        let retry = Task { await fixture.model.loadGoogleConnection() }
        await newRead.waitUntilStarted()

        oldRead.release()
        await startup.value
        #expect(fixture.model.googleConfigurationLoadState == .loading)
        #expect(fixture.createdClientIDs.isEmpty)
        newRead.release()
        await retry.value

        #expect(fixture.model.googleConfigurationLoadState == .loaded)
        #expect(fixture.createdClientIDs.count == 1)
        #expect(fixture.model.isCalendarConnected)
    }

    @Test func missingConfigurationFinishesAndOffersInitialSetup() async throws {
        let fixture = BootstrapFixture(loader: { nil })
        defer { fixture.cleanUp() }
        await fixture.model.start()
        #expect(fixture.model.googleConfigurationLoadState == .loaded)
        #expect(!fixture.model.googleConfigured)
        #expect(!fixture.model.isCalendarConnected)
        #expect(fixture.model.error == nil)
    }
}

private enum BootstrapFailure: Error { case denied, timedOut }

/// Simulates SecItemCopyMatching waiting synchronously on another thread, without Keychain access.
private final class ConfigurationReadGate: Sendable {
    private struct State {
        var started = false
        var finished = false
        var mainThread = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    private let semaphore = DispatchSemaphore(value: 0)
    var hasStarted: Bool { state.withLock { $0.started } }
    var hasFinished: Bool { state.withLock { $0.finished } }
    var wasMainThread: Bool { state.withLock { $0.mainThread } }

    func read() throws -> GoogleOAuthConfiguration? {
        defer { state.withLock { $0.finished = true } }
        let waiter = state.withLock { value in
            value.started = true
            value.mainThread = Thread.isMainThread
            let waiter = value.waiter
            value.waiter = nil
            return waiter
        }
        waiter?.resume()
        guard semaphore.wait(timeout: .now() + 10) == .success else { throw BootstrapFailure.timedOut }
        return GoogleOAuthConfiguration(clientID: "saved.apps.googleusercontent.com")
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            state.withLock { value in
                if value.started { continuation.resume() }
                else { value.waiter = continuation }
            }
        }
    }

    func release() { semaphore.signal() }
}

@MainActor
private final class BootstrapFixture {
    let suite = "WhooshCalendarBootstrap.\(UUID())"
    let preferences: UserDefaults
    let initial = BootstrapCalendar(isConfigured: false)
    let configured = BootstrapCalendar(isConfigured: true)
    var createdClientIDs: [String] = []
    var model: WhooshModel!

    init(loader: @escaping @Sendable () throws -> GoogleOAuthConfiguration?) {
        preferences = UserDefaults(suiteName: suite)!
        model = WhooshModel(
            preview: false, preferences: preferences,
            meeting: MeetingCoordinator(driver: DemoMeetingDriver()),
            calendarClient: initial,
            reminders: WhooshReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}),
            saveGoogleConfiguration: { _ in },
            loadGoogleConfiguration: loader,
            makeConfiguredCalendarClient: { [weak self, configured] config in
                self?.createdClientIDs.append(config.clientID)
                return configured
            }
        )
    }

    func cleanUp() { preferences.removePersistentDomain(forName: suite) }
}

private actor BootstrapCalendar: WhooshCalendarServing {
    nonisolated let isConfigured: Bool
    var credentialsReads = 0
    var disconnects = 0
    init(isConfigured: Bool) { self.isConfigured = isConfigured }
    func hasCredentials() async -> Bool { credentialsReads += 1; return isConfigured }
    func cachedSnapshot() async -> CalendarSnapshot? { nil }
    func clearCachedEvents() async {}
    func disconnect() async { disconnects += 1 }
    func calendars() async -> [GoogleCalendar] { [GoogleCalendar(id: "personal", name: "Personal", isPrimary: true)] }
    func connect(openURL: @escaping @MainActor @Sendable (URL) -> Void) async -> [GoogleCalendar] { await calendars() }
    func events(in calendars: [GoogleCalendar], from: Date, to: Date) async -> [CalendarEvent] {
        [CalendarEvent(id: "live", title: "Upcoming", startDate: .now.addingTimeInterval(600), endDate: .now.addingTimeInterval(1800),
                       calendarID: "personal", calendarName: "Personal", meetingURLs: [URL(string: "https://zoom.us/j/12345678901")!])]
    }
}
