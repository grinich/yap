import Foundation
import Testing
import WhooshCalendar
import WhooshMeetings
@testable import WhooshAppUI

@Suite("Foreground calendar refresh", .serialized)
@MainActor
struct WhooshForegroundRefreshTests {
    @Test func everyCompletedActivationRefreshesWithoutAStalenessDelay() async {
        let fixture = ForegroundFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        #expect(await fixture.calendar.eventRequests == 1)
        #expect(await fixture.model.refreshOnForeground())
        #expect(await fixture.model.refreshOnForeground())
        #expect(await fixture.calendar.eventRequests == 3)
        #expect(await fixture.calendar.credentialChecks == 1)
        #expect(await fixture.calendar.connectCalls == 0)
    }

    @Test func overlappingActivationsShareOneInFlightRefresh() async {
        let fixture = ForegroundFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.calendar.pauseNextEvents()
        let first = Task { await fixture.model.refreshOnForeground() }
        await fixture.calendar.waitUntilPaused()
        var secondStarted = false
        let second = Task { secondStarted = true; return await fixture.model.refreshOnForeground() }
        while !secondStarted { await Task.yield() }
        #expect(fixture.model.isRefreshing)
        #expect(await fixture.calendar.eventRequests == 2)
        await fixture.calendar.resumeEvents()
        #expect(await first.value)
        #expect(await second.value)
        #expect(await fixture.calendar.eventRequests == 2)
        #expect(!fixture.model.isRefreshing)
    }

    @Test func automaticFailurePreservesAgendaFreshnessAndUnrelatedError() async {
        let fixture = ForegroundFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        let priorEvents = fixture.model.events
        let priorRefreshed = fixture.model.lastRefreshed
        await fixture.calendar.failEvents(with: .httpStatus(503))
        #expect(!(await fixture.model.refreshOnForeground()))
        #expect(fixture.model.error == nil)
        #expect(fixture.model.events == priorEvents)
        #expect(fixture.model.lastRefreshed == priorRefreshed)
        fixture.model.error = "An unrelated meeting error"
        #expect(!(await fixture.model.refreshOnForeground()))
        #expect(fixture.model.error == "An unrelated meeting error")
        #expect(await fixture.calendar.credentialChecks == 1)
    }

    @Test func explicitRefreshJoiningAutomaticWorkStillPresentsItsFailure() async {
        let fixture = ForegroundFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.calendar.pauseNextEvents()
        await fixture.calendar.failEvents(with: .httpStatus(503))
        let automatic = Task { await fixture.model.refreshOnForeground() }
        await fixture.calendar.waitUntilPaused()
        var explicitStarted = false
        let explicit = Task { explicitStarted = true; return await fixture.model.refresh() }
        while !explicitStarted { await Task.yield() }
        await fixture.calendar.resumeEvents()
        #expect(!(await automatic.value))
        #expect(!(await explicit.value))
        #expect(fixture.model.error != nil)
        #expect(await fixture.calendar.eventRequests == 2)
    }

    @Test func expiredAuthorizationClearsAgendaWithoutAnAutomaticSignInRetry() async {
        let fixture = ForegroundFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.calendar.failEvents(with: .signInExpired)
        #expect(!(await fixture.model.refreshOnForeground()))
        #expect(!fixture.model.isCalendarConnected)
        #expect(fixture.model.events.isEmpty)
        #expect(fixture.model.lastRefreshed == nil)
        #expect(fixture.model.error == nil)
        #expect(!(await fixture.model.refreshOnForeground()))
        #expect(await fixture.calendar.eventRequests == 2)
        #expect(await fixture.calendar.credentialChecks == 1)
        #expect(await fixture.calendar.connectCalls == 0)
    }

    @Test func activationDoesNotBootstrapAnUnloadedAccountOrRefreshDuringStartup() async {
        let fixture = ForegroundFixture()
        defer { fixture.cleanUp() }
        let unloaded = WhooshModel(preview: false, preferences: fixture.preferences,
                                   meeting: fixture.meeting, calendarClient: fixture.calendar,
                                   reminders: fixture.reminders,
                                   loadGoogleConfiguration: { throw GoogleCalendarError.keychain(-1) })
        #expect(!(await unloaded.refreshOnForeground()))
        #expect(unloaded.googleConfigurationLoadState == .pending)
        #expect(await fixture.calendar.credentialChecks == 0)
        await fixture.calendar.pauseNextEvents()
        let startup = Task { await fixture.model.start() }
        await fixture.calendar.waitUntilPaused()
        #expect(!(await fixture.model.refreshOnForeground()))
        #expect(await fixture.calendar.eventRequests == 1)
        await fixture.calendar.resumeEvents()
        await startup.value
    }

