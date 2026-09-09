import Foundation
import Testing
import YapCalendar
import YapMeetings
@testable import YapAppUI

@Suite("Menu bar meeting actions", .serialized) @MainActor
struct YapMenuBarActionTests {
    @Test func idlePrimaryTogglesButContextOpenAndManualJoinAlwaysShow() async {
        let fixture = MenuBarFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        #expect(fixture.toggleActions.primaryAction == .openYap)
        await fixture.toggleActions.performPrimaryAction(expectedAction: .openYap)
        await fixture.toggleActions.performPrimaryAction(expectedAction: .openYap)
        #expect(fixture.toggleCount == 2)
        #expect(fixture.openCount == 0)
        #expect(!fixture.model.showJoinSheet)
        #expect(fixture.driver.requests.isEmpty)

        fixture.toggleActions.openYap()
        #expect(fixture.openCount == 1)
        #expect(fixture.toggleCount == 2)
        fixture.toggleActions.joinWithLink()
        #expect(fixture.openCount == 2)
        #expect(fixture.toggleCount == 2)
        #expect(fixture.model.showJoinSheet)
        #expect(fixture.driver.requests.isEmpty)
    }

    @Test func namedJoinReturnAndStopSharingNeverToggleTheWindow() async {
        let fixture = MenuBarFixture(events: [MenuBarFixture.event(number: "12345678901")])
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.toggleActions.performPrimaryAction(expectedAction: .joinMeeting,
                                                         expectedMeetingID: fixture.toggleActions.displayedMeetingID)
        #expect(fixture.openCount == 1)
        #expect(fixture.driver.requests.count == 1)
        #expect(fixture.toggleCount == 0)

        await fixture.toggleActions.performPrimaryAction(expectedAction: .returnToMeeting)
        #expect(fixture.openCount == 2)
        #expect(fixture.toggleCount == 0)
        fixture.driver.setSharing(.sharing(MenuBarFixture.sharedWindow))
        await fixture.toggleActions.performPrimaryAction(expectedAction: .stopSharing)
        #expect(fixture.driver.stopRequests == 1)
        #expect(fixture.openCount == 2)
        #expect(fixture.toggleCount == 0)

        fixture.toggleActions.openYap()
        #expect(fixture.openCount == 3)
        #expect(fixture.toggleCount == 0)
        #expect(fixture.driver.stopRequests == 1)
        #expect(fixture.model.meeting.sharing.isSharing)
    }

    @Test func queuedIdleToggleCannotBecomeAJoinOrHideANewCall() async {
        let now = Date.now
        let event = MenuBarFixture.event(number: "12345678901", startDate: now.addingTimeInterval(600),
                                        endDate: now.addingTimeInterval(1_200))
        let fixture = MenuBarFixture(events: [event], now: now)
        defer { fixture.cleanUp() }
        await fixture.model.start()
        let requestedAction = fixture.toggleActions.primaryAction
        #expect(requestedAction == .openYap)
        fixture.now = event.startDate.addingTimeInterval(-300)
        fixture.toggleActions.refreshEligibility()
        await fixture.toggleActions.performPrimaryAction(expectedAction: requestedAction)
        #expect(fixture.toggleCount == 0)
        #expect(fixture.openCount == 0)
        #expect(fixture.driver.requests.isEmpty)

        await fixture.connect()
        await fixture.toggleActions.performPrimaryAction(expectedAction: requestedAction)
        #expect(fixture.toggleActions.primaryAction == .returnToMeeting)
        #expect(fixture.toggleCount == 0)
        #expect(fixture.openCount == 0)
        #expect(fixture.driver.requests.count == 1)
    }

    @Test func noCalendarMeetingOpensYapAndLeavesManualLinkEntryExplicit() async {
        let fixture = MenuBarFixture()
        defer { fixture.cleanUp() }
        await fixture.model.start()
        fixture.model.joinLink = "stale closed-sheet value"
        #expect(fixture.actions.primaryAction == .openYap)
        #expect(fixture.actions.primaryActionTitle == "Yap")
        #expect(fixture.actions.displayedMeetingID == nil)
        await fixture.actions.performPrimaryAction()
        #expect(fixture.openCount == 1)
        #expect(!fixture.model.showJoinSheet)
        #expect(fixture.model.joinLink == "stale closed-sheet value")
        fixture.actions.joinWithLink()
        #expect(fixture.model.showJoinSheet)
        #expect(fixture.model.joinLink.isEmpty)
        #expect(fixture.model.selectedEvent == nil)
        #expect(fixture.driver.requests.isEmpty)
        fixture.model.joinLink = "partly entered invitation"
        fixture.actions.joinWithLink()
        #expect(fixture.model.joinLink == "partly entered invitation")
        #expect(fixture.model.error == nil)
        #expect(await fixture.calendar.eventRequests == 1)
    }

