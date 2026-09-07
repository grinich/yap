import Foundation
import Testing
import YapCalendar
import YapMeetings
import YapSystem
@testable import YapAppUI

@Suite("Calendar and application state", .serialized)
@MainActor
struct YapModelTests {
    @Test func reminderIntroductionAndCancelNeverRequestSystemPermission() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.model.beginReminderSetup()
        #expect(fixture.model.showReminderPermission)
        #expect(fixture.model.reminderAuthorizationStatus == .notDetermined)
        #expect(fixture.reminders.authorizationRequestCount == 0)
        #expect(fixture.reminders.scheduled.isEmpty)
        fixture.model.cancelReminderSetup()
        fixture.reminders.status = .authorized
        await fixture.model.refreshReminderAuthorization()
        #expect(!fixture.model.showReminderPermission)
        #expect(!fixture.model.remindersEnabled)
        #expect(!fixture.model.isWaitingForNotificationSettings)
        #expect(fixture.reminders.authorizationRequestCount == 0)
        #expect(fixture.reminders.scheduled.isEmpty)
        #expect(fixture.model.error == nil)
    }

    @Test func deniedPermissionDoesNotRepeatTheSystemRequest() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        fixture.reminders.status = .denied
        await fixture.model.beginReminderSetup()
        await fixture.model.setReminders(true)
        await fixture.model.setReminders(true)
        #expect(fixture.model.showReminderPermission)
        #expect(fixture.model.reminderAuthorizationStatus == .denied)
        #expect(!fixture.model.remindersEnabled)
        #expect(!fixture.model.isChangingReminders)
        #expect(fixture.reminders.authorizationRequestCount == 0)
        #expect(fixture.model.reminderPermissionError == nil)
        #expect(fixture.model.error == nil)
    }

    @Test func approvedSettingsReturnEnablesOnlyTheStillOpenSetup() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        fixture.reminders.status = .denied
        await fixture.model.beginReminderSetup()
        fixture.model.openReminderNotificationSettings()
        #expect(fixture.reminders.openSettingsCount == 1)
        #expect(fixture.model.isWaitingForNotificationSettings)
        await fixture.model.refreshReminderAuthorization()
        #expect(!fixture.model.remindersEnabled)
        #expect(fixture.model.showReminderPermission)
        fixture.reminders.status = .authorized
        await fixture.model.refreshReminderAuthorization()
        #expect(fixture.model.remindersEnabled)
        #expect(!fixture.model.showReminderPermission)
        #expect(!fixture.model.isWaitingForNotificationSettings)
        #expect(fixture.reminders.scheduled.count == 2)
        #expect(fixture.reminders.authorizationRequestCount == 0)
    }

    @Test func cancelWinsOverAnInFlightSettingsAuthorizationRead() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        fixture.reminders.status = .denied
        await fixture.model.beginReminderSetup()
        fixture.model.openReminderNotificationSettings()
        fixture.reminders.pauseStatusRead = true
        let refresh = Task { await fixture.model.refreshReminderAuthorization() }
        await fixture.reminders.waitUntilStatusReadRequested()
        fixture.model.cancelReminderSetup()
        fixture.reminders.finishStatusRead(.authorized)
        await refresh.value
        #expect(!fixture.model.remindersEnabled)
        #expect(!fixture.model.showReminderPermission)
        #expect(!fixture.model.isWaitingForNotificationSettings)
        #expect(fixture.reminders.scheduled.isEmpty)
        #expect(fixture.reminders.authorizationRequestCount == 0)
    }

    @Test func duplicateReminderApprovalsShareOneSystemRequest() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.model.beginReminderSetup()
        fixture.reminders.pauseAuthorization = true
        let first = Task { await fixture.model.setReminders(true) }
        await fixture.reminders.waitUntilAuthorizationRequested()
        #expect(fixture.model.isChangingReminders)
        await fixture.model.setReminders(true)
        #expect(fixture.reminders.authorizationRequestCount == 1)
        fixture.reminders.finishAuthorization(authorized: true)
        await first.value
        #expect(fixture.model.remindersEnabled)
        #expect(!fixture.model.isChangingReminders)
        #expect(!fixture.model.showReminderPermission)
        #expect(fixture.reminders.synchronizeCount == 1)
        #expect(fixture.reminders.scheduled.count == 2)
    }

    @Test func cancellingTheIntroductionWinsOverPendingSystemApproval() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.model.beginReminderSetup()
        fixture.reminders.pauseAuthorization = true
        let enable = Task { await fixture.model.setReminders(true) }
        await fixture.reminders.waitUntilAuthorizationRequested()
        fixture.model.cancelReminderSetup()
        fixture.reminders.finishAuthorization(authorized: true)
        await enable.value
        #expect(!fixture.model.remindersEnabled)
        #expect(!fixture.model.showReminderPermission)
        #expect(!fixture.model.isChangingReminders)
        #expect(fixture.reminders.scheduled.isEmpty)
        #expect(fixture.model.error == nil)
    }

    @Test func authorizationFailureStaysInlineAndPreservesUnrelatedErrors() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        fixture.model.error = "An unrelated calendar error"
        fixture.reminders.authorizationError = URLError(.notConnectedToInternet)
        await fixture.model.beginReminderSetup()
        await fixture.model.setReminders(true)
        #expect(!fixture.model.remindersEnabled)
        #expect(!fixture.model.isChangingReminders)
        #expect(fixture.model.showReminderPermission)
        #expect(fixture.model.reminderPermissionError != nil)
        #expect(fixture.model.error == "An unrelated calendar error")
        #expect(fixture.reminders.scheduled.isEmpty)
    }

    @Test func permissionLostDuringBackgroundSyncDisablesWithoutGlobalAlert() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.model.setReminders(true)
        #expect(fixture.model.remindersEnabled)
        let requests = fixture.reminders.authorizationRequestCount
        fixture.reminders.synchronizeError = YapReminderPermissionError.notificationsNotAllowed
        await fixture.model.synchronizeReminders()
        #expect(!fixture.model.remindersEnabled)
        #expect(fixture.model.reminderAuthorizationStatus == .denied)
        #expect(!fixture.model.showReminderPermission)
        #expect(fixture.model.error == nil)
        #expect(fixture.reminders.authorizationRequestCount == requests)
    }

    @Test func turningOffRemindersWinsOverPendingAuthorization() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        fixture.reminders.pauseAuthorization = true
        let enable = Task { await fixture.model.setReminders(true) }
        await fixture.reminders.waitUntilAuthorizationRequested()
        await fixture.model.setReminders(false)
        fixture.reminders.finishAuthorization(authorized: true)
        await enable.value
        #expect(!fixture.model.remindersEnabled)
        #expect(fixture.reminders.scheduled.isEmpty)
        #expect(fixture.reminders.disableCount == 1)
        #expect(fixture.model.error == nil)
    }

    @Test func deselectingCalendarRemovesItsReminderWhenRefreshFails() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.model.setReminders(true)
        #expect(fixture.reminders.scheduled.count == 2)
        await fixture.calendar.failFollowingRequests()
        await fixture.model.selectCalendar(fixture.calendars[1], selected: false)
        #expect(fixture.reminders.scheduled.map(\.id) == ["event-a"])
        #expect(fixture.model.error != nil)
    }

    @Test func changingSelectionDuringRefreshCannotRestoreDeselectedEventsOrCache() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        #expect(fixture.model.events.count == 2)
        await fixture.calendar.pauseNextRequest()
        let refresh = Task { await fixture.model.refresh() }
        await fixture.calendar.waitUntilPaused()
        let change = Task { await fixture.model.selectCalendar(fixture.calendars[1], selected: false) }
        await fixture.calendar.waitUntilCacheCleared()
        await fixture.calendar.failFollowingRequests()
        await fixture.calendar.releasePausedRequest()
        _ = await refresh.value
        await change.value
        #expect(fixture.model.selectedCalendarIDs == ["a"])
        #expect(fixture.model.events.map(\.calendarID) == ["a"])
        #expect(await fixture.calendar.cachedSnapshot() == nil)
        #expect(fixture.model.error != nil)
    }

    @Test func disconnectInvalidatesAnInFlightRefresh() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.calendar.pauseNextRequest()
        let refresh = Task { await fixture.model.refresh() }
        await fixture.calendar.waitUntilPaused()
        await fixture.model.disconnectGoogle()
        await fixture.calendar.releasePausedRequest()
        _ = await refresh.value
        #expect(!fixture.model.isCalendarConnected)
        #expect(!fixture.model.isRefreshing)
        #expect(fixture.model.events.isEmpty)
        #expect(fixture.model.calendars.isEmpty)
        #expect(fixture.model.selectedCalendarIDs.isEmpty)
        #expect(fixture.reminders.disableCount == 1)
    }

    @Test func importDisconnectsStoredCredentialsEvenBeforeConnectionStatusLoads() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        #expect(!fixture.model.isCalendarConnected)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("YapModelConfig-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: path) }
        let data = Data(#"{"installed":{"client_id":"replacement.apps.googleusercontent.com"}}"#.utf8)
        try data.write(to: path)
        await fixture.model.importGoogleConfiguration(from: path)
        #expect(await fixture.calendar.disconnectCount == 1)
        #expect(fixture.configuration.saved == data)
        #expect(fixture.configuration.createdClientID == "replacement.apps.googleusercontent.com")
        #expect(fixture.model.events.isEmpty)
        #expect(!fixture.model.isCalendarConnected)
    }

    @Test func failedCredentialDeletionStopsConfigurationReplacement() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.calendar.failDisconnect()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("YapModelConfig-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: path) }
        try Data(#"{"installed":{"client_id":"replacement.apps.googleusercontent.com"}}"#.utf8).write(to: path)
        await fixture.model.importGoogleConfiguration(from: path)
        #expect(fixture.configuration.saved == nil)
        #expect(fixture.configuration.createdClientID == nil)
        #expect(fixture.model.error != nil)
    }

    @Test func showAllPickerTracksTheCurrentCoordinatorAcrossPreview() async {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        #expect(fixture.model.gridLimit == 100)
        fixture.model.updateGridLimit(0)
        #expect(fixture.model.gridLimit == 0)
        #expect(fixture.liveMeeting.showsAllParticipants)
        fixture.model.enterPreview()
        #expect(fixture.model.gridLimit == 100)
        fixture.model.updateGridLimit(0)
        #expect(fixture.model.meeting.showsAllParticipants)
        fixture.model.updateGridLimit(49)
        #expect(fixture.model.gridLimit == 49)
        #expect(!fixture.model.meeting.showsAllParticipants)
        await fixture.model.exitPreview()
        #expect(fixture.model.meeting === fixture.liveMeeting)
        #expect(fixture.model.gridLimit == 0)
        fixture.model.updateGridLimit(25)
        #expect(fixture.model.gridLimit == 25)
        #expect(!fixture.liveMeeting.showsAllParticipants)
    }

    @Test func leavingLaunchPreviewLoadsCalendarAndPreservesLiveMeetingDriver() async throws {
        let fixture = ModelFixture(preview: true)
        defer { fixture.cleanUp() }
        await fixture.model.start()
        #expect(fixture.model.isPreview)
        #expect(fixture.model.events.allSatisfy { $0.calendarID == "preview" })
        #expect(await fixture.calendar.calendarListCalls == 0)
        await fixture.model.exitPreview()
        #expect(!fixture.model.isPreview)
        #expect(fixture.model.isCalendarConnected)
        #expect(fixture.model.meeting === fixture.liveMeeting)
        #expect(fixture.model.events.map(\.calendarID) == ["a", "b"])
        #expect(await fixture.calendar.calendarListCalls == 1)
    }

    @Test func previewDoesNotAcceptLateLiveRefreshOrModifyCalendarSelection() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.calendar.pauseNextRequest()
        let refresh = Task { await fixture.model.refresh() }
        await fixture.calendar.waitUntilPaused()
        fixture.model.enterPreview()
        await fixture.model.selectCalendar(fixture.calendars[0], selected: false)
        await fixture.calendar.releasePausedRequest()
        _ = await refresh.value
        #expect(fixture.model.events.allSatisfy { $0.calendarID == "preview" })
        #expect(fixture.model.selectedCalendarIDs == ["a", "b"])
        await fixture.model.exitPreview()
        #expect(fixture.model.events.allSatisfy { $0.calendarID != "preview" })
        #expect(fixture.model.meeting === fixture.liveMeeting)
    }

    @Test func failedNotificationRefreshDoesNotOfferStaleInvitation() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        let event = try #require(fixture.model.events.first)
        await fixture.calendar.failFollowingRequests()
        await fixture.model.handleSystemAction(.showMeeting(id: event.id))
        #expect(!fixture.model.showJoinSheet)
        #expect(fixture.model.selectedEvent == nil)
        #expect(fixture.model.joinLink.isEmpty)
        #expect(fixture.liveMeeting.status == .idle)
    }

    @Test func explicitJoinNextRequiresSuccessfulRefresh() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.calendar.failFollowingRequests()
        await fixture.model.handleSystemAction(.joinNextMeeting)
        #expect(fixture.liveMeeting.status == .idle)
        #expect(fixture.model.error != nil)
        await fixture.calendar.allowRequests()
        await fixture.model.handleSystemAction(.joinNextMeeting)
        #expect(fixture.liveMeeting.status == .inMeeting)
        await fixture.model.leaveMeeting()
    }

    @Test func freshNotificationOffersDetailsWithoutStartingMedia() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        let event = try #require(fixture.model.events.first)
        await fixture.model.handleSystemAction(.showMeeting(id: event.id))
        #expect(fixture.model.showJoinSheet)
        #expect(fixture.model.selectedEvent?.id == event.id)
        #expect(fixture.liveMeeting.status == .idle)
    }

    @Test func emptySelectionRemainsEmptyAfterRestart() async throws {
        let fixture = ModelFixture()
        defer { fixture.cleanUp() }
        fixture.preferences.set([], forKey: "selectedCalendarIDs")
        let model = fixture.makeModel()
        await model.start()
        #expect(model.selectedCalendarIDs.isEmpty)
        #expect(model.events.isEmpty)
    }
}

