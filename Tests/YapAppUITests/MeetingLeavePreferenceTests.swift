import Foundation
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Meeting leave preference") @MainActor
struct MeetingLeavePreferenceTests {
    @Test(arguments: [true, false])
    func defaultLeaveNeverEndsForEveryone(_ isHost: Bool) async {
        let fixture = LeavePreferenceFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        #expect(!model.askBeforeLeavingMeeting)
        await fixture.connect(model, isHost: isHost)
        #expect(model.meeting.isHost == isHost)

        model.requestLeaveMeeting()
        for _ in 0..<100 where model.activeCall { await Task.yield() }

        #expect(fixture.driver.leaveRequests == [false])
        #expect(!model.showLeaveConfirmation)
        #expect(!model.activeCall)
    }

    @Test(arguments: [true, false])
    func enabledConfirmationWaitsForAnExplicitChoice(_ isHost: Bool) async {
        let fixture = LeavePreferenceFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.askBeforeLeavingMeeting = true
        await fixture.connect(model, isHost: isHost)

        model.requestLeaveMeeting()
        #expect(model.showLeaveConfirmation)
        #expect(model.activeCall)
        #expect(fixture.driver.leaveRequests.isEmpty)
        model.showLeaveConfirmation = false // Stay
        #expect(model.activeCall)
        model.requestLeaveMeeting()
        await model.leaveMeeting()
        #expect(fixture.driver.leaveRequests == [false])
        #expect(!model.showLeaveConfirmation)
        #expect(!model.activeCall)
    }

    @Test func confirmationPreferencePersistsBothWays() {
        let fixture = LeavePreferenceFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.askBeforeLeavingMeeting = true
        let reopened = fixture.makeModel()
        #expect(reopened.askBeforeLeavingMeeting)
        reopened.askBeforeLeavingMeeting = false
        #expect(!fixture.makeModel().askBeforeLeavingMeeting)
    }

    @Test func hostCanExplicitlyEndWithDefaultConfirmationDisabled() async {
        let fixture = LeavePreferenceFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        await fixture.connect(model, isHost: true)
        model.showLeaveConfirmation = true // Explicit host menu action
        await model.leaveMeeting(endForEveryone: true)
        #expect(fixture.driver.leaveRequests == [true])
        #expect(!model.showLeaveConfirmation)
        #expect(!model.activeCall)
    }

    @Test func queuedLeaveDoesNotAffectAReplacementSession() async {
        let fixture = LeavePreferenceFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        await fixture.connect(model, isHost: false)
        model.requestLeaveMeeting()
        let oldSession = model.meeting.sessionID!
        fixture.driver.onEvent?(oldSession, .status(.idle))
        await fixture.connect(model, isHost: false)
        for _ in 0..<10 { await Task.yield() }
        #expect(fixture.driver.leaveRequests.isEmpty)
        #expect(model.activeCall)
    }
}

@MainActor
private final class LeavePreferenceFixture {
    let suite = "MeetingLeavePreferenceTests.\(UUID())"
    let preferences: UserDefaults
    let driver = LeavePreferenceDriver()

    init() { preferences = UserDefaults(suiteName: suite)! }

    func makeModel() -> YapModel {
        YapModel(preview: false, preferences: preferences, meeting: MeetingCoordinator(driver: driver),
            reminders: YapReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}),
            loadGoogleConfiguration: { nil })
    }

    func connect(_ model: YapModel, isHost: Bool) async {
        if isHost { await model.meeting.host(displayName: "Test") }
        else { await model.meeting.join(url: URL(string: "https://zoom.us/j/12345678901")!, displayName: "Test") }
    }

    func cleanUp() { preferences.removePersistentDomain(forName: suite) }
}

@MainActor
private final class LeavePreferenceDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: false, canShare: false, supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var leaveRequests: [Bool] = []

    func connect(_ request: MeetingRequest, sessionID: UUID) async throws {
        onEvent?(sessionID, .status(.inMeeting))
        onEvent?(sessionID, .participants([
            MeetingParticipant(id: "self", name: request.displayName, isSelf: true, isHost: request.isHost)
        ]))
    }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws {
        leaveRequests.append(endForEveryone)
        onEvent?(sessionID, .status(.idle))
    }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws {}
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws {}
    func sendChat(text: String, sessionID: UUID) async throws {}
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {}
    func stopShare(sessionID: UUID) async throws {}
}
