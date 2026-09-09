import AppKit
import Foundation
import Observation
import YapCredentials
import YapCalendar
import YapMeetings
import YapSystem

public protocol YapCalendarServing: Sendable {
    var isConfigured: Bool { get }
    func hasCredentials() async throws -> Bool
    func calendars() async throws -> [GoogleCalendar]
    func cachedSnapshot() async throws -> CalendarSnapshot?
    func clearCachedEvents() async throws
    func events(in calendars: [GoogleCalendar], from: Date, to: Date) async throws -> [CalendarEvent]
    func connect(openURL: @escaping @MainActor @Sendable (URL) -> Void) async throws -> [GoogleCalendar]
    func disconnect() async throws
}

extension GoogleCalendarClient: YapCalendarServing {}

public enum GoogleConfigurationLoadState: Sendable, Equatable {
    case pending, loading, loaded, cancelled, failed
}

@MainActor
public struct YapReminderActions {
    public var requestAuthorization: () async throws -> Bool
    public var synchronize: ([MeetingReminder], TimeInterval) async throws -> Void
    public var disable: () async -> Void
    public var authorizationStatus: () async -> ReminderAuthorizationStatus
    public var openSettings: () -> Bool

    public init(requestAuthorization: @escaping () async throws -> Bool,
                synchronize: @escaping ([MeetingReminder], TimeInterval) async throws -> Void,
                disable: @escaping () async -> Void,
                authorizationStatus: @escaping () async -> ReminderAuthorizationStatus = { .notDetermined },
                openSettings: @escaping () -> Bool = { false }) {
        self.requestAuthorization = requestAuthorization
        self.synchronize = synchronize
        self.disable = disable
        self.authorizationStatus = authorizationStatus
        self.openSettings = openSettings
    }

    public static var live: Self {
        let service = MeetingReminderService()
        return Self(requestAuthorization: { try await service.requestAuthorization() },
                    synchronize: { items, lead in
                        let report = try await service.synchronize(meetings: items, leadTime: lead)
                        if !report.authorizationGranted { throw YapReminderPermissionError.notificationsNotAllowed }
                    },
                    disable: { await service.disable() },
                    authorizationStatus: { await service.authorizationStatus() },
                    openSettings: { MeetingReminderService.openNotificationSettings() })
    }
}

enum YapReminderPermissionError: Error { case notificationsNotAllowed }

@MainActor @Observable
public final class YapModel {
    public var meeting: MeetingCoordinator
    public let meetingPresentation = YapMeetingPresentation()
    public let zoomConnection: ZoomConnectionModel
    public let recordings: RecordingLibraryModel
    public private(set) var events: [CalendarEvent] = []
    public private(set) var calendars: [GoogleCalendar] = []
    public var selectedCalendarIDs: Set<String> = []
    public private(set) var isCalendarConnected = false
    public private(set) var isRefreshing = false
    public private(set) var isConnecting = false
    public private(set) var googleConfigurationLoadState: GoogleConfigurationLoadState
    public private(set) var lastRefreshed: Date?
    public private(set) var isPreview = false
    public var displayName: String { didSet { preferences.set(displayName, forKey: "displayName"); joinInputError = nil } }
    public var remindersEnabled: Bool { didSet { preferences.set(remindersEnabled, forKey: "remindersEnabled") } }
    public var reminderMinutes: Int { didSet { preferences.set(reminderMinutes, forKey: "reminderMinutes") } }
    public var askBeforeLeavingMeeting: Bool { didSet { preferences.set(askBeforeLeavingMeeting, forKey: "askBeforeLeavingMeeting") } }
    public private(set) var showReminderPermission = false
    public private(set) var reminderAuthorizationStatus: ReminderAuthorizationStatus = .notDetermined
    public private(set) var isChangingReminders = false
    public private(set) var isWaitingForNotificationSettings = false
    public private(set) var reminderPermissionError: String?
    public var showSettings = false
    public var showJoinSheet = false { didSet { joinInputError = nil } }
    public var joinLink = "" { didSet { joinInputError = nil } }
    public private(set) var joinInputError: String?
    public var unsupportedZoomLink: URL?
    public var error: String?
    public var selectedEvent: CalendarEvent?
    public var sidebar: MeetingSidebar?
    public var focusedParticipantID: String? {
        get { meeting.pinnedParticipantID }
        set { meeting.setPinnedParticipant(newValue) }
    }
    /// Zero is the picker’s “Show all” selection, not a zero-sized page.
    public var gridLimit: Int { meeting.showsAllParticipants ? 0 : meeting.pageSize }
    public var previewPeople = 6
    public var showLeaveConfirmation = false
    public var areMeetingControlsVisible = true