@MainActor
private final class ModelFixture {
    let preferences: UserDefaults
    let suite = "YapModelTests.\(UUID())"
    let calendars = [GoogleCalendar(id: "a", name: "A", isPrimary: true), GoogleCalendar(id: "b", name: "B")]
    let calendar: ModelCalendar
    let reminders = ModelReminders()
    let configuration = ConfigurationProbe()
    let liveMeeting = MeetingCoordinator(driver: DemoMeetingDriver(participantCount: 3))
    var model: YapModel!

    init(preview: Bool = false) {
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(["a", "b"], forKey: "selectedCalendarIDs")
        let now = Date()
        let events = calendars.enumerated().map { index, calendar in
            CalendarEvent(id: "event-\(calendar.id)", title: calendar.name,
                          startDate: now.addingTimeInterval(Double(index + 1) * 300), endDate: now.addingTimeInterval(3_600),
                          calendarID: calendar.id, calendarName: calendar.name,
                          meetingURLs: [URL(string: "https://zoom.us/j/12345678901")!])
        }
        calendar = ModelCalendar(calendars: calendars, events: events)
        model = makeModel(preview: preview)
    }

    func makeModel(preview: Bool = false) -> YapModel {
        let calendar = self.calendar
        let configuration = self.configuration
        return YapModel(preview: preview, preferences: preferences, meeting: liveMeeting, calendarClient: calendar,
                           reminders: reminders.actions,
                           saveGoogleConfiguration: { configuration.saved = $0 },
                           makeConfiguredCalendarClient: { config in configuration.createdClientID = config.clientID; return calendar })
    }