    @Test func namedJoinAppearsAtFiveMinutesAndExpiresAtTheMeetingEnd() async {
        let now = Date.now
        let event = MenuBarFixture.event(number: "12345678901", title: "A deliberately long meeting title that remains complete for accessibility",
                                         startDate: now.addingTimeInterval(600), endDate: now.addingTimeInterval(1_200))
        let fixture = MenuBarFixture(events: [event], now: now)
        defer { fixture.cleanUp() }
        await fixture.model.start()
        #expect(fixture.actions.primaryAction == .openYap)
        #expect(fixture.actions.nextEligibilityChange == event.startDate.addingTimeInterval(-300))
        await fixture.actions.performPrimaryAction()
        #expect(fixture.openCount == 1)
        #expect(fixture.driver.requests.isEmpty)
        #expect(await fixture.calendar.eventRequests == 1)

        fixture.now = now.addingTimeInterval(300)
        fixture.actions.refreshEligibility()
        #expect(fixture.actions.primaryAction == .joinMeeting)
        #expect(fixture.actions.primaryActionTitle == "Join \(event.title)")
        #expect(fixture.actions.displayedMeetingID == event.id)
        #expect(fixture.actions.nextEligibilityChange == event.endDate)
        fixture.now = now.addingTimeInterval(900)
        fixture.actions.refreshEligibility()
        #expect(fixture.actions.primaryAction == .joinMeeting)
        fixture.now = event.endDate
        fixture.actions.refreshEligibility()
        #expect(fixture.actions.primaryAction == .openYap)
        #expect(fixture.actions.displayedMeetingID == nil)
        #expect(fixture.actions.nextEligibilityChange == nil)
        await fixture.actions.performPrimaryAction(expectedAction: .joinMeeting, expectedMeetingID: event.id)
        #expect(fixture.openCount == 1)
        #expect(fixture.driver.requests.isEmpty)
    }

    @Test func queuedNamedJoinCannotRetargetAfterTheDisplayedEventChanges() async {
        let first = MenuBarFixture.event(number: "12345678901", id: "first-event")
        let fixture = MenuBarFixture(events: [first])
        defer { fixture.cleanUp() }
        await fixture.model.start()
        let displayedID = fixture.actions.displayedMeetingID
        let replacement = MenuBarFixture.event(number: "98765432109", id: "replacement-event")
        await fixture.calendar.setEvents([replacement])
        await fixture.model.refresh()
        await fixture.actions.performPrimaryAction(expectedAction: .joinMeeting, expectedMeetingID: displayedID)
        #expect(fixture.actions.displayedMeetingID == replacement.id)
        #expect(fixture.driver.requests.isEmpty)
        #expect(fixture.openCount == 0)
        #expect(await fixture.calendar.eventRequests == 2)
    }

    @Test func endingTheFirstMeetingSchedulesTheNextMeetingsEligibilityWithoutARefresh() async {
        let now = Date.now
        let first = MenuBarFixture.event(number: "12345678901", id: "first", startDate: now,
                                         endDate: now.addingTimeInterval(60))
        let next = MenuBarFixture.event(number: "98765432109", id: "next", title: "Next meeting",
                                        startDate: now.addingTimeInterval(900), endDate: now.addingTimeInterval(1_200))
        let fixture = MenuBarFixture(events: [first, next], now: now)
        defer { fixture.cleanUp() }
        await fixture.model.start()
        #expect(fixture.actions.displayedMeetingID == first.id)
        #expect(fixture.actions.nextEligibilityChange == first.endDate)
        fixture.now = first.endDate
        fixture.actions.refreshEligibility()
        #expect(fixture.actions.primaryAction == .openYap)
        #expect(fixture.actions.nextEligibilityChange == next.startDate.addingTimeInterval(-300))
        fixture.now = next.startDate.addingTimeInterval(-300)
        fixture.actions.refreshEligibility()
        #expect(fixture.actions.primaryActionTitle == "Join Next meeting")
        #expect(fixture.actions.displayedMeetingID == next.id)
        #expect(fixture.actions.nextEligibilityChange == next.endDate)
        #expect(await fixture.calendar.eventRequests == 1)
        #expect(fixture.driver.requests.isEmpty)
    }

