import CryptoKit
import Foundation

/// `id` must identify a calendar event occurrence, including its account and calendar.
public struct MeetingReminder: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let meetingURL: URL

    public init(id: String, title: String, startDate: Date, meetingURL: URL) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.meetingURL = meetingURL
    }
}

public struct ScheduledMeetingReminder: Equatable, Sendable, Identifiable {
    public let id: String
    public let meeting: MeetingReminder
    public let fireDate: Date
}

/// Pure planning logic. Calling it never asks for permissions or schedules a notification.
public enum ReminderPlan {
    public static let identifierPrefix = "whoosh.meeting-reminder."
    public static let defaultLeadTime: TimeInterval = 120

    public static func identifier(for meetingID: String) -> String {
        let digest = SHA256.hash(data: Data(meetingID.utf8))
        return identifierPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Keeps the last snapshot of a duplicate occurrence and skips reminders whose
    /// delivery time has already passed, so repeated refreshes do not repeat alerts.
    public static func make(
        meetings: [MeetingReminder],
        leadTime: TimeInterval = defaultLeadTime,
        now: Date = .now,
        limit: Int = 60
    ) -> [ScheduledMeetingReminder] {
        let lead = leadTime.isFinite ? max(0, leadTime) : defaultLeadTime
        let unique = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        return unique.values.compactMap { meeting -> ScheduledMeetingReminder? in
            guard !meeting.id.isEmpty, meeting.startDate.timeIntervalSince1970.isFinite else { return nil }
            let fireDate = meeting.startDate.addingTimeInterval(-lead)
            guard fireDate > now else { return nil }
            return ScheduledMeetingReminder(id: identifier(for: meeting.id), meeting: meeting, fireDate: fireDate)
        }
        .sorted { lhs, rhs in
            lhs.fireDate == rhs.fireDate ? lhs.meeting.id < rhs.meeting.id : lhs.fireDate < rhs.fireDate
        }
        .prefix(max(0, limit))
        .map { $0 }
    }

    /// Never removes notifications owned by another feature.
    public static func staleIdentifiers(existing: [String], keeping: Set<String>) -> [String] {
        existing.filter { $0.hasPrefix(identifierPrefix) && !keeping.contains($0) }
    }
}
