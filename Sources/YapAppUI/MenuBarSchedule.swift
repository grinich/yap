import AppKit
import Foundation
import YapCalendar

/// A calendar-day snapshot keeps menu grouping independent of the agenda's Zoom-only filter.
struct MenuBarSchedule {
    struct Entry: Equatable {
        let event: CalendarEvent
        let time: String
        let relativeTime: String
        let isPast: Bool
        let isCurrent: Bool
        let canJoin: Bool
    }

    struct Day {
        let title: String
        let date: Date
        let entries: [Entry]
        let pastEntries: [Entry]
    }

    let days: [Day]
    let summary: Entry?
    let now: Date

    init(events: [CalendarEvent], now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) {
        self.now = now
        let today = calendar.startOfDay(for: now)
        let valid = events.filter { !$0.isCancelled && $0.endDate > $0.startDate }
        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.setLocalizedDateFormatFromTemplate("EEE MMM d")

        days = (0...1).compactMap { offset in
            guard let start = calendar.date(byAdding: .day, value: offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let entries = valid.filter { $0.startDate < end && $0.endDate > start }
                .sorted {
                    if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                    if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                    return $0.id < $1.id
                }.map { event in
                    let past = event.endDate <= now
                    let current = !event.isAllDay && event.startDate <= now && event.endDate > now
                    let time = event.isAllDay ? "All day" : "\(timeFormatter.string(from: event.startDate)) – \(timeFormatter.string(from: event.endDate))"
                    let relative: String
                    if past { relative = "Ended" }
                    else if event.isAllDay { relative = "All day" }
                    else if current { relative = "Ends in \(Self.duration(event.endDate.timeIntervalSince(now)))" }
                    else { relative = "In \(Self.duration(event.startDate.timeIntervalSince(now)))" }
                    return Entry(event: event, time: time, relativeTime: relative, isPast: past, isCurrent: current,
                                 canJoin: AgendaRules.showsJoinButton(for: event, now: now))
                }
            return Day(title: "\(offset == 0 ? "Today" : "Tomorrow") · \(dateFormatter.string(from: start))", date: start,
                       entries: entries.filter { !$0.isPast }, pastEntries: entries.filter(\.isPast))
        }
        summary = days.flatMap(\.entries).filter { !$0.event.isAllDay }
            .sorted {
                if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
                if $0.event.startDate != $1.event.startDate { return $0.event.startDate < $1.event.startDate }
                return $0.event.id < $1.event.id
            }.first
    }

    static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int(ceil(interval / 60)))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    static func compactTitle(_ title: String, limit: Int = 45) -> String {
        let title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !title.isEmpty else { return "Untitled event" }
        return title.count > limit ? String(title.prefix(limit - 1)) + "…" : title
    }

    static func calendarURL(for date: Date, calendar: Calendar = .current) -> URL {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let components = gregorian.dateComponents([.year, .month, .day], from: date)
        return URL(string: "https://calendar.google.com/calendar/r/day/\(components.year!)/\(components.month!)/\(components.day!)")!
    }
}

enum MenuBarScheduleState {
    case ready, loading, disconnected, noCalendars, unavailable
}

enum MenuBarScheduleRequest: Equatable {
    case join(eventID: String)
    case openCalendar(URL)
    case connectCalendar
    case settings
}

/// Uses native menu subtitles and section headers, preserving AppKit tracking and keyboard navigation.
@MainActor
final class MenuBarScheduleMenu: NSObject {
    let menu = NSMenu()
    private let select: (MenuBarScheduleRequest) -> Void
    private let schedule: MenuBarSchedule
    private let calendars: [GoogleCalendar]
    private let allowsJoining: Bool