    @Test func namedJoinCannotRetargetWhenRefreshReplacesTheEvent() async {
        let first = MenuBarFixture.event(number: "12345678901", id: "first-event")
        let fixture = MenuBarFixture(events: [first])
        defer { fixture.cleanUp() }
        await fixture.model.start()
        let displayedID = fixture.actions.displayedMeetingID
        await fixture.calendar.setEvents([MenuBarFixture.event(number: "98765432109", id: "replacement-event")])
        await fixture.actions.performPrimaryAction(expectedAction: .joinMeeting, expectedMeetingID: displayedID)
        #expect(fixture.driver.requests.isEmpty)
        #expect(fixture.model.error != nil)
        #expect(fixture.openCount == 1)
        #expect(await fixture.calendar.eventRequests == 2)
        #expect(!fixture.actions.isPerforming)
    }

    @Test func nextMeetingIsRefreshedBeforeJoiningAndStartsWithMediaOff() async {
        let fixture = MenuBarFixture(events: [MenuBarFixture.event(number: "12345678901")])
        defer { fixture.cleanUp() }
        await fixture.model.start()
        let replacement = MenuBarFixture.event(number: "98765432109")
        await fixture.calendar.setEvents([replacement])
        // Merely receiving calendar updates cannot invoke the action.
        #expect(fixture.driver.requests.isEmpty)
        await fixture.actions.performPrimaryAction()
        #expect(fixture.openCount == 1)
        #expect(fixture.driver.requests.count == 1)
        #expect(fixture.driver.requests.first?.url == replacement.meetingURL)
        #expect(fixture.driver.requests.first?.microphoneMuted == true)
        #expect(fixture.driver.requests.first?.cameraEnabled == false)
        #expect(await fixture.calendar.eventRequests == 2)
        #expect(!fixture.actions.isPerforming)
    }

    @Test func ambiguousInvitationsUseTheExistingChooser() async {
        let first = MenuBarFixture.event(number: "12345678901")
        let ambiguous = CalendarEvent(id: first.id, title: first.title, startDate: first.startDate, endDate: first.endDate,
                                      calendarID: first.calendarID, calendarName: first.calendarName,
                                      meetingURLs: first.meetingURLs + [URL(string: "https://zoom.us/j/98765432109")!])
        let fixture = MenuBarFixture(events: [ambiguous])
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.actions.performPrimaryAction()
        #expect(fixture.model.showJoinSheet)
        #expect(fixture.model.selectedEvent?.id == ambiguous.id)
        #expect(fixture.driver.requests.isEmpty)
    }

    @Test(arguments: [MeetingStatus.connecting, .waitingForHost, .waitingRoom, .inMeeting, .reconnecting, .leaving])
    func everyActiveCallStateOnlyReopensTheExistingWindow(_ status: MeetingStatus) async {
        let fixture = MenuBarFixture(events: [MenuBarFixture.event(number: "12345678901")])
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.model.meeting.join(url: URL(string: "https://zoom.us/j/11111111111")!, displayName: "Fixture")
        fixture.driver.setStatus(status)
        let existingSession = fixture.model.meeting.sessionID
        await fixture.actions.performPrimaryAction()
        fixture.actions.joinWithLink()
        #expect(fixture.openCount == 2)
        #expect(fixture.model.meeting.sessionID == existingSession)
        #expect(fixture.model.meeting.status == status)
        #expect(fixture.driver.requests.count == 1)
        #expect(fixture.driver.mediaControls == 0)
        #expect(!fixture.model.showJoinSheet)
        #expect(await fixture.calendar.eventRequests == 1)
    }

    @Test func repeatedClicksDuringRefreshCannotStartTwoMeetings() async {
        let fixture = MenuBarFixture(events: [MenuBarFixture.event(number: "12345678901")])
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.calendar.pauseNextEvents()
        let first = Task { await fixture.actions.performPrimaryAction() }
        await fixture.calendar.waitUntilPaused()
        #expect(fixture.actions.isPerforming)
        await fixture.actions.performPrimaryAction()
        fixture.actions.joinWithLink()
        #expect(fixture.driver.requests.isEmpty)
        #expect(!fixture.model.showJoinSheet)
        await fixture.calendar.resumeEvents()
        await first.value
        #expect(fixture.driver.requests.count == 1)
        #expect(await fixture.calendar.eventRequests == 2)
        #expect(!fixture.actions.isPerforming)
    }