    func cleanUp() { preferences.removePersistentDomain(forName: suite) }
}

@MainActor
private final class ConfigurationProbe {
    var saved: Data?
    var createdClientID: String?
}

@MainActor
private final class ModelReminders {
    var disableCount = 0
    var authorizationRequestCount = 0
    var statusReadCount = 0
    var synchronizeCount = 0
    var openSettingsCount = 0
    var scheduled: [MeetingReminder] = []
    var status: ReminderAuthorizationStatus = .notDetermined
    var authorizationResult = true
    var authorizationError: (any Error)?
    var synchronizeError: (any Error)?
    var openSettingsResult = true
    var pauseAuthorization = false
    var pauseStatusRead = false
    var authorizationContinuation: CheckedContinuation<Bool, Never>?
    var authorizationWaiter: CheckedContinuation<Void, Never>?
    var statusContinuation: CheckedContinuation<ReminderAuthorizationStatus, Never>?
    var statusWaiter: CheckedContinuation<Void, Never>?

    func requestAuthorization() async throws -> Bool {
        authorizationRequestCount += 1
        if let authorizationError { throw authorizationError }
        let authorized: Bool
        if pauseAuthorization {
            authorized = await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
                authorizationWaiter?.resume(); authorizationWaiter = nil
            }
        } else {
            authorized = authorizationResult
        }
        status = authorized ? .authorized : .denied
        return authorized
    }

    func waitUntilAuthorizationRequested() async {
        if authorizationContinuation != nil { return }
        await withCheckedContinuation { authorizationWaiter = $0 }
    }

    func finishAuthorization(authorized: Bool) {
        authorizationContinuation?.resume(returning: authorized)
        authorizationContinuation = nil
    }

    func readStatus() async -> ReminderAuthorizationStatus {
        statusReadCount += 1
        guard pauseStatusRead else { return status }
        return await withCheckedContinuation { continuation in
            statusContinuation = continuation
            statusWaiter?.resume(); statusWaiter = nil
        }
    }

    func waitUntilStatusReadRequested() async {
        if statusContinuation != nil { return }
        await withCheckedContinuation { statusWaiter = $0 }
    }

    func finishStatusRead(_ status: ReminderAuthorizationStatus) {
        self.status = status
        statusContinuation?.resume(returning: status)
        statusContinuation = nil
    }

    var actions: YapReminderActions {
        YapReminderActions(requestAuthorization: { [self] in try await requestAuthorization() },
                              synchronize: { [self] items, _ in
                                  synchronizeCount += 1
                                  if let synchronizeError { throw synchronizeError }
                                  scheduled = items
                              },
                              disable: { [self] in disableCount += 1; scheduled = [] },
                              authorizationStatus: { [self] in await readStatus() },
                              openSettings: { [self] in openSettingsCount += 1; return openSettingsResult })
    }
}

