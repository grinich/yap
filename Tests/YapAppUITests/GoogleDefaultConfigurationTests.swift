import Foundation
import Testing
import YapCalendar
import YapMeetings
@testable import YapAppUI

@Suite("Yap always includes its Google client")
struct GoogleDefaultConfigurationTests {
    @Test func sourceAndPackagedBuildsUseTheSameSharedGoogleApp() throws {
        let configuration = try GoogleOAuthConfiguration.yap()
        #expect(configuration.isValid)
        #expect(configuration.clientID == "696553061357-u7j8v96hlg5qms17kc9rea8cjtb8ksoh.apps.googleusercontent.com")
        #expect(configuration.clientSecret?.isEmpty == false)
    }

    @Test @MainActor func freshInstallationIsConfiguredWithoutDeveloperSetup() async throws {
        let suite = "YapBundledGoogleTests.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = YapModel(preview: false, preferences: preferences,
            meeting: MeetingCoordinator(driver: DemoMeetingDriver()),
            reminders: YapReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}),
            makeConfiguredCalendarClient: { _ in NoAccountCalendar() })
        await model.loadGoogleConnection()
        #expect(model.googleConfigured)
        #expect(!model.isCalendarConnected)
        #expect(model.error == nil)
    }
}

private struct NoAccountCalendar: YapCalendarServing {
    let isConfigured = true
    func hasCredentials() async -> Bool { false }
    func cachedSnapshot() async -> CalendarSnapshot? { nil }
    func clearCachedEvents() async {}
    func disconnect() async {}
    func calendars() async throws -> [GoogleCalendar] { [] }
    func connect(openURL: @escaping @MainActor @Sendable (URL) -> Void) async throws -> [GoogleCalendar] { [] }
    func events(in calendars: [GoogleCalendar], from: Date, to: Date) async throws -> [CalendarEvent] { [] }
}