    @Test func failedRefreshCannotJoinTheCachedInvitation() async {
        let fixture = MenuBarFixture(events: [MenuBarFixture.event(number: "12345678901")])
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.calendar.failEvents()
        await fixture.actions.performPrimaryAction()
        #expect(fixture.driver.requests.isEmpty)
        #expect(fixture.model.error != nil)
        #expect(!fixture.actions.isPerforming)
    }

    @Test func stopSharingAppearsAndDisappearsOnlyAfterAuthoritativeCallbacks() async {
        let fixture = MenuBarFixture()
        defer { fixture.cleanUp() }
        #expect(fixture.actions.primaryAction == .openYap)
        await fixture.connect()
        #expect(fixture.actions.primaryAction == .returnToMeeting)
        await fixture.model.meeting.startShare(MenuBarFixture.sharedWindow)
        #expect(fixture.actions.primaryAction == .returnToMeeting)
        fixture.driver.setSharing(.sharing(MenuBarFixture.sharedWindow))
        #expect(fixture.actions.primaryAction == .stopSharing)
        #expect(fixture.actions.canPerformPrimaryAction)
        await fixture.actions.performPrimaryAction()
        #expect(fixture.driver.stopRequests == 1)
        #expect(fixture.openCount == 0)
        #expect(fixture.actions.primaryAction == .stopSharing)
        #expect(fixture.model.meeting.sharing.isSharing)
        fixture.driver.setSharing(.idle)
        #expect(fixture.actions.primaryAction == .returnToMeeting)
        #expect(fixture.model.activeCall)
        await fixture.actions.performPrimaryAction()
        #expect(fixture.openCount == 1)
        #expect(fixture.driver.requests.count == 1)
    }

    @Test func repeatedStopClicksAreCoalescedWithoutOpeningAWindow() async {
        let fixture = MenuBarFixture()
        defer { fixture.cleanUp() }
        await fixture.connect()
        fixture.driver.setSharing(.sharing(MenuBarFixture.sharedWindow))
        fixture.driver.pauseStop = true
        let first = Task { await fixture.actions.performPrimaryAction() }
        await fixture.driver.waitUntilStopped()
        #expect(!fixture.actions.canPerformPrimaryAction)
        await fixture.actions.performPrimaryAction()
        #expect(fixture.driver.stopRequests == 1)
        #expect(fixture.openCount == 0)
        fixture.driver.resumeStop()
        await first.value
        #expect(fixture.actions.primaryAction == .stopSharing)
        #expect(fixture.actions.canPerformPrimaryAction)
    }

    @Test func disconnectedOrBusySharingCannotIssueAnotherControl() async {
        let fixture = MenuBarFixture()
        defer { fixture.cleanUp() }
        await fixture.connect()
        fixture.driver.setSharing(.sharing(MenuBarFixture.sharedWindow))
        fixture.driver.setStatus(.reconnecting)
        #expect(fixture.actions.primaryAction == .stopSharing)
        #expect(!fixture.actions.canPerformPrimaryAction)
        await fixture.actions.performPrimaryAction()
        #expect(fixture.driver.stopRequests == 0)
        fixture.driver.setStatus(.inMeeting)
        fixture.driver.pauseStop = true
        let existingControl = Task { await fixture.model.meeting.stopShare() }
        await fixture.driver.waitUntilStopped()
        #expect(fixture.model.meeting.isApplyingControl)
        #expect(!fixture.actions.isPerforming)
        #expect(!fixture.actions.canPerformPrimaryAction)
        await fixture.actions.performPrimaryAction()
        #expect(fixture.driver.stopRequests == 1)
        #expect(fixture.openCount == 0)
        fixture.driver.resumeStop()
        await existingControl.value
    }

