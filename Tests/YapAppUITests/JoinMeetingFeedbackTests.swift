import Foundation
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Join sheet feedback") @MainActor
struct JoinMeetingFeedbackTests {
    @Test func incomingNativeLinkPreparesJoinWithoutStartingMedia() async {
        let fixture = JoinFeedbackFixture()
        defer { fixture.cleanUp() }
        fixture.model.showJoinSheet = false
        fixture.model.receiveMeetingLink(URL(string: "zoommtg://us02web.zoom.us/join?action=join&confno=12345678901&pwd=a%2Bb%26c&uname=SomeoneElse&video=1")!)
        #expect(fixture.model.showJoinSheet)
        #expect(fixture.model.joinLink == "https://us02web.zoom.us/j/12345678901?pwd=a%2Bb%26c")
        #expect(fixture.model.displayName == "Test Person")
        #expect(fixture.driver.requests.isEmpty)
        #expect(fixture.model.unsupportedZoomLink == nil)
        await fixture.model.joinPastedLink()
        #expect(fixture.driver.requests.count == 1)
        #expect(fixture.driver.requests.first?.microphoneMuted == true)
        #expect(fixture.driver.requests.first?.cameraEnabled == false)
    }

    @Test func incomingLinkDoesNotReplaceAnActiveMeeting() async {
        let fixture = JoinFeedbackFixture()
        defer { fixture.cleanUp() }
        await fixture.model.meeting.join(url: URL(string: JoinFeedbackFixture.validInvitation)!, displayName: "Test")
        fixture.model.showJoinSheet = false
        fixture.model.joinLink = "previous draft"
        fixture.model.receiveMeetingLink(URL(string: "zoommtg://zoom.us/join?action=join&confno=99999999999")!)
        #expect(!fixture.model.showJoinSheet)
        #expect(fixture.model.joinLink == "previous draft")
        #expect(fixture.model.error == "Leave your current meeting before joining another.")
        #expect(fixture.driver.requests.count == 1)
    }

    @Test func unsupportedZoomActionOffersExplicitOfficialAppHandoff() {
        let fixture = JoinFeedbackFixture()
        defer { fixture.cleanUp() }
        fixture.model.showJoinSheet = true
        let url = URL(string: "zoommtg://zoom.us/start?confno=12345678901&zak=fixture")!
        fixture.model.receiveMeetingLink(url)
        #expect(fixture.model.unsupportedZoomLink == url)
        #expect(!fixture.model.showJoinSheet)
        #expect(fixture.driver.requests.isEmpty)
        #expect(fixture.model.error == nil)
    }

    @Test func disguisedZoomHostDoesNotOfferOfficialAppHandoff() {
        let fixture = JoinFeedbackFixture()
        defer { fixture.cleanUp() }
        fixture.model.showJoinSheet = false
        fixture.model.receiveMeetingLink(URL(string: "zoommtg://zoom.us.evil.example/join?action=join&confno=12345678901")!)
        #expect(fixture.model.unsupportedZoomLink == nil)
        #expect(!fixture.model.showJoinSheet)
        #expect(fixture.model.error != nil)
        #expect(fixture.driver.requests.isEmpty)
    }

    @Test func pastedNativeLinkUsesTheSameMeetingAndMediaDefaults() async {
        let fixture = JoinFeedbackFixture()
        defer { fixture.cleanUp() }
        fixture.model.joinLink = "zoomus://zoom.us/join?action=join&confno=12345678901&pwd=fixture"
        await fixture.model.joinPastedLink()
        #expect(fixture.driver.requests.first?.url?.absoluteString == "https://zoom.us/j/12345678901?pwd=fixture")
        #expect(fixture.driver.requests.first?.microphoneMuted == true)
        #expect(fixture.driver.requests.first?.cameraEnabled == false)
        #expect(!fixture.model.showJoinSheet)
    }

    @Test(arguments: [
        "https://example.com/not-a-zoom-meeting",
        "https://zoom.us.example.com/j/12345678901",
        "http://zoom.us/j/12345678901",
        "https://zoom.us/j/00000000000",
        "https://zoom.us/j/12345678901?pwd=one&pwd=two",
        "https://zoom.com/j/12345678901"
    ])
    func invalidInvitationKeepsTheSheetOpenWithLocalFeedback(_ link: String) async {
        let fixture = JoinFeedbackFixture()
        defer { fixture.cleanUp() }
        fixture.model.joinLink = link
        await fixture.model.joinPastedLink()

        #expect(fixture.model.joinInputError == "Enter a Zoom meeting link such as https://zoom.us/j/12345678901.")
        #expect(fixture.model.showJoinSheet)
        #expect(fixture.driver.requests.isEmpty)
        #expect(fixture.model.error == nil)
        #expect(fixture.model.meeting.lastError == nil)
        // Cancel must not expose the delayed global alert observed in the live app.
        fixture.model.showJoinSheet = false
        #expect(fixture.model.joinInputError == nil)
        #expect(fixture.model.error == nil)
        #expect(fixture.model.meeting.lastError == nil)
    }

    @Test func localValidationDoesNotConsumeAnUnrelatedGlobalError() async {
        let fixture = JoinFeedbackFixture()
        defer { fixture.cleanUp() }
        fixture.model.error = "An unrelated calendar refresh failed."
        fixture.model.joinLink = "https://example.com/not-a-zoom-meeting"
        await fixture.model.joinPastedLink()
        #expect(fixture.model.joinInputError != nil)
        fixture.model.showJoinSheet = false
        #expect(fixture.model.error == "An unrelated calendar refresh failed.")
    }