private actor ModelCalendar: YapCalendarServing {
    nonisolated let isConfigured = true
    let listed: [GoogleCalendar]
    let allEvents: [CalendarEvent]
    var connected = true
    var disconnectCount = 0
    var calendarListCalls = 0
    var snapshot: CalendarSnapshot?
    var pauseNext = false
    var paused = false
    var failRequests = false
    var disconnectFails = false
    var pausedRequest: CheckedContinuation<Void, Never>?
    var pauseWaiter: CheckedContinuation<Void, Never>?
    var cacheWaiter: CheckedContinuation<Void, Never>?
    var wasCleared = false
    var generation = UUID()

    init(calendars: [GoogleCalendar], events: [CalendarEvent]) { listed = calendars; allEvents = events }
    func hasCredentials() -> Bool { connected }
    func calendars() -> [GoogleCalendar] { calendarListCalls += 1; return listed }
    func cachedSnapshot() -> CalendarSnapshot? { snapshot }
    func clearCachedEvents() {
        snapshot = nil
        wasCleared = true
        cacheWaiter?.resume(); cacheWaiter = nil
    }
    func connect(openURL: @escaping @MainActor @Sendable (URL) -> Void) -> [GoogleCalendar] { connected = true; return listed }
    func disconnect() throws {
        disconnectCount += 1
        if disconnectFails { throw GoogleCalendarError.keychain(-1) }
        generation = UUID(); connected = false; snapshot = nil
    }
    func failDisconnect() { disconnectFails = true }
    func pauseNextRequest() { pauseNext = true; wasCleared = false }
    func failFollowingRequests() { failRequests = true }
    func allowRequests() { failRequests = false }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }
    func waitUntilCacheCleared() async {
        if wasCleared { return }
        await withCheckedContinuation { cacheWaiter = $0 }
    }
    func releasePausedRequest() { pausedRequest?.resume(); pausedRequest = nil; paused = false }

    func events(in calendars: [GoogleCalendar], from: Date, to: Date) async throws -> [CalendarEvent] {
        let originalGeneration = generation
        if failRequests { throw GoogleCalendarError.httpStatus(503) }
        let selected = allEvents.filter { event in calendars.contains { $0.id == event.calendarID } }
        if pauseNext {
            pauseNext = false; paused = true
            pauseWaiter?.resume(); pauseWaiter = nil
            await withCheckedContinuation { pausedRequest = $0 }
        }
        if generation == originalGeneration {
            snapshot = CalendarSnapshot(events: selected, fetchedAt: .now, calendarIDs: calendars.map(\.id), windowStart: from, windowEnd: to)
        }
        return selected
    }
}