    @Test func failedStopKeepsTheVisibleStopActionAndAllowsRetry() async {
        let fixture = MenuBarFixture()
        defer { fixture.cleanUp() }
        await fixture.connect()
        fixture.driver.setSharing(.sharing(MenuBarFixture.sharedWindow))
        fixture.driver.failStop = true
        await fixture.actions.performPrimaryAction()
        #expect(fixture.model.meeting.lastError != nil)
        #expect(fixture.actions.primaryAction == .stopSharing)
        #expect(fixture.actions.canPerformPrimaryAction)
        fixture.driver.failStop = false
        await fixture.actions.performPrimaryAction()
        #expect(fixture.driver.stopRequests == 2)
        #expect(fixture.openCount == 0)
    }

    @Test func aQueuedClickCannotTurnIntoADifferentActionAfterAStateChange() async {
        let fixture = MenuBarFixture(events: [MenuBarFixture.event(number: "12345678901")])
        defer { fixture.cleanUp() }
        await fixture.model.start()
        await fixture.connect()
        fixture.driver.setSharing(.sharing(MenuBarFixture.sharedWindow))
        await fixture.actions.performPrimaryAction(expectedAction: .joinMeeting)
        #expect(fixture.driver.stopRequests == 0)
        fixture.driver.setSharing(.idle)
        await fixture.model.meeting.leave()
        #expect(fixture.actions.primaryAction == .joinMeeting)
        await fixture.actions.performPrimaryAction(expectedAction: .stopSharing)
        #expect(fixture.driver.requests.count == 1)
        #expect(fixture.openCount == 0)
        #expect(await fixture.calendar.eventRequests == 1)
    }

    @Test func sharingChatToggleUsesTheMainSidebar() async {
        let fixture = MenuBarFixture()
        defer { fixture.cleanUp() }
        await fixture.connect()
        fixture.driver.setSharing(.sharing(MenuBarFixture.sharedWindow))
        fixture.model.sidebar = .people
        #expect(fixture.actions.sharingChatIsVisible == false)
        fixture.actions.setSharingChatVisible(true)
        #expect(fixture.actions.sharingChatIsVisible == true)
        #expect(fixture.model.sidebar == .chat)
        fixture.actions.setSharingChatVisible(false)
        #expect(fixture.openCount == 0)
        #expect(fixture.driver.stopRequests == 0)
    }

    @Test func theMenuUsesTheCurrentChatSurfaceAndPreservesAnExplicitShowIntent() async {
        let fixture = MenuBarFixture()
        defer { fixture.cleanUp() }
        await fixture.connect()
        fixture.driver.setSharing(.sharing(MenuBarFixture.sharedWindow))
        fixture.model.sidebar = .people
        #expect(fixture.actions.sharingChatIsVisible == false)
        fixture.actions.setSharingChatVisible(true)
        #expect(fixture.model.sidebar == .chat)
        fixture.actions.setSharingChatVisible(false)
        #expect(fixture.model.sidebar == nil)
        #expect(fixture.openCount == 0)
    }

    @Test func aStaleChatMenuCannotChangeTheNextMeetingOrAStoppedShare() async {
        let fixture = MenuBarFixture()
        defer { fixture.cleanUp() }
        await fixture.connect()
        fixture.model.sidebar = .people
        #expect(fixture.actions.sharingChatIsVisible == nil)
        fixture.actions.setSharingChatVisible(true)
        #expect(fixture.model.sidebar == .people)
        fixture.driver.setSharing(.sharing(MenuBarFixture.sharedWindow))
        let priorSession = fixture.model.meeting.sessionID
        fixture.driver.setSharing(.idle)
        fixture.actions.setSharingChatVisible(true)
        #expect(fixture.actions.sharingChatIsVisible == nil)
        #expect(fixture.openCount == 0)
        await fixture.model.meeting.leave()
        await fixture.connect()
        fixture.driver.setSharing(.sharing(MenuBarFixture.sharedWindow))
        fixture.actions.setSharingChatVisible(true, expectedSessionID: priorSession)
        #expect(fixture.openCount == 0)
    }
}

@MainActor
private final class MenuBarFixture {
    let suite = "YapMenuBarTests.\(UUID())"
    let preferences: UserDefaults
    let calendar: MenuBarCalendar
    let driver = MenuBarDriver()
    let model: YapModel
    var openCount = 0
    var toggleCount = 0
    var now: Date
    lazy var actions = YapMenuBarActionHandler(model: model, now: { [weak self] in self?.now ?? .now }) { [weak self] in self?.openCount += 1 }
    lazy var toggleActions = YapMenuBarActionHandler(
        model: model, now: { [weak self] in self?.now ?? .now },
        toggleMainWindow: { [weak self] in self?.toggleCount += 1 },
        openMainWindow: { [weak self] in self?.openCount += 1 })

