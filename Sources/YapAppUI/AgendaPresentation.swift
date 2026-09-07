import Foundation
import YapCalendar

enum AgendaPresentation {
    /// The input contains only agenda-eligible occurrences, including ongoing ones.
    static func heading(for upcoming: [CalendarEvent], now: Date, calendar: Calendar = .current) -> String {
        guard !upcoming.isEmpty else { return "Agenda" }
        guard let day = calendar.dateInterval(of: .day, for: now) else { return "Upcoming" }
        return upcoming.contains { $0.startDate < day.end && $0.endDate > now } ? "Today" : "Upcoming"
    }

    static func headerDate(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = locale
        return now.formatted(style)
    }

    static func startLabel(for event: CalendarEvent, now: Date, calendar: Calendar = .current,
                           locale: Locale = .current) -> String {
        guard event.startDate > now else { return "Scheduled now" }
        if let date = dateLabel(for: event.startDate, now: now, calendar: calendar, locale: locale) { return date }
        let minutes = Int(ceil(event.startDate.timeIntervalSince(now) / 60))
        return minutes < 60 ? "In \(minutes) min" : "Today"
    }

    static func dateLabel(for date: Date, now: Date, calendar: Calendar = .current,
                          locale: Locale = .current) -> String? {
        guard !calendar.isDate(date, inSameDayAs: now) else { return nil }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = locale
        return date.formatted(style)
    }
}
