import Foundation
import Testing
import YapCalendar
import YapMeetings
@testable import YapAppUI

@Suite("Calendar join authority", .serialized) @MainActor
struct CalendarJoinRegressionTests {
    @Test(arguments: ["join", "details"])
    func incomingLinkSupersedesPendingCalendarNavigation(_ action: String) async {
        let fixture = CalendarJoinFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.calendar.pauseNextEvents()
        let pending = Task {
            if action == "join" { await fixture.model.joinNextCalendarMeeting(expectedEventID: "ready") }
            else { await fixture.model.handleSystemAction(.showMeeting(id: "ready")) }
        }
        await fixture.calendar.waitUntilPaused()
        fixture.model.receiveMeetingLink(URL(string: "zoommtg://zoom.us/join?action=join&confno=98765432101")!)
        await fixture.calendar.resumeEvents()
        await pending.value
        for _ in 0..<100 where fixture.driver.requests.isEmpty { await Task.yield() }
        #expect(fixture.driver.requests.count == 1)
        #expect(fixture.driver.requests.first?.url?.absoluteString == "https://zoom.us/j/98765432101")
        #expect(fixture.model.selectedEvent == nil)
        #expect(fixture.model.joinLink == "https://zoom.us/j/98765432101")
        #expect(!fixture.model.showJoinSheet)
        #expect(fixture.model.error == nil)
    }

    @Test func overlappingJoinActionsProduceOneJoinWithoutAnActiveCallError() async {
        let fixture = CalendarJoinFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.calendar.pauseNextEvents()
        let first = Task { await fixture.model.joinNextCalendarMeeting(expectedEventID: "ready") }
        await fixture.calendar.waitUntilPaused()
        var secondStarted = false
        let second = Task {
            secondStarted = true
            await fixture.model.joinNextCalendarMeeting(expectedEventID: "ready")
        }
        while !secondStarted { await Task.yield() }
        await fixture.calendar.resumeEvents()
        await first.value
        await second.value
        #expect(fixture.driver.requests.count == 1)
        #expect(fixture.model.error == nil)
        #expect(fixture.driver.requests.first?.microphoneMuted == true)
        #expect(fixture.driver.requests.first?.cameraEnabled == false)
        #expect(await fixture.calendar.eventRequests == 2)
    }

    @Test(arguments: ["preview", "disconnect", "selection"])
    func invalidatedCalendarJoinDoesNotJoinOrReportAStaleRefreshError(_ change: String) async {
        let fixture = CalendarJoinFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.calendar.pauseNextEvents()
        let join = Task { await fixture.model.joinNextCalendarMeeting(expectedEventID: "ready") }
        await fixture.calendar.waitUntilPaused()
        var selectionTask: Task<Void, Never>?
        switch change {
        case "preview": fixture.model.enterPreview()
        case "disconnect": await fixture.model.disconnectGoogle()
        default:
            selectionTask = Task { await fixture.model.selectCalendar(GoogleCalendar(id: "fixture", name: "Fixture"), selected: false) }
            while fixture.model.selectedCalendarIDs.contains("fixture") { await Task.yield() }
        }
        await fixture.calendar.resumeEvents()
        await join.value
        await selectionTask?.value
        #expect(fixture.driver.requests.isEmpty)
        #expect(fixture.model.error == nil)
        #expect(fixture.model.selectedEvent == nil)
        #expect(!fixture.model.showJoinSheet)
    }

    @Test func validChoiceAmongRejectedLinksJoinsWithoutAnUnnecessaryChooser() async {
        let fixture = CalendarJoinFixture()
        defer { fixture.cleanUp() }
        let valid = URL(string: "https://us02web.zoom.us/j/12345678901?pwd=opaque-token")!
        let event = CalendarEvent(id: "mixed", title: "Mixed invitation", startDate: .now,
                                  endDate: Date().addingTimeInterval(900), calendarID: "fixture",
                                  calendarName: "Fixture", meetingURLs: [URL(string: "https://zoom.us/j/00000000000")!, valid])
        await fixture.model.join(event)
        #expect(fixture.driver.requests.first?.url == valid)
        #expect(fixture.driver.requests.count == 1)
        #expect(!fixture.model.showJoinSheet)
        #expect(fixture.model.error == nil)
    }
}

@MainActor
private final class CalendarJoinFixture {
    let suite = "CalendarJoinRegressionTests.\(UUID())"
    let preferences: UserDefaults
    let calendar = CalendarJoinClient()
    let driver = CalendarJoinDriver()
    let model: YapModel

    init() {
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(["fixture"], forKey: "selectedCalendarIDs")
        preferences.set("Test Person", forKey: "displayName")
        model = YapModel(preview: false, preferences: preferences,
                            meeting: MeetingCoordinator(driver: driver), calendarClient: calendar,
                            reminders: YapReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}))
    }
    func cleanUp() { preferences.removePersistentDomain(forName: suite) }
}

private actor CalendarJoinClient: YapCalendarServing {
    nonisolated let isConfigured = true
    private let listed = [GoogleCalendar(id: "fixture", name: "Fixture", isPrimary: true)]
    private var pauseNext = false
    private var paused = false
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?
    private(set) var eventRequests = 0

    func hasCredentials() -> Bool { true }
    func calendars() -> [GoogleCalendar] { listed }
    func cachedSnapshot() -> CalendarSnapshot? { nil }
    func clearCachedEvents() {}
    func connect(openURL: @escaping @MainActor @Sendable (URL) -> Void) -> [GoogleCalendar] { listed }
    func disconnect() {}
    func pauseNextEvents() { pauseNext = true }
    func waitUntilPaused() async {
        if !paused { await withCheckedContinuation { pauseWaiter = $0 } }
    }
    func resumeEvents() { resumeWaiter?.resume(); resumeWaiter = nil; paused = false }
    func events(in calendars: [GoogleCalendar], from: Date, to: Date) async -> [CalendarEvent] {
        eventRequests += 1
        if pauseNext {
            pauseNext = false; paused = true
            // Deliberately deliver after cancellation, like a late provider response.
            await withCheckedContinuation { continuation in
                resumeWaiter = continuation
                pauseWaiter?.resume(); pauseWaiter = nil
            }
        }
        return [CalendarEvent(id: "ready", title: "Ready meeting", startDate: Date().addingTimeInterval(-60),
                              endDate: Date().addingTimeInterval(900), calendarID: "fixture", calendarName: "Fixture",
                              meetingURLs: [URL(string: "https://zoom.us/j/12345678901")!])]
    }
}

@MainActor
private final class CalendarJoinDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: false, canShare: false, supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var requests: [MeetingRequest] = []
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws {
        requests.append(request)
        onEvent?(sessionID, .status(.inMeeting))
    }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { onEvent?(sessionID, .status(.idle)) }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws {}
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws {}
    func sendChat(text: String, sessionID: UUID) async throws {}
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {}
    func stopShare(sessionID: UUID) async throws {}
}
