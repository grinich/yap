import Foundation
import Testing
import WhooshCalendar
import WhooshMeetings
@testable import WhooshAppUI

@Suite("Calendar list changes", .serialized)
@MainActor
struct CalendarListRefreshTests {
    @Test func manualRefreshFindsNewCalendarsWithoutSelectingThem() async {
        let fixture = CalendarListFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.service.setCalendarIDs(["a", "b", "new"])
        #expect(await fixture.model.refresh())
        #expect(fixture.model.calendars.map(\.id) == ["a", "b", "new"])
        #expect(fixture.model.selectedCalendarIDs == ["a", "b"])
        #expect(await fixture.service.lastRequestedIDs == ["a", "b"])
        #expect(fixture.model.events.allSatisfy { $0.calendarID != "new" })
    }

    @Test func removedSelectionCannotBlockOtherCalendarsOrLeaveAnOldJoinSheet() async {
        let fixture = CalendarListFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        fixture.model.selectedEvent = fixture.model.events.first { $0.calendarID == "b" }
        fixture.model.joinLink = fixture.model.selectedEvent!.meetingURL!.absoluteString
        fixture.model.showJoinSheet = true
        await fixture.service.setCalendarIDs(["a"])
        #expect(await fixture.model.refresh())
        #expect(fixture.model.selectedCalendarIDs == ["a"])
        #expect(fixture.preferences.stringArray(forKey: "selectedCalendarIDs") == ["a"])
        #expect(await fixture.service.lastRequestedIDs == ["a"])
        #expect(fixture.model.events.map(\.calendarID) == ["a"])
        #expect(!fixture.model.showJoinSheet)
        #expect(fixture.model.joinLink.isEmpty)
    }

    @Test func emptySelectionRemainsEmptyWhenCalendarsAreAdded() async {
        let fixture = CalendarListFixture(selection: [])
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.service.setCalendarIDs(["a", "b", "new"])
        #expect(await fixture.model.refresh())
        #expect(fixture.model.selectedCalendarIDs.isEmpty)
        #expect(fixture.model.events.isEmpty)
        #expect(await fixture.service.lastRequestedIDs.isEmpty)
    }

    @Test func calendarListFinishingAfterPreviewCannotChangeRealSelection() async {
        let fixture = CalendarListFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.service.setCalendarIDs(["a"])
        await fixture.service.pauseNextList()
        let refresh = Task { await fixture.model.refresh() }
        await fixture.service.waitUntilPaused()
        fixture.model.enterPreview()
        await fixture.service.release()
        #expect(await !refresh.value)
        #expect(fixture.model.isPreview)
        #expect(fixture.model.selectedCalendarIDs == ["a", "b"])
        #expect(fixture.model.events.allSatisfy { $0.calendarID == "preview" })
    }
}

@MainActor
private final class CalendarListFixture {
    let suite = "WhooshCalendarListTests.\(UUID())"
    let preferences: UserDefaults
    let service = ChangingCalendarList()
    let model: WhooshModel

    init(selection: [String] = ["a", "b"]) {
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(selection, forKey: "selectedCalendarIDs")
        model = WhooshModel(preview: false, preferences: preferences, meeting: MeetingCoordinator(driver: DemoMeetingDriver()),
                            calendarClient: service,
                            reminders: WhooshReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}))
    }
    func cleanUp() { preferences.removePersistentDomain(forName: suite) }
}

private actor ChangingCalendarList: WhooshCalendarServing {
    nonisolated let isConfigured = true
    var ids = ["a", "b"]
    var lastRequestedIDs: [String] = []
    var shouldPause = false
    var paused = false
    var pauseWaiter: CheckedContinuation<Void, Never>?
    var pendingList: CheckedContinuation<Void, Never>?

    func hasCredentials() -> Bool { true }
    func cachedSnapshot() -> CalendarSnapshot? { nil }
    func clearCachedEvents() {}
    func disconnect() {}
    func calendars() async -> [GoogleCalendar] {
        let selectedIDs = ids
        if shouldPause {
            shouldPause = false; paused = true
            pauseWaiter?.resume(); pauseWaiter = nil
            await withCheckedContinuation { pendingList = $0 }
        }
        return selectedIDs.map { GoogleCalendar(id: $0, name: $0, isPrimary: $0 == "a") }
    }
    func connect(openURL: @escaping @MainActor @Sendable (URL) -> Void) async -> [GoogleCalendar] { await calendars() }
    func events(in calendars: [GoogleCalendar], from: Date, to: Date) throws -> [CalendarEvent] {
        lastRequestedIDs = calendars.map(\.id)
        guard Set(lastRequestedIDs).isSubset(of: Set(ids)) else { throw GoogleCalendarError.httpStatus(404) }
        return calendars.map {
            CalendarEvent(id: $0.id, title: $0.name, startDate: .now.addingTimeInterval(300), endDate: .now.addingTimeInterval(3_600),
                          calendarID: $0.id, calendarName: $0.name,
                          meetingURLs: [URL(string: "https://zoom.us/j/12345678901")!])
        }
    }
    func setCalendarIDs(_ ids: [String]) { self.ids = ids }
    func pauseNextList() { shouldPause = true }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }
    func release() { pendingList?.resume(); pendingList = nil; paused = false }
}