    private var calendarClient: any YapCalendarServing
    @ObservationIgnored private let reminders: YapReminderActions
    @ObservationIgnored private let saveGoogleConfiguration: (Data) throws -> Void
    @ObservationIgnored private let loadGoogleConfiguration: @Sendable () throws -> GoogleOAuthConfiguration?
    @ObservationIgnored private let makeConfiguredCalendarClient: (GoogleOAuthConfiguration) -> any YapCalendarServing
    @ObservationIgnored private var configurationLoad: Task<Void, Never>?
    @ObservationIgnored private var configurationLoadID: UUID?
    @ObservationIgnored private var configurationWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var liveMeeting: MeetingCoordinator
    @ObservationIgnored private var liveCalendarEvents: [CalendarEvent] = []
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var activeRefresh: Task<Bool, Never>?
    @ObservationIgnored private var activeRefreshID: UUID?
    @ObservationIgnored private var pendingCalendarJoinID: UUID?
    @ObservationIgnored private var meetingLinkRevision = UUID()
    @ObservationIgnored private var activeRefreshPresentsErrors = false
    @ObservationIgnored private var liveCalendarLoadCount = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var selectionRevision = UUID()
    @ObservationIgnored private var reminderRevision = UUID()
    @ObservationIgnored private var started = false

    public init(preview: Bool = ProcessInfo.processInfo.arguments.contains("--preview"),
                preferences: UserDefaults = .standard,
                meeting: MeetingCoordinator? = nil,
                zoomConnection: ZoomConnectionModel? = nil,
                calendarClient: (any YapCalendarServing)? = nil,
                reminders: YapReminderActions? = nil,
                saveGoogleConfiguration: ((Data) throws -> Void)? = nil,
                loadGoogleConfiguration: (@Sendable () throws -> GoogleOAuthConfiguration?)? = nil,
                makeConfiguredCalendarClient: ((GoogleOAuthConfiguration) -> any YapCalendarServing)? = nil) {
        self.preferences = preferences
        self.displayName = preferences.string(forKey: "displayName") ?? NSFullUserName().components(separatedBy: " ").first ?? "Me"
        self.remindersEnabled = preferences.bool(forKey: "remindersEnabled")
        self.askBeforeLeavingMeeting = preferences.bool(forKey: "askBeforeLeavingMeeting")
        self.reminderMinutes = max(1, preferences.integer(forKey: "reminderMinutes") == 0 ? 2 : preferences.integer(forKey: "reminderMinutes"))
        let zoomConnection = zoomConnection ?? ZoomConnectionModel()
        self.zoomConnection = zoomConnection
        let recordings = RecordingLibraryModel(client: zoomConnection.client)
        self.recordings = recordings
        zoomConnection.onAccountWillChange = { [weak recordings] in recordings?.clear() }
        let liveMeeting = meeting ?? MeetingCoordinator(driver: makeZoomMeetingDriver(accountClient: zoomConnection.client))
        self.meeting = liveMeeting
        self.liveMeeting = liveMeeting
        self.calendarClient = calendarClient ?? Self.makeCalendarClient()
        self.googleConfigurationLoadState = calendarClient == nil || loadGoogleConfiguration != nil ? .pending : .loaded
        self.reminders = reminders ?? .live
        self.saveGoogleConfiguration = saveGoogleConfiguration ?? YapConfigurationStore.saveGoogle
        self.loadGoogleConfiguration = loadGoogleConfiguration ?? YapConfigurationStore.loadGoogle
        self.makeConfiguredCalendarClient = makeConfiguredCalendarClient ?? { Self.makeCalendarClient(configuration: $0) }
        self.selectedCalendarIDs = Set(preferences.stringArray(forKey: "selectedCalendarIDs") ?? [])
        recordings.zoomSignInRecovery = ZoomSignInRecovery(model: self)
        if preview {
            enterPreview()
            if ProcessInfo.processInfo.arguments.contains("--recordings-preview") { recordings.isPresented = true }
        }
    }

    public var googleConfigured: Bool { calendarClient.isConfigured }
    public var upcomingEvents: [CalendarEvent] { AgendaRules.upcoming(events, now: .now) }
    public var nextMeeting: CalendarEvent? { upcomingEvents.first }
    public var activeCall: Bool { meeting.status.isActive }

    deinit { refreshLoop?.cancel(); activeRefresh?.cancel(); configurationLoad?.cancel() }

