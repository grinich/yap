import Foundation
import AppKit
import UserNotifications

public enum ReminderAuthorizationStatus: Sendable, Equatable {
    case notDetermined, authorized, denied

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized, .provisional: self = .authorized
        case .denied: self = .denied
        @unknown default: self = .denied
        }
    }
}

public struct ReminderSyncReport: Equatable, Sendable {
    public let scheduledCount: Int
    public let authorizationGranted: Bool
}

/// Retain one instance for the lifetime of the app. Permission is requested only
/// through requestAuthorization(), which belongs behind an explicit user action.
@MainActor
public final class MeetingReminderService: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private var pendingOperation: Task<ReminderSyncReport, Error>?
    private var authorizationOperation: Task<Bool, Error>?
    private var currentMeetings: [String: MeetingReminder] = [:]
    private static let categoryID = "WHOOSH_UPCOMING_MEETING"
    private static let openActionID = "WHOOSH_OPEN_MEETING"

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    public func authorizationStatus() async -> ReminderAuthorizationStatus {
        ReminderAuthorizationStatus(await center.notificationSettings().authorizationStatus)
    }

    public func requestAuthorization() async throws -> Bool {
        try Task.checkCancellation()
        if let authorizationOperation { return try await authorizationOperation.value }
        let operation = Task { @MainActor [self] in
            switch await authorizationStatus() {
            case .denied: return false
            case .authorized: break
            case .notDetermined:
                do {
                    guard try await center.requestAuthorization(options: [.alert, .sound]) else { return false }
                } catch {
                    if Self.isNotificationsNotAllowed(error) { return false }
                    throw error
                }
            }
            await registerCategory()
            return true
        }
        authorizationOperation = operation
        defer { authorizationOperation = nil }
        return try await operation.value
    }

    private func registerCategory() async {
        let action = UNNotificationAction(identifier: Self.openActionID, title: "Open meeting", options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.categoryID, actions: [action], intentIdentifiers: [], options: [])
        var categories = await center.notificationCategories()
        categories = Set(categories.filter { $0.identifier != Self.categoryID })
        categories.insert(category)
        center.setNotificationCategories(categories)
    }

    /// Opens settings only when explicitly invoked by the app's settings button.
    @discardableResult public static func openNotificationSettings() -> Bool {
        for url in notificationSettingsURLs(bundleIdentifier: Bundle.main.bundleIdentifier) {
            if NSWorkspace.shared.open(url) { return true }
        }
        return false
    }

    nonisolated static func notificationSettingsURLs(bundleIdentifier: String?) -> [URL] {
        let pane = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        var urls: [URL] = []
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            var components = URLComponents(url: pane, resolvingAgainstBaseURL: false)!
            // The pane supports this URL scheme; selecting an individual app is
            // best effort and may still require choosing Whoosh in its app list.
            components.queryItems = [URLQueryItem(name: "id", value: bundleIdentifier)]
            if let url = components.url { urls.append(url) }
        }
        urls.append(pane)
        urls.append(URL(filePath: "/System/Applications/System Settings.app"))
        return urls
    }

    nonisolated static func isNotificationsNotAllowed(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == UNErrorDomain && error.code == UNError.Code.notificationsNotAllowed.rawValue
    }

    /// Supply the entire selected-calendar snapshot. Calls serialize so a slower
    /// refresh cannot restore a canceled reminder after a later refresh removes it.
    @discardableResult
    public func synchronize(
        meetings: [MeetingReminder],
        leadTime: TimeInterval = ReminderPlan.defaultLeadTime
    ) async throws -> ReminderSyncReport {
        let previous = pendingOperation
        let operation = Task { @MainActor [self] in
            _ = await previous?.result
            return try await apply(meetings: meetings, leadTime: leadTime)
        }
        pendingOperation = operation
        return try await operation.value
    }

    public func disable() async {
        let previous = pendingOperation
        let operation = Task<ReminderSyncReport, Error> { @MainActor [self] in
            _ = await previous?.result
            currentMeetings = [:]
            await removeStale(keeping: [])
            return ReminderSyncReport(scheduledCount: 0, authorizationGranted: false)
        }
        pendingOperation = operation
        _ = await operation.result
    }

    private func apply(meetings: [MeetingReminder], leadTime: TimeInterval) async throws -> ReminderSyncReport {
        currentMeetings = Dictionary(
            meetings.map { (ReminderPlan.identifier(for: $0.id), $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        guard await authorizationStatus() == .authorized else {
            currentMeetings = [:]
            await removeStale(keeping: [])
            return ReminderSyncReport(scheduledCount: 0, authorizationGranted: false)
        }

        await registerCategory()

        let plan = ReminderPlan.make(meetings: meetings, leadTime: leadTime)
        await removeStale(keeping: Set(plan.map(\.id)))
        var scheduledCount = 0
        for item in plan {
            let delay = item.fireDate.timeIntervalSinceNow
            guard delay > 0 else { continue }
            let content = UNMutableNotificationContent()
            content.title = item.meeting.title.isEmpty ? "Upcoming meeting" : item.meeting.title
            content.body = "Starts at \(item.meeting.startDate.formatted(date: .omitted, time: .shortened)). Open Zooom to join."
            content.sound = .default
            content.categoryIdentifier = Self.categoryID
            content.threadIdentifier = "whoosh.upcoming-meetings"
            // Neither the Zoom invitation URL nor its passcode enters the notification payload.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: trigger))
            } catch {
                guard Self.isNotificationsNotAllowed(error) else { throw error }
                currentMeetings = [:]
                await removeStale(keeping: [])
                return ReminderSyncReport(scheduledCount: 0, authorizationGranted: false)
            }
            scheduledCount += 1
        }
        return ReminderSyncReport(scheduledCount: scheduledCount, authorizationGranted: true)
    }

    private func removeStale(keeping identifiers: Set<String>) async {
        let pending = await center.pendingNotificationRequests()
        let stale = ReminderPlan.staleIdentifiers(existing: pending.map(\.identifier), keeping: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: stale)
        let delivered = await center.deliveredNotifications()
        let staleDelivered = ReminderPlan.staleIdentifiers(
            existing: delivered.map { $0.request.identifier },
            keeping: Set(currentMeetings.keys)
        )
        center.removeDeliveredNotifications(withIdentifiers: staleDelivered)
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard notification.request.identifier.hasPrefix(ReminderPlan.identifierPrefix) else { return [] }
        return [.banner, .sound]
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        guard identifier.hasPrefix(ReminderPlan.identifierPrefix) else { return }
        await routeNotification(identifier: identifier, action: action)
    }

    private func routeNotification(identifier: String, action: String) {
        guard action == UNNotificationDefaultActionIdentifier || action == Self.openActionID else { return }
        if let meeting = currentMeetings[identifier], meeting.startDate > Date.now.addingTimeInterval(-3600) {
            WhooshSystemActions.request(.showMeeting(id: meeting.id))
        } else {
            // Cold-start, deleted, or expired invitations return to the live agenda.
            WhooshSystemActions.request(.showUpcomingMeetings)
        }
    }
}
