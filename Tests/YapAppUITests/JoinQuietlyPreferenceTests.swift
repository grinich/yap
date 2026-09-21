import Foundation
import Testing
import YapCalendar
import YapMeetings
@testable import YapAppUI

@Suite("Join quietly preference") @MainActor
struct JoinQuietlyPreferenceTests {
    @Test(arguments: ["missing", "false string", "true string", "zero", "one", "array", "dictionary", "data"])
    func missingOrMalformedPreferenceStartsQuietly(_ value: String) async throws {
        let fixture = JoinQuietlyFixture()
        defer { fixture.cleanUp() }
        switch value {
        case "false string": fixture.preferences.set("false", forKey: "joinQuietly")
        case "true string": fixture.preferences.set("true", forKey: "joinQuietly")
        case "zero": fixture.preferences.set(0, forKey: "joinQuietly")
        case "one": fixture.preferences.set(1, forKey: "joinQuietly")
        case "array": fixture.preferences.set([false], forKey: "joinQuietly")
        case "dictionary": fixture.preferences.set(["enabled": false], forKey: "joinQuietly")
        case "data": fixture.preferences.set(Data([0]), forKey: "joinQuietly")
        default: break
        }
        let model = fixture.makeModel()
        #expect(model.joinQuietly)
        model.joinLink = JoinQuietlyFixture.invitation.absoluteString
        await model.joinPastedLink()
        let request = try #require(fixture.driver.requests.first)
        #expect(request.microphoneMuted)
        #expect(!request.cameraEnabled)
    }

    @Test func preferencePersistsInBothDirections() {
        let fixture = JoinQuietlyFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        #expect(model.joinQuietly)
        model.joinQuietly = false
        let reopened = fixture.makeModel()
        #expect(!reopened.joinQuietly)
        reopened.joinQuietly = true
        #expect(fixture.makeModel().joinQuietly)
    }

