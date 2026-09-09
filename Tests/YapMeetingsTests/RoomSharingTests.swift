import AppKit
import Testing
@testable import YapMeetings

@Suite("Zoom Room sharing") @MainActor
struct RoomSharingTests {
    @Test func pairingUsesASeparateRequestAndWaitsForContentSelection() async throws {
        let driver = RoomDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.shareToRoom(displayName: "Michael")
        let id = try #require(meeting.sessionID)
        #expect(driver.request?.isRoomShare == true)
        #expect(driver.request?.url == nil)
        #expect(driver.request?.microphoneMuted == true)
        #expect(driver.request?.cameraEnabled == false)
        #expect(meeting.roomShareStage == .searching)
        #expect(!meeting.canChooseSharingContent)
        #expect(driver.shares.isEmpty)
        driver.onEvent?(id, .roomShare(.needsCode))
        await meeting.submitRoomSharingCode(" abc def ")
        #expect(driver.codes == ["ABCDEF"])
        #expect(meeting.roomShareStage == .searching)
        driver.onEvent?(id, .roomShare(.choosingContent))
        #expect(meeting.canChooseSharingContent)
        let sources = try await meeting.availableShareTargetsForChooser()
        #expect(driver.shares.isEmpty)
        try await meeting.startShareFromChooser(try #require(sources.first))
        #expect(driver.shares == sources)
        driver.onEvent?(id, .roomShare(.sharing))
        #expect(meeting.roomShareStage == .sharing)
    }

    @Test func cancellationWaitsForTerminalCallbackAndRejectsLatePairing() async throws {
        let driver = RoomDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.shareToRoom(displayName: "Michael")
        let id = try #require(meeting.sessionID)
        await meeting.leave()
        #expect(driver.endedForEveryone == false)
        #expect(meeting.status == .leaving)
        driver.onEvent?(id, .roomShare(.choosingContent))
        #expect(!meeting.canChooseSharingContent)
        driver.onEvent?(id, .status(.idle))
        #expect(!meeting.isRoomShare)
        #expect(meeting.sessionID == nil)
        await meeting.join(url: URL(string: "https://zoom.us/j/12345678901")!, displayName: "Michael")
        driver.onEvent?(id, .roomShare(.sharing))
        #expect(!meeting.isRoomShare)
        #expect(driver.request?.isRoomShare == false)
    }

    @Test func roomSharingCannotReplaceACallOrEnableMeetingCameraAndMic() async throws {
        let driver = RoomDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.shareToRoom(displayName: "Michael")
        let id = try #require(meeting.sessionID)
        driver.onEvent?(id, .status(.inMeeting))
        await meeting.setCameraEnabled(true)
        await meeting.setMicrophoneMuted(false)
        #expect(driver.mediaChanges == 0)
        await meeting.shareToRoom(displayName: "Other")
        #expect(meeting.sessionID == id)
        #expect(driver.connects == 1)
    }

    @Test func invalidCodesStayEditableAndCannotBeSubmittedTwiceWhileConnecting() async throws {
        let driver = RoomDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.shareToRoom(displayName: "Michael")
        let id = try #require(meeting.sessionID)
        driver.onEvent?(id, .roomShare(.needsCode))
        await meeting.submitRoomSharingCode("https://zoom.us/")
        #expect(driver.codes.isEmpty)
        #expect(meeting.roomShareStage == .needsCode)
        await meeting.submitRoomSharingCode("ABCDEF")
        await meeting.submitRoomSharingCode("ABCDEF")
        #expect(driver.codes.count == 1)
        driver.onEvent?(id, .roomShare(.invalidCode))
        await meeting.submitRoomSharingCode("123 456 789")
        #expect(driver.codes.last == "123456789")
    }
}

@MainActor private final class RoomDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: true, canShare: true,
        supportsNativeVideo: false, canEnumerateShareTargets: true)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var request: MeetingRequest?
    var codes: [String] = []
    var shares: [ShareTarget] = []
    var connects = 0
    var mediaChanges = 0
    var endedForEveryone: Bool?
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws { self.request = request; connects += 1 }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { endedForEveryone = endForEveryone }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws { mediaChanges += 1 }
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws { mediaChanges += 1 }
    func sendChat(text: String, sessionID: UUID) async throws {}
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws { shares.append(target) }
    func stopShare(sessionID: UUID) async throws {}
    func submitRoomSharingCode(_ code: String, sessionID: UUID) async throws { codes.append(code) }
    func availableShareTargets(sessionID: UUID) async throws -> [ShareTarget] {
        [.init(id: "1", title: "Display", kind: .display)]
    }
}
