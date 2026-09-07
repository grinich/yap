import Foundation
import Testing
import UserNotifications
@testable import WhooshSystem

@Suite("Reminder authorization policy")
struct ReminderAuthorizationTests {
    @Test func mapsAvailableMacOSAuthorizationStates() {
        #expect(ReminderAuthorizationStatus(.notDetermined) == .notDetermined)
        #expect(ReminderAuthorizationStatus(.authorized) == .authorized)
        #expect(ReminderAuthorizationStatus(.provisional) == .authorized)
        #expect(ReminderAuthorizationStatus(.denied) == .denied)
    }

    @Test func onlyTheExactNotificationDenialIsConvertedToStatus() {
        #expect(MeetingReminderService.isNotificationsNotAllowed(NSError(domain: UNErrorDomain, code: 1)))
        #expect(!MeetingReminderService.isNotificationsNotAllowed(NSError(domain: NSCocoaErrorDomain, code: 1)))
        #expect(!MeetingReminderService.isNotificationsNotAllowed(NSError(domain: UNErrorDomain, code: 1400)))
        #expect(!MeetingReminderService.isNotificationsNotAllowed(CancellationError()))
    }

    @Test func settingsRouteEscapesTheCurrentBundleAndKeepsPaneFallbacks() {
        let bundle = "com.example.fixture&other=value"
        let urls = MeetingReminderService.notificationSettingsURLs(bundleIdentifier: bundle)
        let components = URLComponents(url: urls[0], resolvingAgainstBaseURL: false)
        #expect(components?.scheme == "x-apple.systempreferences")
        #expect(components?.queryItems == [URLQueryItem(name: "id", value: bundle)])
        #expect(URLComponents(url: urls[1], resolvingAgainstBaseURL: false)?.query == nil)
        #expect(urls.last?.path == "/System/Applications/System Settings.app")
        #expect(MeetingReminderService.notificationSettingsURLs(bundleIdentifier: nil).count == 2)
    }
}
