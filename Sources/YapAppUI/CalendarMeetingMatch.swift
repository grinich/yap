import Foundation
import YapCalendar

/// Match the meeting identity, not its password or browser tracking parameters.
enum CalendarMeetingMatch {
    static func matches(_ url: URL, event: CalendarEvent) -> Bool {
        guard let normalized = ZoomMeetingLinkParser.normalizedJoinURL(url.absoluteString) else { return false }
        return event.meetingURLs.contains {
            guard let candidate = ZoomMeetingLinkParser.normalizedJoinURL($0.absoluteString) else { return false }
            return candidate.lastPathComponent == normalized.lastPathComponent
        }
    }

    static func event(for url: URL, in events: [CalendarEvent], now: Date = .now) -> CalendarEvent? {
        let candidates = events.filter {
            !$0.isCancelled && !$0.isAllDay && $0.endDate > now &&
            $0.startDate <= now.addingTimeInterval(15 * 60) && matches(url, event: $0)
        }
        let ongoing = candidates.filter { $0.startDate <= now }
        let choices = ongoing.isEmpty ? candidates : ongoing
        // A reused room URL can identify several events. Don't invent a title.
        return choices.count == 1 ? choices.first : nil
    }
}