    public func start() async {
        guard !started else { return }
        started = true
        if !isPreview { await loadLiveCalendar() }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                await self?.refresh()
            }
        }
    }

    private static func makeCalendarClient(configuration: GoogleOAuthConfiguration? = nil) -> GoogleCalendarClient {
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .flatMap { YapCalendarCache.url(in: $0, bundleIdentifier: Bundle.main.bundleIdentifier, bundleURL: Bundle.main.bundleURL) }
        return GoogleCalendarClient(configuration: configuration, cacheURL: cache)
    }

    private func bootstrapGoogleConfiguration() async -> Bool {
        switch googleConfigurationLoadState {
        case .loaded: return true
        case .cancelled, .failed: return false
        case .pending, .loading: break
        }
        return await withCheckedContinuation { waiter in
            configurationWaiters.append(waiter)
            guard configurationLoad == nil else { return }
            let operationID = UUID()
            let loader = loadGoogleConfiguration
            configurationLoadID = operationID
            googleConfigurationLoadState = .loading
            // SecItemCopyMatching can wait for a legitimate macOS approval dialog.
            // Keep that synchronous call off MainActor so the first window can draw.
            configurationLoad = Task.detached(priority: .userInitiated) { [weak self] in
                let result = Result {
                    try Task.checkCancellation()
                    return try loader()
                }
                await self?.finishGoogleConfigurationLoad(result, operationID: operationID)
            }
        }
    }

    private func finishGoogleConfigurationLoad(_ result: Result<GoogleOAuthConfiguration?, Error>, operationID: UUID) {
        guard configurationLoadID == operationID else { return }
        configurationLoad = nil; configurationLoadID = nil
        switch result {
        case .success(let configuration):
            if let configuration { calendarClient = makeConfiguredCalendarClient(configuration) }
            googleConfigurationLoadState = .loaded
            resumeConfigurationWaiters(loaded: true)
        case .failure(let error):
            googleConfigurationLoadState = .failed
            self.error = error.localizedDescription
            resumeConfigurationWaiters(loaded: false)
        }
    }

    private func resumeConfigurationWaiters(loaded: Bool) {
        let waiters = configurationWaiters
        configurationWaiters = []
        for waiter in waiters { waiter.resume(returning: loaded) }
    }

    public func loadGoogleConnection() async {
        if googleConfigurationLoadState == .failed || googleConfigurationLoadState == .cancelled {
            googleConfigurationLoadState = .pending
            error = nil
        }
        if isPreview { _ = await bootstrapGoogleConfiguration() }
        else { await loadLiveCalendar() }
    }

    public func cancelGoogleConfigurationLoad() {
        guard googleConfigurationLoadState == .pending || googleConfigurationLoadState == .loading else { return }
        // Cancelling ignores the eventual result; it cannot dismiss a system-owned prompt.
        configurationLoad?.cancel()
        configurationLoad = nil; configurationLoadID = nil
        googleConfigurationLoadState = .cancelled
        invalidateCalendarOperations()
        resumeConfigurationWaiters(loaded: false)
    }

    private func loadLiveCalendar() async {
        liveCalendarLoadCount += 1
        defer { liveCalendarLoadCount -= 1 }
        let current = generation
        guard await bootstrapGoogleConfiguration(), current == generation, !isPreview else { return }
        let client = calendarClient
        do {
            let connected = try await client.hasCredentials()
            guard current == generation, !isPreview else { return }
            isCalendarConnected = connected
            guard connected else { events = []; calendars = []; lastRefreshed = nil; return }
            if let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                _ = try? YapCalendarCache.prepareForLiveApp(in: applicationSupport,
                    bundleIdentifier: Bundle.main.bundleIdentifier, bundleURL: Bundle.main.bundleURL,
                    isPreview: isPreview, hasCredentials: connected)
            }
            if let snapshot = try await client.cachedSnapshot() {
                guard current == generation, !isPreview else { return }
                events = snapshot.events.filter { selectedCalendarIDs.contains($0.calendarID) }
                lastRefreshed = snapshot.fetchedAt
            }
            let listed = try await client.calendars()
            guard current == generation, !isPreview else { return }
            calendars = listed
            if preferences.object(forKey: "selectedCalendarIDs") == nil { selectInitialCalendars() }
            await refresh(reloadCalendars: false)
        } catch {
            guard current == generation, !isPreview else { return }
            self.error = error.localizedDescription
            let selection = selectionRevision
            switch error as? GoogleCalendarError {
            case .signInExpired, .notConnected:
                events = []; liveCalendarEvents = []; calendars = []; lastRefreshed = nil
                isCalendarConnected = false
                clearCalendarJoinDraft()
                await reminders.disable()
                guard current == generation, selection == selectionRevision, !isPreview else { return }
            case .httpStatus(403), .httpStatus(404):
                let snapshot = try? await client.cachedSnapshot()
                guard current == generation, selection == selectionRevision, !isPreview else { return }
                events = snapshot?.events.filter { selectedCalendarIDs.contains($0.calendarID) } ?? []
                lastRefreshed = snapshot?.fetchedAt
                clearCalendarJoinDraft()
                await synchronizeReminders()
                guard current == generation, selection == selectionRevision, !isPreview else { return }
            default: break
            }
        }
    }

    private func clearCalendarJoinDraft() {
        // Calendar failures cannot invalidate a pasted or incoming meeting link.
        guard selectedEvent != nil else { return }
        selectedEvent = nil; joinLink = ""; showJoinSheet = false
    }

    public func connectGoogle() async {
        guard !isConnecting else { return }
        guard googleConfigured else { showSettings = true; return }
        if isPreview {
            guard !activeCall else { error = "Leave the preview meeting before connecting Google Calendar."; return }
            await exitPreview()
        }
        isConnecting = true
        let current = generation
        defer { if current == generation { isConnecting = false } }
        do {
            let result = try await calendarClient.connect { url in NSWorkspace.shared.open(url) }
            guard generation == current else { return }
            calendars = result
            isCalendarConnected = true
            YapSystemActions.request(.openYap)
            selectInitialCalendars()
            await refresh(reloadCalendars: false)
        } catch { if generation == current { self.error = error.localizedDescription } }
    }

    @discardableResult
    public func refresh() async -> Bool {
        await refresh(reloadCalendars: true)
    }

    /// Refresh an existing connection on activation without restarting account setup.
    @discardableResult
    public func refreshOnForeground() async -> Bool {
        guard !Task.isCancelled, googleConfigurationLoadState == .loaded,
              liveCalendarLoadCount == 0, isCalendarConnected, !isPreview,
              !isConnecting, !activeCall else { return false }
        return await refresh(reloadCalendars: true, presentsErrors: false)
    }

    @discardableResult
    private func refresh(reloadCalendars: Bool, presentsErrors: Bool = true) async -> Bool {
        guard isCalendarConnected, !isPreview else { return false }
        if let activeRefresh {
            // An explicit refresh that joins an automatic one still owns visible feedback.
            activeRefreshPresentsErrors = activeRefreshPresentsErrors || presentsErrors
            return await activeRefresh.value
        }
        let current = generation
        let selection = selectionRevision
        let operationID = UUID()
        let client = calendarClient
        let selected = calendars.filter { selectedCalendarIDs.contains($0.id) }
        isRefreshing = true
        activeRefreshID = operationID
        activeRefreshPresentsErrors = presentsErrors
        let operation = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer {
                if self.activeRefreshID == operationID {
                    self.isRefreshing = false
                    self.activeRefresh = nil
                    self.activeRefreshID = nil
                    self.activeRefreshPresentsErrors = false
                }
            }
            return await self.performRefresh(client: client, selected: selected, generation: current, selection: selection, reloadCalendars: reloadCalendars)
        }
        activeRefresh = operation
        return await operation.value
    }

    private func performRefresh(client: any YapCalendarServing, selected: [GoogleCalendar], generation current: UUID, selection: UUID, reloadCalendars: Bool) async -> Bool {
        let now = Date()
        do {
            var requestedCalendars = selected
            if reloadCalendars {
                let available = try await client.calendars()
                guard generation == current, selectionRevision == selection, !isPreview else { return false }
                calendars = available
                let availableIDs = Set(available.map(\.id))
                let retainedSelection = selectedCalendarIDs.intersection(availableIDs)
                if retainedSelection != selectedCalendarIDs {
                    selectedCalendarIDs = retainedSelection
                    preferences.set(Array(retainedSelection), forKey: "selectedCalendarIDs")
                    events.removeAll { !retainedSelection.contains($0.calendarID) }
                    if let selectedEvent, !retainedSelection.contains(selectedEvent.calendarID) {
                        self.selectedEvent = nil; joinLink = ""; showJoinSheet = false
                    }
                    await synchronizeReminders()
                    guard generation == current, selectionRevision == selection, !isPreview else { return false }
                }
                // New calendars appear in Settings without being silently selected.
                requestedCalendars = available.filter { retainedSelection.contains($0.id) }
            }
            let updated = try await client.events(in: requestedCalendars, from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(14 * 86_400))
            guard generation == current, !isPreview else { return false }
            guard selectionRevision == selection else {
                try await client.clearCachedEvents()
                return false
            }
            events = updated.filter { selectedCalendarIDs.contains($0.calendarID) }
            lastRefreshed = .now
            await synchronizeReminders()
            return generation == current && selectionRevision == selection && !isPreview
        } catch {
            guard generation == current, selectionRevision == selection, !isPreview else { return false }
            if activeRefreshPresentsErrors { self.error = error.localizedDescription }
            switch error as? GoogleCalendarError {
            case .signInExpired, .notConnected:
                events = []; liveCalendarEvents = []; calendars = []; lastRefreshed = nil
                isCalendarConnected = false
                clearCalendarJoinDraft()
                await reminders.disable()
                guard generation == current, selectionRevision == selection, !isPreview else { return false }
            case .httpStatus(403), .httpStatus(404):
                let snapshot = try? await client.cachedSnapshot()
                guard generation == current, selectionRevision == selection, !isPreview else { return false }
                events = snapshot?.events.filter { selectedCalendarIDs.contains($0.calendarID) } ?? []
                lastRefreshed = snapshot?.fetchedAt
                if let selectedEvent, !events.contains(where: { $0.id == selectedEvent.id }) {
                    self.selectedEvent = nil; joinLink = ""; showJoinSheet = false
                }
                await synchronizeReminders()
                guard generation == current, selectionRevision == selection, !isPreview else { return false }
            default: break
            }
            return false
        }
    }

    public func selectCalendar(_ calendar: GoogleCalendar, selected: Bool) async {
        guard !isPreview else { return }
        let current = generation
        selectionRevision = UUID()
        let revision = selectionRevision
        if selected { selectedCalendarIDs.insert(calendar.id) } else { selectedCalendarIDs.remove(calendar.id) }
        preferences.set(Array(selectedCalendarIDs), forKey: "selectedCalendarIDs")
        // Immediately remove deselected calendar data, even if the following network refresh fails.
        events.removeAll { !selectedCalendarIDs.contains($0.calendarID) }
        do { try await calendarClient.clearCachedEvents() }
        catch { self.error = error.localizedDescription }
        await synchronizeReminders()
        if let activeRefresh { _ = await activeRefresh.value }
        guard current == generation, revision == selectionRevision, !isPreview else { return }
        await refresh()
    }

    private func selectInitialCalendars() {
        selectedCalendarIDs = Set(calendars.filter(\.isPrimary).map(\.id))
        if selectedCalendarIDs.isEmpty, let first = calendars.first { selectedCalendarIDs.insert(first.id) }
        preferences.set(Array(selectedCalendarIDs), forKey: "selectedCalendarIDs")
    }

    public func disconnectGoogle() async {
        do { try await disconnectCalendarConnection() }
        catch { self.error = error.localizedDescription }
    }

    private func invalidateCalendarOperations() {
        generation = UUID()
        selectionRevision = UUID()
        pendingCalendarJoinID = nil
        activeRefresh?.cancel()
        activeRefresh = nil
        activeRefreshID = nil
        activeRefreshPresentsErrors = false
        isRefreshing = false
        isConnecting = false
    }

    private func disconnectCalendarConnection() async throws {
        cancelGoogleConfigurationLoad()
        invalidateCalendarOperations()
        let client = calendarClient
        if !isPreview { events = [] }
        liveCalendarEvents = []
        calendars = []; selectedCalendarIDs = []
        isCalendarConnected = false; lastRefreshed = nil
        selectedEvent = nil; joinLink = ""; showJoinSheet = false
        preferences.removeObject(forKey: "selectedCalendarIDs")
        await reminders.disable()
        try await client.disconnect()
    }

    public func importGoogleConfiguration(from url: URL) async {
        do {
            let data = try Data(contentsOf: url)
            let configuration = try YapConfigurationStore.parseGoogle(data)
            // Always invalidate stored credentials, including when a previous sign-in expired.
            try await disconnectCalendarConnection()
            try saveGoogleConfiguration(data)
            calendarClient = makeConfiguredCalendarClient(configuration)
            googleConfigurationLoadState = .loaded
        } catch { self.error = error.localizedDescription }
    }

    public func beginReminderSetup() async {
        guard !isPreview, !showReminderPermission, !isChangingReminders else { return }
        reminderRevision = UUID()
        let revision = reminderRevision
        isChangingReminders = true
        defer { if reminderRevision == revision { isChangingReminders = false } }
        reminderPermissionError = nil
        let status = await reminders.authorizationStatus()
        guard reminderRevision == revision else { return }
        reminderAuthorizationStatus = status
        if status == .authorized {
            isChangingReminders = false
            await setReminders(true)
        }
        else { showReminderPermission = true }
    }

    public func cancelReminderSetup() {
        guard showReminderPermission || isChangingReminders else { return }
        reminderRevision = UUID()
        showReminderPermission = false
        isChangingReminders = false
        isWaitingForNotificationSettings = false
        reminderPermissionError = nil
    }

    public func openReminderNotificationSettings() {
        guard showReminderPermission, !isChangingReminders else { return }
        reminderPermissionError = nil
        isWaitingForNotificationSettings = reminders.openSettings()
        if !isWaitingForNotificationSettings {
            reminderPermissionError = "Open System Settings, choose Notifications, then select Yap."
        }
    }

    /// Observes changes made in macOS without ever requesting permission on focus.
    public func refreshReminderAuthorization() async {
        guard !isPreview else { return }
        let revision = reminderRevision
        let status = await reminders.authorizationStatus()
        guard reminderRevision == revision else { return }
        reminderAuthorizationStatus = status
        if status == .authorized, isWaitingForNotificationSettings, showReminderPermission {
            isWaitingForNotificationSettings = false
            remindersEnabled = true
            showReminderPermission = false
            reminderPermissionError = nil
            await synchronizeReminders()
        } else if status != .authorized, remindersEnabled {
            remindersEnabled = false
            await reminders.disable()
        }
    }

    /// Called only by the centered dialog's explicit approval action (or when
    /// enabling an already-authorized preference). Background refresh never asks.
    public func setReminders(_ enabled: Bool) async {
        guard !isPreview else { return }
        if enabled && isChangingReminders { return }
        reminderRevision = UUID()
        let revision = reminderRevision
        if enabled {
            isChangingReminders = true
            reminderPermissionError = nil
            defer { if reminderRevision == revision { isChangingReminders = false } }
            do {
                let status = await reminders.authorizationStatus()
                guard reminderRevision == revision else { return }
                reminderAuthorizationStatus = status
                if status == .denied {
                    remindersEnabled = false
                    showReminderPermission = true
                    return
                }
                let authorized = try await reminders.requestAuthorization()
                guard reminderRevision == revision else { return }
                remindersEnabled = authorized
                reminderAuthorizationStatus = authorized ? .authorized : .denied
                showReminderPermission = !authorized
                if authorized { await synchronizeReminders() }
                else { await reminders.disable() }
            } catch {
                guard reminderRevision == revision else { return }
                remindersEnabled = false
                showReminderPermission = true
                if error is YapReminderPermissionError {
                    reminderAuthorizationStatus = .denied
                } else {
                    reminderPermissionError = "Yap couldn’t enable notifications. Please try again."
                }
            }
        } else {
            remindersEnabled = false
            showReminderPermission = false
            isChangingReminders = false
            isWaitingForNotificationSettings = false
            reminderPermissionError = nil
            await reminders.disable()
        }
    }

    public func synchronizeReminders() async {
        guard remindersEnabled, isCalendarConnected, !isPreview else { return }
        let revision = reminderRevision
        let items = events.compactMap { event -> MeetingReminder? in
            guard !event.isCancelled, !event.isAllDay, let url = event.meetingURL else { return nil }
            return MeetingReminder(id: event.id, title: event.title, startDate: event.startDate, meetingURL: url)
        }
        do { try await reminders.synchronize(items, TimeInterval(reminderMinutes * 60)) }
        catch {
            guard reminderRevision == revision, remindersEnabled else { return }
            if error is YapReminderPermissionError {
                // Revocation can race a background calendar refresh. Keep the
                // preference honest without interrupting a meeting with an alert.
                remindersEnabled = false
                reminderAuthorizationStatus = .denied
            } else { self.error = error.localizedDescription }
        }
    }

    public func join(_ event: CalendarEvent) async {
        guard isPreview || !zoomConnection.isBusy else { error = "Finish connecting your Zoom account before joining a meeting."; return }
        guard !activeCall else { error = "Leave your current meeting before joining another."; return }
        guard !event.isCancelled, event.endDate > Date() else { error = "This meeting has ended or was cancelled. Refresh your calendar for the latest details."; return }
        selectedEvent = event
        let links = AgendaRules.meetingURLs(for: event)
        guard links.count == 1, let url = links.first else {
            joinLink = ""
            showJoinSheet = true
            return
        }
        await meeting.join(url: url, displayName: displayName, title: event.title)
    }

    public func receiveMeetingLink(_ url: URL) {
        pendingCalendarJoinID = nil
        meetingLinkRevision = UUID()
        guard let meetingURL = YapDeepLink.meetingURL(from: url),
              MeetingCoordinator.isZoomMeetingURL(meetingURL) else {
            if YapDeepLink.isZoomApplicationURL(url) {
                showJoinSheet = false
                unsupportedZoomLink = url
            }
            else { error = "This isn’t a supported Zoom meeting link." }
            return
        }
        guard !activeCall else {
            error = "Leave your current meeting before joining another."
            return
        }
        unsupportedZoomLink = nil
        selectedEvent = nil
        joinLink = meetingURL.absoluteString
        showJoinSheet = false
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showJoinSheet = true
            joinInputError = "Enter your name before joining the meeting."
            return
        }
        let revision = meetingLinkRevision
        let requestedMeeting = meeting
        Task { [weak self] in
            guard let self, self.meetingLinkRevision == revision,
                  self.meeting === requestedMeeting, !self.activeCall else { return }
            guard self.isPreview || !self.zoomConnection.isBusy else {
                self.error = "Finish connecting your Zoom account before joining a meeting."
                return
            }
            await self.meeting.join(url: meetingURL, displayName: self.displayName)
        }
    }

    public func joinPastedLink() async {
        guard !Task.isCancelled else { return }
        joinInputError = nil
        guard !activeCall else { joinInputError = "Leave your current meeting before joining another."; return }
        guard isPreview || !zoomConnection.isBusy else { joinInputError = "Finish connecting your Zoom account before joining a meeting."; return }
        guard let url = ZoomMeetingLinkParser.normalizedJoinURL(joinLink.trimmingCharacters(in: .whitespacesAndNewlines)),
              MeetingCoordinator.isZoomMeetingURL(url) else {
            joinInputError = "Enter a Zoom meeting link such as https://zoom.us/j/12345678901."; return
        }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            joinInputError = "Enter your name before joining the meeting."; return
        }
        showJoinSheet = false
        await meeting.join(url: url, displayName: displayName, title: selectedEvent?.title ?? "")
    }

    public func hostMeeting() async {
        guard isPreview || !zoomConnection.isBusy else { error = "Finish connecting your Zoom account before starting a meeting."; return }
        await meeting.host(displayName: displayName, title: isPreview ? "Design catch-up" : "")
    }

    public func requestLeaveMeeting() {
        guard activeCall, meeting.status != .leaving else { return }
        if askBeforeLeavingMeeting {
            showLeaveConfirmation = true
            return
        }
        let requestedMeeting = meeting
        let sessionID = meeting.sessionID
        Task { [weak self] in
            guard let self, self.meeting === requestedMeeting, self.meeting.sessionID == sessionID else { return }
            await self.leaveMeeting()
        }
    }

    public func leaveMeeting(endForEveryone: Bool = false) async {
        showLeaveConfirmation = false
        await meeting.leave(endForEveryone: endForEveryone)
        if !meeting.status.isActive { sidebar = nil; focusedParticipantID = nil }
    }

    public func enterPreview() {
        guard !activeCall else { error = "Leave your meeting before opening a preview."; return }
        guard !isPreview else { return }
        liveMeeting = meeting
        liveCalendarEvents = events
        selectedEvent = nil; joinLink = ""; showJoinSheet = false
        invalidateCalendarOperations()
        isPreview = true
        recordings.enterPreview()
        meeting = MeetingCoordinator(driver: DemoMeetingDriver(participantCount: previewPeople))
        events = Self.sampleEvents(now: .now)
    }

    public func exitPreview() async {
        guard isPreview, !activeCall else { return }
        invalidateCalendarOperations()
        selectedEvent = nil; joinLink = ""; showJoinSheet = false
        isPreview = false
        recordings.clear()
        meeting = liveMeeting
        events = liveCalendarEvents.filter { selectedCalendarIDs.contains($0.calendarID) }
        liveCalendarEvents = []
        await loadLiveCalendar()
    }

    public func setPreviewPeople(_ count: Int) {
        previewPeople = count
        meeting.setDemoParticipantCount(count)
    }

    public func updateGridLimit(_ limit: Int) {
        if limit == 0 { meeting.showAllParticipants() }
        else { meeting.setPageSize(limit) }
    }

    public func handleSystemActions() async {
        while let action = YapSystemActions.takePendingAction() {
            await handleSystemAction(action)
        }
    }

    /// A named menu-bar action stays bound to the event the person saw, even if
    /// a refresh changes the next meeting before the join can be dispatched.
    public func joinNextCalendarMeeting(expectedEventID: String? = nil) async {
        guard !Task.isCancelled, pendingCalendarJoinID == nil, !activeCall else { return }
        let operationID = UUID()
        let currentGeneration = generation
        let currentSelection = selectionRevision
        pendingCalendarJoinID = operationID
        defer {
            if pendingCalendarJoinID == operationID { pendingCalendarJoinID = nil }
        }
        let refreshed = isPreview ? true : await refresh()
        guard !Task.isCancelled, pendingCalendarJoinID == operationID,
              generation == currentGeneration, selectionRevision == currentSelection,
              !activeCall else { return }
        guard refreshed else {
            error = "Your calendar couldn’t be refreshed. Open the agenda and check the meeting before joining."
            return
        }
        let now = Date.now
        let ready = upcomingEvents.filter { AgendaRules.showsJoinButton(for: $0, now: now) }
        let event: CalendarEvent?
        if let expectedEventID { event = ready.first { $0.id == expectedEventID } }
        else { event = ready.first }
        guard let event else {
            error = expectedEventID == nil
                ? "There’s no Zoom meeting starting within five minutes or currently in progress."
                : "That meeting is no longer ready to join. Check your agenda."
            return
        }
        await join(event)
    }

    public func handleSystemAction(_ action: YapSystemAction) async {
        switch action {
            case .openYap, .showUpcomingMeetings: break
            case .joinNextMeeting:
                await joinNextCalendarMeeting()
            case .showMeeting(let id):
                let linkRevision = meetingLinkRevision
                let refreshed = isPreview ? false : await refresh()
                guard linkRevision == meetingLinkRevision else { return }
                guard refreshed else {
                    selectedEvent = nil; joinLink = ""; showJoinSheet = false
                    error = "Your calendar couldn’t be refreshed. Check the agenda before joining this meeting."
                    return
                }
                if let event = upcomingEvents.first(where: { $0.id == id }) {
                    let links = AgendaRules.meetingURLs(for: event)
                    selectedEvent = event; joinLink = links.count == 1 ? links[0].absoluteString : ""; showJoinSheet = true
                } else { error = "That meeting is no longer upcoming. Your agenda has been refreshed." }
        }
    }

    static func sampleEvents(now: Date) -> [CalendarEvent] {
        [("Design catch-up", 300.0, 1800.0), ("A little time to think", 3600.0, 1800.0), ("Friday roundtable", 7200.0, 2700.0)].enumerated().map { index, item in
            CalendarEvent(id: "preview-\(index)", title: item.0, startDate: now.addingTimeInterval(item.1), endDate: now.addingTimeInterval(item.1 + item.2), calendarID: "preview", calendarName: "Preview calendar", meetingURLs: index == 1 ? [] : [URL(string: "https://zoom.us/j/12345678901")!])
        }
    }
}

