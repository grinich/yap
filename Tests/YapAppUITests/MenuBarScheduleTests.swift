import AppKit
import Foundation
import Testing
import YapCalendar
@testable import YapAppUI

@Suite("Menu bar calendar schedule")
struct MenuBarScheduleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private let locale = Locale(identifier: "en_US")
    private var now: Date { date(day: 14, hour: 10) }

    @Test func groupsAllEventsIntoTodayTomorrowAndEarlierToday() {
        let events = [
            event("tomorrow", day: 15, hour: 9),
            event("non-zoom", day: 14, hour: 12, zoom: false),
            event("current", day: 14, hour: 9, minute: 50),
            event("past", day: 14, hour: 8),
            event("all-day", day: 14, hour: 0, duration: 86_400, allDay: true, zoom: false),
            event("cancelled", day: 14, hour: 13, cancelled: true),
            event("yesterday", day: 13, hour: 18),
            event("later", day: 16, hour: 9)
        ]
        let schedule = MenuBarSchedule(events: events, now: now, calendar: calendar, locale: locale)

        #expect(schedule.days.count == 2)
        #expect(schedule.days[0].title.hasPrefix("Today"))
        #expect(schedule.days[1].title.hasPrefix("Tomorrow"))
        #expect(schedule.days[0].entries.map(\.event.id) == ["all-day", "current", "non-zoom"])
        #expect(schedule.days[0].pastEntries.map(\.event.id) == ["past"])
        #expect(schedule.days[1].entries.map(\.event.id) == ["tomorrow"])
        #expect(schedule.summary?.event.id == "current")
        #expect(schedule.summary?.relativeTime == "Ends in 50 min")
        #expect(schedule.days[0].entries[0].time == "All day")
    }

    @Test func joinEligibilityKeepsTheExistingWindowAndExcludesNonmeetings() {
        let schedule = MenuBarSchedule(events: [
            event("ready", day: 14, hour: 10, minute: 5),
            event("later", day: 14, hour: 10, minute: 6),
            event("non-zoom", day: 14, hour: 10, minute: 1, zoom: false),
            event("all-day", day: 14, hour: 0, duration: 86_400, allDay: true),
            event("ended", day: 14, hour: 9)
        ], now: now, calendar: calendar, locale: locale)
        let entries = schedule.days.flatMap { $0.entries + $0.pastEntries }

        #expect(entries.filter(\.canJoin).map(\.event.id) == ["ready"])
        #expect(schedule.summary?.event.id == "non-zoom")
        #expect(schedule.summary?.relativeTime == "In 1 min")
    }

    @Test func emptyDaysRemainVisibleAndAllDayEventsDoNotBecomeTheCountdown() {
        let empty = MenuBarSchedule(events: [], now: now, calendar: calendar, locale: locale)
        #expect(empty.days.count == 2)
        #expect(empty.days.allSatisfy { $0.entries.isEmpty && $0.pastEntries.isEmpty })
        #expect(empty.summary == nil)

        let allDay = MenuBarSchedule(events: [event("holiday", day: 14, hour: 0, duration: 86_400, allDay: true)],
                                    now: now, calendar: calendar, locale: locale)
        #expect(allDay.days[0].entries.count == 1)
        #expect(allDay.summary == nil)
    }

    @Test func dayGroupingFollowsLocalMidnightAcrossDaylightSaving() throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let today = try #require(local.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0)))
        let tomorrow = try #require(local.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0)))
        let overnight = CalendarEvent(id: "overnight", title: "Overnight", startDate: tomorrow.addingTimeInterval(-1800),
                                     endDate: tomorrow.addingTimeInterval(1800), calendarID: "work", calendarName: "Work")
        let midnight = CalendarEvent(id: "midnight", title: "Midnight", startDate: tomorrow,
                                    endDate: tomorrow.addingTimeInterval(3600), calendarID: "work", calendarName: "Work")

        let schedule = MenuBarSchedule(events: [midnight, overnight], now: today, calendar: local, locale: locale)

        #expect(tomorrow.timeIntervalSince(today) == 23 * 3600)
        #expect(schedule.days[1].date == tomorrow)
        #expect(schedule.days[0].entries.map(\.event.id) == ["overnight"])
        #expect(schedule.days[1].entries.map(\.event.id) == ["overnight", "midnight"])
    }

    @Test func calendarLinksUseTheLocalGregorianDayAndNeverEventText() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = calendar.timeZone
        #expect(MenuBarSchedule.calendarURL(for: now, calendar: buddhist).absoluteString ==
                "https://calendar.google.com/calendar/r/day/2026/9/14")
        #expect(MenuBarSchedule.compactTitle("  A title\nwith\tspacing  ") == "A title with spacing")
        #expect(MenuBarSchedule.compactTitle(String(repeating: "A", count: 100)).count == 45)
    }

    @Test @MainActor func constructingTheNativeMenuIsReadOnlyAndKeepsJoinBoundToTheEvent() throws {
        let ready = event("ready", day: 14, hour: 10, minute: 2)
        let focus = event("focus", day: 14, hour: 11, zoom: false)
        let schedule = MenuBarSchedule(events: [ready, focus], now: now, calendar: calendar, locale: locale)
        var requests: [MenuBarScheduleRequest] = []
        let builder = MenuBarScheduleMenu(schedule: schedule, calendars: []) { requests.append($0) }
        let row = try #require(builder.menu.items.first { $0.title == ready.title && $0.submenu != nil })
        let join = try #require(row.submenu?.items.first { $0.representedObject as? MenuBarScheduleRequest == .join(eventID: "ready") })
        let localRow = try #require(builder.menu.items.first { $0.title == focus.title })

        #expect(requests.isEmpty)
        #expect(row.subtitle != nil)
        #expect(join.isEnabled)
        #expect(builder.menu.items.contains { $0.isSectionHeader })
        #expect(localRow.submenu?.items.contains { $0.title == "No Zoom link in this event" } == true)
        let localRequests = localRow.submenu?.items.compactMap { $0.representedObject as? MenuBarScheduleRequest } ?? []
        #expect(!localRequests.contains { if case .join = $0 { return true }; return false })
    }

    @Test @MainActor func activeMeetingDisablesScheduleJoiningWithoutHidingCalendarDetails() throws {
        let ready = event("ready", day: 14, hour: 10, minute: 2)
        let schedule = MenuBarSchedule(events: [ready], now: now, calendar: calendar, locale: locale)
        let builder = MenuBarScheduleMenu(schedule: schedule, calendars: [], allowsJoining: false) { _ in }
        let row = try #require(builder.menu.items.first { $0.title == ready.title && $0.submenu != nil })
        let join = try #require(row.submenu?.items.first { $0.title == "Join Zoom meeting" })
        let open = try #require(row.submenu?.items.first { $0.title == "Open day in Google Calendar" })
        #expect(!join.isEnabled)
        #expect(open.isEnabled)
    }

    @Test @MainActor func disconnectedMenuOffersSetupWithoutShowingCachedEvents() {
        let schedule = MenuBarSchedule(events: [event("private", day: 14, hour: 11)], now: now, calendar: calendar, locale: locale)
        var requests: [MenuBarScheduleRequest] = []
        let builder = MenuBarScheduleMenu(schedule: schedule, calendars: [], state: .disconnected) { requests.append($0) }
        #expect(!builder.menu.items.contains { $0.title == "private" })
        #expect(builder.menu.items.contains { $0.representedObject as? MenuBarScheduleRequest == .connectCalendar })
        #expect(requests.isEmpty)
    }

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func event(_ id: String, day: Int, hour: Int, minute: Int = 0, duration: TimeInterval = 3600,
                       allDay: Bool = false, zoom: Bool = true, cancelled: Bool = false) -> CalendarEvent {
        let start = date(day: day, hour: hour, minute: minute)
        return CalendarEvent(id: id, title: id, startDate: start, endDate: start.addingTimeInterval(duration),
                             calendarID: "work", calendarName: "Work",
                             meetingURLs: zoom ? [URL(string: "https://zoom.us/j/12345678901")!] : [],
                             isCancelled: cancelled, isAllDay: allDay)
    }
}