    @Test func previewDisconnectedAndActiveMeetingStatesDoNotRefresh() async {
        let fixture = ForegroundFixture()
        defer { fixture.cleanUp() }
        #expect(!(await fixture.model.refreshOnForeground()))
        #expect(await fixture.calendar.credentialChecks == 0)
        await fixture.model.start()
        await fixture.meeting.host(displayName: "Fixture", title: "Fixture meeting")
        #expect(fixture.model.activeCall)
        #expect(!(await fixture.model.refreshOnForeground()))
        #expect(await fixture.calendar.eventRequests == 1)
        await fixture.meeting.leave()
        fixture.model.enterPreview()
        #expect(!(await fixture.model.refreshOnForeground()))
        #expect(await fixture.calendar.eventRequests == 1)
        await fixture.model.exitPreview()
        await fixture.model.disconnectGoogle()
        let requests = await fixture.calendar.eventRequests
        #expect(!(await fixture.model.refreshOnForeground()))
        #expect(await fixture.calendar.eventRequests == requests)
        #expect(await fixture.calendar.connectCalls == 0)
    }

    @Test func disconnectRejectsLateForegroundEvents() async {
        let fixture = ForegroundFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.calendar.pauseNextEvents()
        let refresh = Task { await fixture.model.refreshOnForeground() }
        await fixture.calendar.waitUntilPaused()
        await fixture.model.disconnectGoogle()
        await fixture.calendar.resumeEvents()
        #expect(!(await refresh.value))
        #expect(fixture.model.events.isEmpty)
        #expect(!fixture.model.isCalendarConnected)
        #expect(!fixture.model.isRefreshing)
    }
}

@MainActor
private final class ForegroundFixture {
    let suite = "WhooshForegroundRefreshTests.\(UUID())"
    let preferences: UserDefaults
    let calendar = ForegroundCalendar()
    let meeting = MeetingCoordinator(driver: DemoMeetingDriver(participantCount: 2))
    let reminders = WhooshReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {})
    let model: WhooshModel

    init() {
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(["fixture"], forKey: "selectedCalendarIDs")
        model = WhooshModel(preview: false, preferences: preferences, meeting: meeting,
                            calendarClient: calendar, reminders: reminders)
    }

    func cleanUp() { preferences.removePersistentDomain(forName: suite) }
}

private actor ForegroundCalendar: WhooshCalendarServing {
    nonisolated let isConfigured = true
    private let listed = [GoogleCalendar(id: "fixture", name: "Fixture", isPrimary: true)]
    private var connected = true
    private var failure: GoogleCalendarError?
    private var pauseNext = false
    private var paused = false
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?
    private(set) var credentialChecks = 0
    private(set) var connectCalls = 0
    private(set) var eventRequests = 0

    func hasCredentials() -> Bool { credentialChecks += 1; return connected }
    func calendars() -> [GoogleCalendar] { listed }
    func cachedSnapshot() -> CalendarSnapshot? { nil }
    func clearCachedEvents() {}
    func connect(openURL: @escaping @MainActor @Sendable (URL) -> Void) -> [GoogleCalendar] {
        connectCalls += 1; connected = true; return listed
    }
    func disconnect() { connected = false }
    func pauseNextEvents() { pauseNext = true }
    func failEvents(with failure: GoogleCalendarError) { self.failure = failure }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }
    func resumeEvents() { resumeWaiter?.resume(); resumeWaiter = nil; paused = false }

    func events(in calendars: [GoogleCalendar], from: Date, to: Date) async throws -> [CalendarEvent] {
        eventRequests += 1
        if pauseNext {
            pauseNext = false; paused = true
            await withCheckedContinuation { continuation in
                resumeWaiter = continuation
                pauseWaiter?.resume(); pauseWaiter = nil
            }
        }
        if let failure { throw failure }
        return [CalendarEvent(id: "fixture-event", title: "Fixture meeting", startDate: Date().addingTimeInterval(300),
                              endDate: Date().addingTimeInterval(900), calendarID: "fixture", calendarName: "Fixture",
                              meetingURLs: [URL(string: "https://zoom.us/j/12345678901")!])]
    }
}