    @Test(arguments: [true, false], ["pasted", "calendar", "deep link", "host"])
    func normalMeetingEntryUsesSavedPreference(_ quietly: Bool, _ entry: String) async throws {
        let fixture = JoinQuietlyFixture()
        defer { fixture.cleanUp() }
        fixture.makeModel().joinQuietly = quietly
        let model = fixture.makeModel()
        switch entry {
        case "pasted":
            model.joinLink = JoinQuietlyFixture.invitation.absoluteString
            await model.joinPastedLink()
        case "calendar":
            await model.join(fixture.calendarEvent)
        case "deep link":
            model.receiveMeetingLink(URL(string: "zoommtg://zoom.us/join?action=join&confno=12345678901&video=0")!)
            for _ in 0..<100 where fixture.driver.requests.isEmpty { await Task.yield() }
        default:
            await model.hostMeeting()
        }
        #expect(fixture.driver.requests.count == 1)
        let request = try #require(fixture.driver.requests.first)
        #expect(request.microphoneMuted == quietly)
        #expect(request.cameraEnabled == !quietly)
        #expect(request.isHost == (entry == "host"))
        #expect(!request.isRoomShare)
        #expect(request.displayName == "Test Person")
        if entry != "host" { #expect(request.url == JoinQuietlyFixture.invitation) }
        if entry == "calendar" {
            #expect(request.title == fixture.calendarEvent.title)
            #expect(request.scheduledInterval?.start == fixture.calendarEvent.startDate)
            #expect(request.scheduledInterval?.end == fixture.calendarEvent.endDate)
        }
        #expect(model.meeting.isConnected)
        #expect(model.error == nil)
        #expect(model.joinInputError == nil)
    }

    @Test(arguments: [true, false])
    func changingPreferenceAffectsTheNextCallWithoutChangingActiveMedia(_ initialQuietly: Bool) async throws {
        let fixture = JoinQuietlyFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.joinQuietly = initialQuietly
        model.joinLink = JoinQuietlyFixture.invitation.absoluteString
        await model.joinPastedLink()
        let sessionID = try #require(model.meeting.sessionID)
        #expect(model.meeting.isMicrophoneMuted == initialQuietly)
        #expect(model.meeting.isCameraEnabled == !initialQuietly)

        model.joinQuietly = !initialQuietly
        for _ in 0..<10 { await Task.yield() }

        #expect(model.meeting.sessionID == sessionID)
        #expect(fixture.driver.requests.count == 1)
        #expect(fixture.driver.microphoneCommands.isEmpty)
        #expect(fixture.driver.cameraCommands.isEmpty)
        #expect(model.meeting.isMicrophoneMuted == initialQuietly)
        #expect(model.meeting.isCameraEnabled == !initialQuietly)

        await model.leaveMeeting()
        await model.joinPastedLink()
        #expect(fixture.driver.requests.count == 2)
        let nextRequest = try #require(fixture.driver.requests.last)
        #expect(nextRequest.microphoneMuted == !initialQuietly)
        #expect(nextRequest.cameraEnabled == initialQuietly)
    }

    @Test func roomSharingKeepsMediaOffWhenQuietJoiningIsDisabled() async throws {
        let fixture = JoinQuietlyFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.joinQuietly = false

        await model.shareScreenToRoom()

        #expect(fixture.driver.requests.count == 1)
        let request = try #require(fixture.driver.requests.first)
        #expect(request.isRoomShare)
        #expect(!request.isHost)
        #expect(request.url == nil)
        #expect(request.microphoneMuted)
        #expect(!request.cameraEnabled)
        #expect(model.meeting.isMicrophoneMuted)
        #expect(!model.meeting.isCameraEnabled)
        #expect(fixture.driver.microphoneCommands.isEmpty)
        #expect(fixture.driver.cameraCommands.isEmpty)
        #expect(model.error == nil)
    }
}

@MainActor
private final class JoinQuietlyFixture {
    static let invitation = URL(string: "https://zoom.us/j/12345678901")!
    let suite = "JoinQuietlyPreferenceTests.\(UUID())"
    let preferences: UserDefaults
    let driver = JoinQuietlyDriver()
    let calendarEvent: CalendarEvent

    init() {
        preferences = UserDefaults(suiteName: suite)!
        preferences.set("Test Person", forKey: "displayName")
        let start = Date.now
        calendarEvent = CalendarEvent(id: "quiet-preference", title: "Fixture meeting", startDate: start,
            endDate: start.addingTimeInterval(1800), calendarID: "fixture", calendarName: "Fixture",
            meetingURLs: [Self.invitation])
    }

    func makeModel() -> YapModel {
        YapModel(preview: false, preferences: preferences, meeting: MeetingCoordinator(driver: driver),
            reminders: YapReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}),
            loadGoogleConfiguration: { nil })
    }

    func cleanUp() { preferences.removePersistentDomain(forName: suite) }
}

@MainActor
private final class JoinQuietlyDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: false, canShare: true, supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var requests: [MeetingRequest] = []
    var microphoneCommands: [Bool] = []
    var cameraCommands: [Bool] = []

    func connect(_ request: MeetingRequest, sessionID: UUID) async throws {
        requests.append(request)
        onEvent?(sessionID, .status(.inMeeting))
        onEvent?(sessionID, .participants([
            MeetingParticipant(id: "self", name: request.displayName, isSelf: true, isHost: request.isHost,
                isMuted: request.microphoneMuted, isCameraEnabled: request.cameraEnabled)
        ]))
        onEvent?(sessionID, .microphoneMuted(request.microphoneMuted))
        onEvent?(sessionID, .cameraEnabled(request.cameraEnabled))
    }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { onEvent?(sessionID, .status(.idle)) }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws { microphoneCommands.append(muted) }
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws { cameraCommands.append(enabled) }
    func sendChat(text: String, sessionID: UUID) async throws {}
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {}
    func stopShare(sessionID: UUID) async throws {}
}
