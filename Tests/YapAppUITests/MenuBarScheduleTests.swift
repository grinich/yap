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
        let rows = builder.menu.items.filter { $0.title == ready.title }
        let localRow = try #require(builder.menu.items.first { $0.title == focus.title })

        #expect(requests.isEmpty)
        #expect(rows.count == 2) // Summary and the day's schedule both use direct rows.
        for row in rows {
            #expect(row.submenu == nil)
            #expect(row.action != nil)
            #expect(row.isEnabled)
            #expect(row.representedObject as? MenuBarScheduleRequest == .join(eventID: "ready"))
            #expect(row.toolTip?.contains(ready.calendarName) == true)
        }
        #expect(rows.last?.subtitle?.contains(ready.calendarName) == true)
        #expect(builder.menu.items.contains { $0.isSectionHeader })
        #expect(localRow.submenu == nil)
        #expect(localRow.representedObject as? MenuBarScheduleRequest ==
                .openCalendar(MenuBarSchedule.calendarURL(for: focus.startDate)))
    }

    @Test @MainActor func activatingSummaryAndDayRowsDispatchesTheExactSelectedEventOnce() throws {
        let summary = event("summary", day: 14, hour: 10, minute: 2)
        let other = event("different-event", day: 14, hour: 10, minute: 4)
        let schedule = MenuBarSchedule(events: [other, summary], now: now, calendar: calendar, locale: locale)
        var requests: [MenuBarScheduleRequest] = []
        let builder = MenuBarScheduleMenu(schedule: schedule, calendars: []) { requests.append($0) }
        let rows = builder.menu.items.filter { $0.title == summary.title || $0.title == other.title }
        #expect(rows.map(\.title) == [summary.title, summary.title, other.title])
        #expect(requests.isEmpty)

        for row in rows {
            #expect(row.submenu == nil)
            let index = try #require(builder.menu.items.firstIndex { $0 === row })
            requests.removeAll()
            _ = NSApplication.shared
            builder.menu.performActionForItem(at: index)
            #expect(requests == [.join(eventID: row.title == other.title ? other.id : summary.id)])
        }
    }

    @Test(arguments: ["future", "current meeting", "all day"])
    @MainActor func disabledRowsRetainDetailsAndCannotDispatch(_ reason: String) throws {
        let meeting = event("unavailable", day: 14, hour: reason == "future" ? 11 : 10, minute: 2,
                            duration: reason == "all day" ? 86_400 : 3600, allDay: reason == "all day")
        let schedule = MenuBarSchedule(events: [meeting], now: now, calendar: calendar, locale: locale)
        let entry = try #require(schedule.days[0].entries.first)
        var requests: [MenuBarScheduleRequest] = []
        let builder = MenuBarScheduleMenu(schedule: schedule, calendars: [], allowsJoining: reason != "current meeting") {
            requests.append($0)
        }
        let rows = builder.menu.items.filter { $0.title == meeting.title }
        #expect(!rows.isEmpty)
        for row in rows {
            #expect(row.submenu == nil)
            #expect(!row.isEnabled)
            #expect(row.subtitle?.contains(entry.time) == true)
            #expect(row.toolTip?.contains(meeting.calendarName) == true)
            let explanation = reason == "future" ? "five minutes" : reason == "all day" ? "All-day" : "current meeting"
            #expect(row.toolTip?.contains(explanation) == true)
            let action = try #require(row.action)
            // Exercise the handler too: even a stale AppKit action cannot join a disabled row.
            #expect(NSApplication.shared.sendAction(action, to: row.target, from: row))
        }
        #expect(rows.last?.subtitle?.contains(meeting.calendarName) == true)
        #expect(requests.isEmpty)
    }

    @Test @MainActor func nonZoomRowsOpenTheirCalendarDayDirectlyDuringAnActiveMeeting() throws {
        let focus = event("focus", day: 14, hour: 10, minute: 2, zoom: false)
        let schedule = MenuBarSchedule(events: [focus], now: now, calendar: calendar, locale: locale)
        var requests: [MenuBarScheduleRequest] = []
        let builder = MenuBarScheduleMenu(schedule: schedule, calendars: [], allowsJoining: false) { requests.append($0) }
        let rows = builder.menu.items.filter { $0.title == focus.title }
        #expect(rows.count == 2)
        for row in rows {
            #expect(row.submenu == nil)
            #expect(row.isEnabled)
            requests.removeAll()
            let index = try #require(builder.menu.items.firstIndex { $0 === row })
            _ = NSApplication.shared
            builder.menu.performActionForItem(at: index)
            #expect(requests == [.openCalendar(MenuBarSchedule.calendarURL(for: focus.startDate))])
        }
    }

    @Test @MainActor func multipleZoomLinksDispatchTheEventToTheExistingMeetingChooser() throws {
        let start = date(day: 14, hour: 10, minute: 2)
        let meeting = CalendarEvent(id: "multiple-links", title: "Choose the meeting", startDate: start,
            endDate: start.addingTimeInterval(3600), calendarID: "work", calendarName: "Work", meetingURLs: [
                URL(string: "https://zoom.us/j/12345678901")!, URL(string: "https://zoom.us/j/98765432101")!
            ])
        let schedule = MenuBarSchedule(events: [meeting], now: now, calendar: calendar, locale: locale)
        var requests: [MenuBarScheduleRequest] = []
        let builder = MenuBarScheduleMenu(schedule: schedule, calendars: []) { requests.append($0) }
        let rows = builder.menu.items.filter { $0.title == meeting.title }
        #expect(rows.count == 2)
        for row in rows {
            #expect(row.submenu == nil)
            #expect(row.isEnabled)
            #expect(row.representedObject as? MenuBarScheduleRequest == .join(eventID: meeting.id))
            requests.removeAll()
            let index = try #require(builder.menu.items.firstIndex { $0 === row })
            _ = NSApplication.shared
            builder.menu.performActionForItem(at: index)
            #expect(requests == [.join(eventID: meeting.id)])
        }
    }

    @Test @MainActor func earlierTodayKeepsItsGroupingWithoutNestedEventSubmenus() throws {
        let ended = event("ended", day: 14, hour: 8)
        let schedule = MenuBarSchedule(events: [ended], now: now, calendar: calendar, locale: locale)
        var requests: [MenuBarScheduleRequest] = []
        let builder = MenuBarScheduleMenu(schedule: schedule, calendars: []) { requests.append($0) }
        let earlier = try #require(builder.menu.items.first { $0.title == "Earlier today" }?.submenu)
        let row = try #require(earlier.items.first { $0.title == ended.title })
        #expect(row.submenu == nil)
        #expect(!row.isEnabled)
        #expect(row.subtitle?.contains(ended.calendarName) == true)
        #expect(row.toolTip?.contains("ended") == true)
        let action = try #require(row.action)
        #expect(NSApplication.shared.sendAction(action, to: row.target, from: row))
        #expect(requests.isEmpty)
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