    init(events: [CalendarEvent] = [], now: Date = .now) {
        self.now = now
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(["fixture"], forKey: "selectedCalendarIDs")
        calendar = MenuBarCalendar(events: events)
        model = YapModel(preview: false, preferences: preferences, meeting: MeetingCoordinator(driver: driver),
                            calendarClient: calendar,
                            reminders: YapReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}))
    }
    func cleanUp() { preferences.removePersistentDomain(forName: suite) }
    static let sharedWindow = ShareTarget(id: "fixture-window", title: "Fixture window", kind: .window)
    func connect() async {
        await model.meeting.join(url: URL(string: "https://zoom.us/j/12345678901")!, displayName: "Fixture")
    }
    static func event(number: String, id: String = "fixture-event", title: String = "Fixture meeting",
                      startDate: Date = Date().addingTimeInterval(240), endDate: Date = Date().addingTimeInterval(900)) -> CalendarEvent {
        CalendarEvent(id: id, title: title, startDate: startDate,
                      endDate: endDate, calendarID: "fixture", calendarName: "Fixture",
                      meetingURLs: [URL(string: "https://zoom.us/j/\(number)")!])
    }
}

private actor MenuBarCalendar: YapCalendarServing {
    nonisolated let isConfigured = true
    private var listedEvents: [CalendarEvent]
    private var failure = false
    private var pauseNext = false
    private var paused = false
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?
    private(set) var eventRequests = 0
    init(events: [CalendarEvent]) { listedEvents = events }
    func hasCredentials() -> Bool { true }
    func calendars() -> [GoogleCalendar] { [GoogleCalendar(id: "fixture", name: "Fixture", isPrimary: true)] }
    func cachedSnapshot() -> CalendarSnapshot? { nil }
    func clearCachedEvents() {}
    func connect(openURL: @escaping @MainActor @Sendable (URL) -> Void) -> [GoogleCalendar] { calendars() }
    func disconnect() {}
    func setEvents(_ events: [CalendarEvent]) { listedEvents = events }
    func failEvents() { failure = true }
    func pauseNextEvents() { pauseNext = true }
    func waitUntilPaused() async {
        if !paused { await withCheckedContinuation { pauseWaiter = $0 } }
    }
    func resumeEvents() { resumeWaiter?.resume(); resumeWaiter = nil }
    func events(in calendars: [GoogleCalendar], from: Date, to: Date) async throws -> [CalendarEvent] {
        eventRequests += 1
        if pauseNext {
            pauseNext = false; paused = true
            await withCheckedContinuation { continuation in
                resumeWaiter = continuation
                pauseWaiter?.resume(); pauseWaiter = nil
            }
        }
        if failure { throw GoogleCalendarError.httpStatus(503) }
        return listedEvents
    }
}

@MainActor
private final class MenuBarDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: false, canShare: true, supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var requests: [MeetingRequest] = []
    var mediaControls = 0
    var stopRequests = 0
    var pauseStop = false
    var failStop = false
    private var stopWaiter: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var sessionID: UUID?
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws {
        requests.append(request); self.sessionID = sessionID
        onEvent?(sessionID, .status(.inMeeting))
    }
    func setStatus(_ status: MeetingStatus) { if let sessionID { onEvent?(sessionID, .status(status)) } }
    func setSharing(_ sharing: MeetingSharingState) { if let sessionID { onEvent?(sessionID, .sharing(sharing)) } }
    func waitUntilStopped() async {
        if stopContinuation == nil { await withCheckedContinuation { stopWaiter = $0 } }
    }
    func resumeStop() { stopContinuation?.resume(); stopContinuation = nil }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { onEvent?(sessionID, .status(.idle)) }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws { mediaControls += 1 }
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws { mediaControls += 1 }
    func sendChat(text: String, sessionID: UUID) async throws {}
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {}
    func stopShare(sessionID: UUID) async throws {
        stopRequests += 1
        if pauseStop {
            pauseStop = false
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
                stopWaiter?.resume(); stopWaiter = nil
            }
        }
        if failStop { throw MeetingError.noMeeting }
    }
}
