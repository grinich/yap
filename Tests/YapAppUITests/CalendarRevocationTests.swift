import Foundation
import Testing
import YapCalendar
import YapMeetings
@testable import YapAppUI

@Suite("Calendar access revocation", .serialized)
@MainActor
struct CalendarRevocationTests {
    @Test func inaccessibleCalendarDisappearsFromVisibleAgendaAndJoinSheet() async {
        let fixture = RevocationFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        fixture.model.selectedEvent = fixture.items[1]
        fixture.model.joinLink = fixture.items[1].meetingURL!.absoluteString
        fixture.model.showJoinSheet = true
        await fixture.service.revokeCalendarB()
        #expect(await !fixture.model.refresh())
        #expect(fixture.model.events.map(\.calendarID) == ["a"])
        #expect(fixture.model.lastRefreshed == fixture.cacheDate)
        #expect(fixture.model.selectedEvent == nil)
        #expect(fixture.model.joinLink.isEmpty)
        #expect(!fixture.model.showJoinSheet)
    }

    @Test func expiredGoogleGrantClearsAgendaAndConnectionState() async {
        let fixture = RevocationFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.service.expireConnection()
        #expect(await !fixture.model.refresh())
        #expect(fixture.model.events.isEmpty)
        #expect(fixture.model.calendars.isEmpty)
        #expect(fixture.model.lastRefreshed == nil)
        #expect(!fixture.model.isCalendarConnected)
        #expect(fixture.remindersDisabled == 1)
    }

    @Test func startupRevocationCannotLeaveTheLaunchCacheVisible() async {
        let fixture = RevocationFixture()
        defer { fixture.cleanUp() }
        await fixture.service.revokeCalendarListing()
        await fixture.model.start()
        #expect(fixture.model.events.isEmpty)
        #expect(fixture.model.lastRefreshed == nil)
        #expect(fixture.model.error != nil)
    }

    @Test func previewRejectsALateCacheReconciliationAfterAccessError() async {
        let fixture = RevocationFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.service.revokeCalendarB(pauseReconciliation: true)
        let refresh = Task { await fixture.model.refresh() }
        await fixture.service.waitUntilCacheReadPaused()
        fixture.model.enterPreview()
        await fixture.service.releaseCacheRead()
        #expect(await !refresh.value)
        #expect(fixture.model.isPreview)
        #expect(fixture.model.events.allSatisfy { $0.calendarID == "preview" })
    }
}

@MainActor
private final class RevocationFixture {
    let suite = "YapRevocationTests.\(UUID())"
    let preferences: UserDefaults
    let cacheDate = Date(timeIntervalSince1970: 1_800_000_000)
    let items: [CalendarEvent]
    let service: RevocationCalendar
    var remindersDisabled = 0
    var model: YapModel!

    init() {
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(["a", "b"], forKey: "selectedCalendarIDs")
        let now = Date()
        items = ["a", "b"].map {
            CalendarEvent(id: $0, title: $0, startDate: now.addingTimeInterval(300), endDate: now.addingTimeInterval(3600),
                          calendarID: $0, calendarName: $0,
                          meetingURLs: [URL(string: "https://zoom.us/j/12345678901")!])
        }
        service = RevocationCalendar(items: items, fetchedAt: cacheDate)
        model = YapModel(preview: false, preferences: preferences, meeting: MeetingCoordinator(driver: DemoMeetingDriver()),
                            calendarClient: service,
                            reminders: YapReminderActions(requestAuthorization: { false }, synchronize: { _, _ in },
                                                             disable: { [weak self] in self?.remindersDisabled += 1 }))
    }

    func cleanUp() { preferences.removePersistentDomain(forName: suite) }
}

private actor RevocationCalendar: YapCalendarServing {
    nonisolated let isConfigured = true
    let items: [CalendarEvent]
    let fetchedAt: Date
    var cached: [CalendarEvent]?
    var fetchError: GoogleCalendarError?
    var listingRevoked = false
    var pauseCache = false
    var cachePaused = false
    var cacheWaiter: CheckedContinuation<Void, Never>?
    var cacheContinuation: CheckedContinuation<Void, Never>?

    init(items: [CalendarEvent], fetchedAt: Date) { self.items = items; self.fetchedAt = fetchedAt; cached = items }
    func hasCredentials() -> Bool { true }
    func calendars() throws -> [GoogleCalendar] {
        if listingRevoked { cached = nil; throw GoogleCalendarError.httpStatus(403) }
        return [GoogleCalendar(id: "a", name: "A", isPrimary: true), GoogleCalendar(id: "b", name: "B")]
    }
    func cachedSnapshot() async -> CalendarSnapshot? {
        if pauseCache {
            pauseCache = false; cachePaused = true
            cacheWaiter?.resume(); cacheWaiter = nil
            await withCheckedContinuation { cacheContinuation = $0 }
        }
        guard let cached else { return nil }
        return CalendarSnapshot(events: cached, fetchedAt: fetchedAt, calendarIDs: cached.map(\.calendarID), windowStart: .distantPast, windowEnd: .distantFuture)
    }
    func events(in calendars: [GoogleCalendar], from: Date, to: Date) throws -> [CalendarEvent] {
        if let fetchError { throw fetchError }
        return items
    }
    func clearCachedEvents() { cached = nil }
    func disconnect() { cached = nil }
    func connect(openURL: @escaping @MainActor @Sendable (URL) -> Void) throws -> [GoogleCalendar] { try calendars() }
    func revokeCalendarB(pauseReconciliation: Bool = false) {
        cached = items.filter { $0.calendarID == "a" }; fetchError = .httpStatus(404); pauseCache = pauseReconciliation
    }
    func expireConnection() { cached = nil; fetchError = .signInExpired }
    func revokeCalendarListing() { listingRevoked = true }
    func waitUntilCacheReadPaused() async {
        if cachePaused { return }
        await withCheckedContinuation { cacheWaiter = $0 }
    }
    func releaseCacheRead() { cacheContinuation?.resume(); cacheContinuation = nil }
}
