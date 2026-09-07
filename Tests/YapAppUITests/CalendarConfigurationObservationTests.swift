import Foundation
import Observation
import Synchronization
import Testing
import YapCalendar
import YapMeetings
@testable import YapAppUI

@Suite("Calendar configuration observation")
@MainActor
struct CalendarConfigurationObservationTests {
    @Test func firstImportNotifiesTheSettingsSignInControl() async throws {
        let suite = "YapCalendarConfigurationObservation.\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("YapGoogleImport-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: path) }
        try Data(#"{"installed":{"client_id":"personal.apps.googleusercontent.com"}}"#.utf8).write(to: path)

        let model = YapModel(
            preview: false, preferences: preferences,
            meeting: MeetingCoordinator(driver: DemoMeetingDriver()),
            calendarClient: ImportCalendarService(isConfigured: false),
            reminders: YapReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}),
            saveGoogleConfiguration: { _ in },
            makeConfiguredCalendarClient: { _ in ImportCalendarService(isConfigured: true) }
        )
        let didChange = Mutex(false)
        withObservationTracking {
            #expect(!model.googleConfigured)
        } onChange: {
            didChange.withLock { $0 = true }
        }

        await model.importGoogleConfiguration(from: path)

        #expect(model.googleConfigured)
        #expect(didChange.withLock { $0 })
        #expect(!model.isCalendarConnected)
        #expect(model.error == nil)
    }
}

private struct ImportCalendarService: YapCalendarServing {
    let isConfigured: Bool
    func hasCredentials() async -> Bool { false }
    func cachedSnapshot() async -> CalendarSnapshot? { nil }
    func clearCachedEvents() async {}
    func disconnect() async {}
    func calendars() async throws -> [GoogleCalendar] { [] }
    func connect(openURL: @escaping @MainActor @Sendable (URL) -> Void) async throws -> [GoogleCalendar] { [] }
    func events(in calendars: [GoogleCalendar], from: Date, to: Date) async throws -> [CalendarEvent] { [] }
}
