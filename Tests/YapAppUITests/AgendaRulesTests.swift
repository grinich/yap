import Testing
import Foundation
import YapCalendar
@testable import YapAppUI

@Suite("Agenda and join routing")
struct AgendaRulesTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ id: String, start: TimeInterval, end: TimeInterval, cancelled: Bool = false, allDay: Bool = false,
               links: [URL] = [URL(string: "https://zoom.us/j/12345678901")!]) -> CalendarEvent {
        CalendarEvent(id: id, title: id, startDate: now.addingTimeInterval(start), endDate: now.addingTimeInterval(end), calendarID: "one", calendarName: "One", meetingURLs: links, isCancelled: cancelled, isAllDay: allDay)
    }

    @Test func onlyUpcomingActionableOccurrences() {
        let events = [event("ended", start: -200, end: -1), event("cancelled", start: 10, end: 50, cancelled: true), event("all-day", start: -1, end: 100, allDay: true), event("later", start: 30, end: 50), event("ongoing", start: -10, end: 10)]
        #expect(AgendaRules.upcoming(events, now: now).map(\.id) == ["ongoing", "later"])
    }

    @Test func joinButtonAppearsAtFiveMinutesAndStaysUntilMeetingEnds() {
        #expect(!AgendaRules.showsJoinButton(for: event("distant", start: 152_100, end: 153_900), now: now))
        #expect(!AgendaRules.showsJoinButton(for: event("just-too-early", start: 300.001, end: 2100), now: now))
        #expect(AgendaRules.showsJoinButton(for: event("five-minutes", start: 300, end: 2100), now: now))
        #expect(AgendaRules.showsJoinButton(for: event("starting", start: 0, end: 1800), now: now))
        #expect(AgendaRules.showsJoinButton(for: event("in-progress", start: -600, end: 1200), now: now))
        #expect(!AgendaRules.showsJoinButton(for: event("ended", start: -1800, end: 0), now: now))
    }

    @Test func joinWindowDoesNotMakeCancelledOrNonZoomEventsJoinable() {
        #expect(!AgendaRules.showsJoinButton(for: event("cancelled", start: 60, end: 1800, cancelled: true), now: now))
        #expect(!AgendaRules.showsJoinButton(for: event("all-day", start: 0, end: 86_400, allDay: true), now: now))
        #expect(!AgendaRules.showsJoinButton(for: event("no-link", start: 60, end: 1800, links: []), now: now))
    }

    @Test func sameMeetingLinkDoesNotMergeOccurrences() {
        let a = event("occurrence-a", start: 10, end: 20)
        let b = event("occurrence-b", start: 40, end: 50)
        #expect(AgendaRules.upcoming([b, a], now: now).map(\.id) == [a.id, b.id])
    }

    @Test func agendaShowsOnlyZoomMeetingsWithoutChangingFetchedEvents() {
        let fetched = [
            event("focus-time", start: 1, end: 30, links: []),
            event("meet", start: 5, end: 40, links: [URL(string: "https://meet.google.com/example")!]),
            event("fake-zoom", start: 6, end: 40, links: [URL(string: "https://zoom.us.example.com/j/12345678901")!]),
            event("zoom", start: 10, end: 50)
        ]
        #expect(AgendaRules.upcoming(fetched, now: now).map(\.id) == ["zoom"])
        #expect(fetched.count == 4)
        #expect(fetched.first?.meetingURLs.isEmpty == true)
    }

    @Test func nonMeetingCalendarsProduceTheZoomEmptyState() {
        let fetched = [event("appointment", start: 1, end: 30, links: []),
                       event("task", start: 10, end: 50, links: [])]
        #expect(AgendaRules.upcoming(fetched, now: now).isEmpty)
    }

    @Test(arguments: [
        "https://zoom.com/j/12345678901",
        "https://zoom.us/j/00000000000",
        "https://zoom.us/j/12345678901?pwd=one&pwd=two",
        "https://zoom.us/j/12345678901?tk=one&tk=two"
    ])
    func agendaDoesNotAdvertiseInvitationsRejectedByTheMeetingSDK(_ link: String) {
        let invitation = event("rejected", start: 60, end: 900, links: [URL(string: link)!])
        #expect(AgendaRules.upcoming([invitation], now: now).isEmpty)
        #expect(!AgendaRules.showsJoinButton(for: invitation, now: now))
    }

    @Test func mixedInvitationRetainsOnlyUsableChoicesWithoutChangingProviderData() {
        let valid = URL(string: "https://us02web.zoom.us/j/12345678901?pwd=opaque-token")!
        let links = [URL(string: "https://zoom.us/j/00000000000")!, valid]
        let invitation = event("mixed", start: 60, end: 900, links: links)
        #expect(AgendaRules.meetingURLs(for: invitation) == [valid])
        #expect(AgendaRules.upcoming([invitation], now: now) == [invitation])
        #expect(invitation.meetingURLs == links)
    }

    @Test func invitationsWithMultipleZoomLinksRemainAvailableForExplicitChoice() {
        let links = [URL(string: "https://zoom.us/j/12345678901")!, URL(string: "https://zoom.us/j/12345678902")!]
        let invitation = event("choose-meeting", start: 1, end: 30, links: links)
        #expect(invitation.meetingURL == nil)
        #expect(AgendaRules.upcoming([invitation], now: now) == [invitation])
    }

    @Test func deepLinkRequiresExplicitTrustedMeeting() {
        #expect(YapDeepLink.meetingURL(from: URL(string: "yap://join?url=https%3A%2F%2Fzoom.us%2Fj%2F12345678901")!)?.host == "zoom.us")
        for scheme in ["whoosh", "zooom"] {
            #expect(YapDeepLink.meetingURL(from: URL(string: "\(scheme)://join?url=https%3A%2F%2Fzoom.us%2Fj%2F12345678901")!)?.host == "zoom.us")
            #expect(YapDeepLink.meetingURL(from: URL(string: "\(scheme)://join?url=https%3A%2F%2Fzoom.us.evil.example%2Fj%2F12345678901")!) == nil)
        }
        #expect(YapDeepLink.meetingURL(from: URL(string: "yap://join?url=https%3A%2F%2Fzoom.us.evil.example%2Fj%2F12345678901")!) == nil)
        #expect(YapDeepLink.meetingURL(from: URL(string: "yap://join?url=https%3A%2F%2Fzoom.us%2Fj%2F12345678901&url=https%3A%2F%2Fzoom.us%2Fj%2F12345678902")!) == nil)
    }

    @Test func googleImportRejectsWebClients() {
        #expect(throws: (any Error).self) { try YapConfigurationStore.parseGoogle(Data(#"{"web":{"client_id":"test.apps.googleusercontent.com"}}"#.utf8)) }
        #expect(throws: (any Error).self) { try YapConfigurationStore.parseGoogle(Data(#"{"installed":{"client_id":"untrusted"}}"#.utf8)) }
    }
}