public enum MeetingSidebar: String { case chat, people }

public enum AgendaRules {
    /// Advertise only invitations accepted by the same validator used to join.
    public static func meetingURLs(for event: CalendarEvent) -> [URL] {
        event.meetingURLs.filter {
            ZoomMeetingLinkParser.validatedURL($0.absoluteString) != nil &&
            MeetingCoordinator.isZoomMeetingURL($0)
        }
    }

    public static func showsJoinButton(for event: CalendarEvent, now: Date) -> Bool {
        event.startDate.timeIntervalSince(now) <= 5 * 60 &&
        !upcoming([event], now: now).isEmpty
    }

    public static func upcoming(_ events: [CalendarEvent], now: Date) -> [CalendarEvent] {
        events.filter {
            !$0.isCancelled && !$0.isAllDay && $0.endDate > now &&
            !meetingURLs(for: $0).isEmpty
        }
            .sorted { $0.startDate == $1.startDate ? $0.id < $1.id : $0.startDate < $1.startDate }
    }
}

enum YapConfigurationStore {
    private static let service = "app.yap.personal.configuration"
    static func parseGoogle(_ data: Data) throws -> GoogleOAuthConfiguration {
        struct File: Decodable { struct Installed: Decodable { let client_id: String; let client_secret: String? }; let installed: Installed }
        let file = try JSONDecoder().decode(File.self, from: data)
        let configuration = GoogleOAuthConfiguration(clientID: file.installed.client_id, clientSecret: file.installed.client_secret)
        guard configuration.isValid else { throw GoogleCalendarError.notConfigured }
        return configuration
    }
    private static let key = CredentialKey(service: service, account: "google-desktop")
    static func loadGoogle() throws -> GoogleOAuthConfiguration? {
        try resolveGoogle(savedData: { try access { try CredentialVault.shared.load(key) } },
                          bundledInfo: Bundle.main.infoDictionary ?? [:])
    }
    // Packaged builds use Yap's client directly. Source builds can import their own.
    // Reading the bundled public client does not require Keychain access.
    static func resolveGoogle(savedData: () throws -> Data?, bundledInfo: [String: Any]) throws -> GoogleOAuthConfiguration? {
        guard let clientID = bundledInfo["YapGoogleClientID"] as? String else {
            return try savedData().map(parseGoogle)
        }
        let configuration = GoogleOAuthConfiguration(clientID: clientID,
            clientSecret: bundledInfo["YapGoogleClientSecret"] as? String)
        guard configuration.isValid else { throw GoogleCalendarError.notConfigured }
        return configuration
    }
    static func saveGoogle(_ data: Data) throws {
        _ = try parseGoogle(data)
        try access { try CredentialVault.shared.save(data, for: key) }
    }
    private static func access<Value>(_ action: () throws -> Value) throws -> Value {
        do { return try action() }
        catch CredentialVaultError.keychain(let status) { throw GoogleCalendarError.keychain(status) }
        catch CredentialVaultError.invalidData { throw GoogleCalendarError.invalidResponse }
    }
}