    @Test func editingTheFieldsClearsFeedbackAndAValidLinkJoinsMuted() async {
        let fixture = JoinFeedbackFixture()
        defer { fixture.cleanUp() }
        fixture.model.joinLink = "invalid"
        await fixture.model.joinPastedLink()
        #expect(fixture.model.joinInputError != nil)

        let invitation = "https://us02web.zoom.us/j/12345678901?pwd=opaque-invitation-token"
        fixture.model.joinLink = "  \(invitation) \n"
        #expect(fixture.model.joinInputError == nil)
        fixture.model.displayName = " \n "
        await fixture.model.joinPastedLink()
        #expect(fixture.model.joinInputError == "Enter your name before joining the meeting.")
        #expect(fixture.model.showJoinSheet)
        #expect(fixture.driver.requests.isEmpty)

        fixture.model.displayName = "  Test Person  "
        #expect(fixture.model.joinInputError == nil)
        await fixture.model.joinPastedLink()
        #expect(!fixture.model.showJoinSheet)
        #expect(fixture.model.error == nil)
        #expect(fixture.model.joinInputError == nil)
        #expect(fixture.driver.requests.count == 1)
        #expect(fixture.driver.requests.first?.url?.absoluteString == invitation)
        #expect(fixture.driver.requests.first?.displayName == "Test Person")
        #expect(fixture.driver.requests.first?.microphoneMuted == true)
        #expect(fixture.driver.requests.first?.cameraEnabled == false)
    }

    @Test func anActiveCallIsExplainedInsideTheSheetWithoutAnotherJoin() async {
        let fixture = JoinFeedbackFixture()
        defer { fixture.cleanUp() }
        await fixture.model.meeting.join(url: URL(string: JoinFeedbackFixture.validInvitation)!, displayName: "Test")
        fixture.model.joinLink = JoinFeedbackFixture.validInvitation
        await fixture.model.joinPastedLink()
        #expect(fixture.model.joinInputError == "Leave your current meeting before joining another.")
        #expect(fixture.model.showJoinSheet)
        #expect(fixture.model.meeting.status == .inMeeting)
        #expect(fixture.driver.requests.count == 1)
        #expect(fixture.model.error == nil)
        #expect(fixture.model.meeting.lastError == nil)
    }

    @Test func aBusyAccountShowsLocalFeedbackAndCanBeRetried() async {
        let store = JoinFeedbackCredentialStore()
        let connection = ZoomConnectionModel(client: ZoomAccountClient(store: store), openURL: { _ in })
        let fixture = JoinFeedbackFixture(connection: connection)
        defer { fixture.cleanUp() }
        let configuration = ZoomPersonalConfiguration(sdkClientID: "fixture-sdk", sdkClientSecret: "fixture-secret", oauthPublicClientID: "fixture-public")
        let save = Task { await connection.saveConfiguration(configuration) }
        await store.waitForSave()
        #expect(connection.isBusy)
        fixture.model.joinLink = JoinFeedbackFixture.validInvitation
        await fixture.model.joinPastedLink()
        #expect(fixture.model.joinInputError == "Finish connecting your Zoom account before joining a meeting.")
        #expect(fixture.model.showJoinSheet)
        #expect(fixture.driver.requests.isEmpty)
        #expect(fixture.model.error == nil)

        await store.resumeSave()
        #expect(await save.value)
        await fixture.model.joinPastedLink()
        #expect(fixture.model.joinInputError == nil)
        #expect(!fixture.model.showJoinSheet)
        #expect(fixture.driver.requests.count == 1)
    }
}

@MainActor
private final class JoinFeedbackFixture {
    static let validInvitation = "https://zoom.us/j/12345678901"
    let suite = "YapJoinFeedback-\(UUID())"
    let preferences: UserDefaults
    let driver = JoinFeedbackDriver()
    let model: YapModel

    init(connection: ZoomConnectionModel? = nil) {
        preferences = UserDefaults(suiteName: suite)!
        preferences.set("Test Person", forKey: "displayName")
        model = YapModel(preview: false, preferences: preferences,
                            meeting: MeetingCoordinator(driver: driver), zoomConnection: connection,
                            reminders: YapReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}),
                            loadGoogleConfiguration: { nil })
        model.showJoinSheet = true
    }

    func cleanUp() { preferences.removePersistentDomain(forName: suite) }
}

@MainActor
private final class JoinFeedbackDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: false, canShare: false, supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var requests: [MeetingRequest] = []

    func connect(_ request: MeetingRequest, sessionID: UUID) async throws {
        requests.append(request)
        onEvent?(sessionID, .status(.inMeeting))
    }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { onEvent?(sessionID, .status(.idle)) }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws {}
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws {}
    func sendChat(text: String, sessionID: UUID) async throws {}
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {}
    func stopShare(sessionID: UUID) async throws {}
}

private actor JoinFeedbackCredentialStore: ZoomCredentialStore {
    var configuration: ZoomPersonalConfiguration?
    var saveStarted = false
    var saveWaiter: CheckedContinuation<Void, Never>?
    var saveContinuation: CheckedContinuation<Void, Never>?

    func loadConfiguration() -> ZoomPersonalConfiguration? { configuration }
    func saveConfiguration(_ configuration: ZoomPersonalConfiguration) async {
        self.configuration = configuration
        await withCheckedContinuation { continuation in
            saveContinuation = continuation
            saveStarted = true
            saveWaiter?.resume(); saveWaiter = nil
        }
    }
    func waitForSave() async {
        if !saveStarted { await withCheckedContinuation { saveWaiter = $0 } }
    }
    func resumeSave() { saveContinuation?.resume(); saveContinuation = nil }
    func loadTokens() -> ZoomOAuthTokens? { nil }
    func saveTokens(_ tokens: ZoomOAuthTokens) {}
    func deleteTokens() {}
    func deleteAll() { configuration = nil }
}