    init(schedule: MenuBarSchedule, calendars: [GoogleCalendar], state: MenuBarScheduleState = .ready,
         isRefreshing: Bool = false, refreshError: String? = nil, allowsJoining: Bool = true,
         select: @escaping (MenuBarScheduleRequest) -> Void) {
        self.schedule = schedule
        self.calendars = calendars
        self.allowsJoining = allowsJoining
        self.select = select
        super.init()
        menu.autoenablesItems = false
        menu.minimumWidth = 350
        switch state {
        case .loading:
            addNotice("Loading your calendar…", subtitle: "Your schedule will appear here.", symbol: "calendar")
            return
        case .disconnected:
            addNotice("Your day, a click away", subtitle: "Connect Google Calendar to see your schedule.", symbol: "calendar")
            addAction("Connect Google Calendar…", request: .connectCalendar, to: menu)
            return
        case .unavailable:
            addNotice("Calendar unavailable", subtitle: "Sign in to Google Calendar to try again.", symbol: "exclamationmark.triangle")
            addAction("Sign in to Google Calendar…", request: .connectCalendar, to: menu)
            return
        case .noCalendars:
            addNotice("Choose your calendars", subtitle: "Select calendars in Settings to show their events.", symbol: "calendar")
            addAction("Choose calendars…", request: .settings, to: menu)
            return
        case .ready: break
        }
        if let refreshError {
            addNotice("Couldn’t refresh calendar", subtitle: refreshError, symbol: "exclamationmark.triangle")
            menu.addItem(.separator())
        } else if isRefreshing {
            addNotice("Refreshing calendar…", subtitle: "Showing your saved schedule.", symbol: "arrow.clockwise")
            menu.addItem(.separator())
        }
        if let entry = schedule.summary {
            menu.addItem(.sectionHeader(title: entry.isCurrent ? "Happening now" : "Up next"))
            let item = eventItem(entry)
            item.subtitle = "\(entry.relativeTime) · \(entry.time)"
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for day in schedule.days {
            menu.addItem(.sectionHeader(title: day.title))
            if day.entries.isEmpty {
                let empty = NSMenuItem(title: day.pastEntries.isEmpty ? "No events" : "Nothing else today", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            } else {
                for entry in day.entries { menu.addItem(eventItem(entry)) }
            }
            if !day.pastEntries.isEmpty {
                let earlier = NSMenuItem(title: "Earlier today", action: nil, keyEquivalent: "")
                earlier.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                for entry in day.pastEntries { submenu.addItem(eventItem(entry)) }
                earlier.submenu = submenu
                menu.addItem(earlier)
            }
            if day.date != schedule.days.last?.date { menu.addItem(.separator()) }
        }
    }

    private func eventItem(_ entry: MenuBarSchedule.Entry) -> NSMenuItem {
        let event = entry.event
        let title = MenuBarSchedule.compactTitle(event.title)
        let item = NSMenuItem(title: title, action: #selector(performScheduleAction(_:)), keyEquivalent: "")
        item.target = self
        item.subtitle = "\(entry.time) · \(MenuBarSchedule.compactTitle(event.calendarName, limit: 28))"
        let details = "\(event.title)\n\(entry.time)\n\(event.calendarName)"
        item.image = eventImage(event)
        let links = AgendaRules.meetingURLs(for: event)
        if !links.isEmpty {
            item.representedObject = MenuBarScheduleRequest.join(eventID: event.id)
            item.isEnabled = entry.canJoin && allowsJoining
            let actionHint: String
            if item.isEnabled {
                actionHint = links.count > 1 ? "Choose Zoom meeting…" : "Join Zoom meeting"
            } else {
                actionHint = !allowsJoining ? "Leave your current meeting to join another."
                    : entry.isPast ? "This event has ended."
                    : event.isAllDay ? "All-day events don’t have a join time."
                    : "Available five minutes before the start."
            }
            item.toolTip = "\(details)\n\(actionHint)"
        } else {
            item.representedObject = MenuBarScheduleRequest.openCalendar(MenuBarSchedule.calendarURL(for: event.startDate))
            item.toolTip = "\(details)\nOpen day in Google Calendar"
        }
        return item
    }

    private func eventImage(_ event: CalendarEvent) -> NSImage? {
        let symbol = !AgendaRules.meetingURLs(for: event).isEmpty ? "video.fill" : event.isAllDay ? "sun.max" : "calendar"
        let hex = calendars.first { $0.id == event.calendarID }?.colorHex?.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let color: NSColor
        if let hex, hex.count == 6, let value = UInt32(hex, radix: 16) {
            color = NSColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                            blue: CGFloat(value & 255) / 255, alpha: 1)
        } else { color = .secondaryLabelColor }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
    }

    private func addNotice(_ title: String, subtitle: String, symbol: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.subtitle = MenuBarSchedule.compactTitle(subtitle, limit: 72)
        item.toolTip = subtitle
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult private func addAction(_ title: String, request: MenuBarScheduleRequest, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performScheduleAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = request
        menu.addItem(item)
        return item
    }

    @objc private func performScheduleAction(_ sender: NSMenuItem) {
        guard sender.isEnabled, let request = sender.representedObject as? MenuBarScheduleRequest else { return }
        select(request)
    }
}
