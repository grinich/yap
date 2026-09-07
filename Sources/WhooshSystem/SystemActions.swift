import AppIntents
import AppKit
import Foundation

public enum WhooshSystemAction: Equatable, Sendable {
    case openWhoosh
    case showUpcomingMeetings
    case joinNextMeeting
    case showMeeting(id: String)
}

struct PendingSystemActions: Sendable {
    private struct Item: Sendable {
        let action: WhooshSystemAction
        let requestedAt: Date
    }
    private var items: [Item] = []

    mutating func enqueue(_ action: WhooshSystemAction, now: Date = .now) {
        items.append(Item(action: action, requestedAt: now))
    }

    mutating func discardMeetingNavigation() {
        items.removeAll { item in
            switch item.action {
            case .joinNextMeeting, .showMeeting: true
            case .openWhoosh, .showUpcomingMeetings: false
            }
        }
    }

    mutating func take(now: Date = .now) -> WhooshSystemAction? {
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        if item.action == .joinNextMeeting {
            let age = now.timeIntervalSince(item.requestedAt)
            // If startup or a closed window delayed routing, do not join a new,
            // unrelated meeting when the person eventually reopens the app.
            guard (0...60).contains(age) else { return .showUpcomingMeetings }
        }
        return item.action
    }
}

/// The app resolves current calendar and call state before acting, including
/// whether a call is already active. These requests never turn on media devices.
@MainActor
public enum WhooshSystemActions {
    public static let notificationName = Notification.Name("WhooshSystemActionRequested")
    private static var pendingActions = PendingSystemActions()

    public static func request(_ action: WhooshSystemAction) {
        pendingActions.enqueue(action)
        NSApplication.shared.activate()
        NotificationCenter.default.post(name: notificationName, object: nil)
    }

    /// Drain after installing the notification observer as well as on each event;
    /// this preserves an intent delivered while the app is still starting.
    public static func takePendingAction() -> WhooshSystemAction? {
        pendingActions.take()
    }

    /// A newly opened invitation supersedes meeting intents still waiting for
    /// startup. Intents requested after this point remain valid new navigation.
    public static func discardPendingMeetingNavigation() {
        pendingActions.discardMeetingNavigation()
    }
}

public struct OpenWhooshIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Zooom"
    public static let description = IntentDescription("Open your personal meeting space.")
    public static let supportedModes: IntentModes = .foreground
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        WhooshSystemActions.request(.openWhoosh)
        return .result()
    }
}

public struct ShowUpcomingMeetingsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Show Upcoming Meetings"
    public static let description = IntentDescription("See your upcoming meetings in Zooom.")
    public static let supportedModes: IntentModes = .foreground
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        WhooshSystemActions.request(.showUpcomingMeetings)
        return .result()
    }
}

public struct JoinNextMeetingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Join Next Meeting"
    public static let description = IntentDescription("Open Zooom and join your next meeting, with your microphone muted and camera off.")
    public static let supportedModes: IntentModes = .foreground
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        WhooshSystemActions.request(.joinNextMeeting)
        return .result()
    }
}

/// Include this package in the app's AppIntentsPackage declaration and run App
/// Intents metadata extraction when producing the app bundle.
public struct WhooshSystemIntentPackage: AppIntentsPackage {}
