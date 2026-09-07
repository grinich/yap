import Foundation
import Testing
import WhooshCalendar
@testable import WhooshAppUI

@Suite("Agenda date presentation")
struct AgendaPresentationTests {
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ year: Int = 2026, _ month: Int = 9, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func event(start: Date, end: Date) -> CalendarEvent {
        CalendarEvent(id: "synthetic", title: "Planning", startDate: start, endDate: end,
                      calendarID: "calendar", calendarName: "Calendar",
                      meetingURLs: [URL(string: "https://zoom.us/j/12345678901")!])
    }

    @Test func futureOnlyAndEmptyAgendasDoNotClaimToday() {
        let now = date(2026, 9, 6, 12)
        let tomorrow = event(start: date(2026, 9, 7, 9), end: date(2026, 9, 7, 10))
        #expect(AgendaPresentation.heading(for: [tomorrow], now: now, calendar: calendar) == "Upcoming")
        #expect(AgendaPresentation.heading(for: [], now: now, calendar: calendar) == "Agenda")
    }

    @Test func ongoingOvernightMeetingStillBelongsToToday() {
        let now = date(2026, 9, 7, 0, 10)
        let overnight = event(start: date(2026, 9, 6, 23), end: date(2026, 9, 7, 1))
        #expect(AgendaPresentation.heading(for: [overnight], now: now, calendar: calendar) == "Today")
        #expect(AgendaPresentation.startLabel(for: overnight, now: now, calendar: calendar) == "Scheduled now")
    }

    @Test func midnightUpdatesHeaderAndDatesWithoutChangingJoinEligibility() {
        let before = date(2026, 9, 6, 23, 50)
        let after = date(2026, 9, 7, 0, 10)
        let meeting = event(start: date(2026, 9, 7, 0, 15), end: date(2026, 9, 7, 1))
        #expect(AgendaPresentation.headerDate(now: before, calendar: calendar, locale: locale) !=
                AgendaPresentation.headerDate(now: after, calendar: calendar, locale: locale))
        #expect(AgendaPresentation.startLabel(for: meeting, now: before, calendar: calendar) == "Tomorrow")
        #expect(AgendaPresentation.startLabel(for: meeting, now: after, calendar: calendar) == "In 5 min")
        #expect(AgendaPresentation.heading(for: [meeting], now: after, calendar: calendar) == "Today")
        #expect(AgendaPresentation.dateLabel(for: meeting.startDate, now: after, calendar: calendar) == nil)
        #expect(!AgendaRules.showsJoinButton(for: meeting, now: before))
        #expect(AgendaRules.showsJoinButton(for: meeting, now: after))
    }

    @Test func tomorrowUsesCalendarDaysAcrossDaylightSavingChange() {
        let now = date(2026, 3, 7, 23, 50)
        let tomorrow = date(2026, 3, 8, 23, 55)
        #expect(AgendaPresentation.dateLabel(for: tomorrow, now: now, calendar: calendar) == "Tomorrow")
        #expect(AgendaPresentation.dateLabel(for: date(2026, 3, 9, 0), now: now, calendar: calendar) != "Tomorrow")
    }

    @Test func distantDatesIncludeWeekdayAndDifferentYear() {
        let now = date(2026, 12, 30, 12)
        let label = AgendaPresentation.dateLabel(for: date(2027, 1, 2, 9), now: now, calendar: calendar, locale: locale)
        #expect(label?.contains("Sat") == true)
        #expect(label?.contains("2027") == true)
    }
}
