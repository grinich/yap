import Foundation
import Testing
import YapCalendar
import YapMeetings
@testable import YapAppUI

@Suite("Calendar meeting identity")
struct CalendarMeetingMatchTests {
    @Test @MainActor func carriesScheduleAndClearsItWhenLeaving() async {
        let meeting = MeetingCoordinator(driver: DemoMeetingDriver())
        let interval = DateInterval(start: Date(), duration: 1800)
        await meeting.join(url: URL(string: "https://zoom.us/j/12345678901")!, displayName: "Me", title: "Team sync", scheduledInterval: interval)
        #expect(meeting.displayTitle == "Team sync")
        #expect(meeting.scheduledInterval == interval)
        await meeting.leave()
        #expect(meeting.scheduledInterval == nil)
    }
    @Test @MainActor func calendarContextOnlyUpdatesItsActiveSession() async {
        let meeting = MeetingCoordinator(driver: DemoMeetingDriver())
        await meeting.join(url: URL(string: "https://zoom.us/j/12345678901")!, displayName: "Me")
        let session = meeting.sessionID!
        let interval = DateInterval(start: .now, duration: 1800)
        meeting.updateCalendarContext(title: "Wrong session", scheduledInterval: interval, sessionID: UUID())
        #expect(meeting.displayTitle == "Your meeting")
        meeting.updateCalendarContext(title: "Team sync", scheduledInterval: interval, sessionID: session)
        #expect(meeting.displayTitle == "Team sync")
        #expect(meeting.scheduledInterval == interval)
        await meeting.leave()
        meeting.updateCalendarContext(title: "Old session", scheduledInterval: interval, sessionID: session)
        #expect(meeting.meetingTitle.isEmpty)
        #expect(meeting.scheduledInterval == nil)
    }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func event(_ id: String, offset: TimeInterval = -600, cancelled: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: "Team sync", startDate: now.addingTimeInterval(offset),
                      endDate: now.addingTimeInterval(offset + 1800), calendarID: "work", calendarName: "Work",
                      meetingURLs: [URL(string: "https://work.zoom.us/j/12345678901?pwd=original")!], isCancelled: cancelled)
    }
    @Test func matchesDifferentParametersAndHostForTheSameMeeting() {
        let url = URL(string: "https://zoom.us/j/12345678901?pwd=other")!
        #expect(CalendarMeetingMatch.event(for: url, in: [event("today"), event("tomorrow", offset: 86400)], now: now)?.id == "today")
        #expect(CalendarMeetingMatch.event(for: url, in: [event("cancelled", cancelled: true)], now: now) == nil)
        #expect(CalendarMeetingMatch.event(for: url, in: [event("ended", offset: -3600)], now: now) == nil)
        #expect(CalendarMeetingMatch.event(for: url, in: [event("one"), event("two")], now: now) == nil)
        #expect(CalendarMeetingMatch.event(for: url, in: [event("soon", offset: 300)], now: now)?.id == "soon")
        #expect(!CalendarMeetingMatch.matches(URL(string: "https://zoom.us/j/99999999999")!, event: event("today")))
    }
}
