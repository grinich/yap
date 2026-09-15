import Foundation
import Testing
@testable import YapMeetings

@Suite("Chat reply routing") @MainActor
struct ChatReplyRoutingTests {
    @Test func repliesUseTheOriginalSDKMessageAndNeverFallBackToBroadcast() async throws {
        let driver = ReplyDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Me")
        let session = try #require(meeting.sessionID)
        let message = MeetingChatMessage(senderName: "Alex", text: "Question", sdkID: "zoom-message", canReply: true)
        driver.onEvent?(session, .message(message))
        await meeting.sendChat(text: "Answer", sessionID: session, replyingTo: message.id)
        #expect(driver.replyID == "zoom-message")
        #expect(driver.broadcasts == 0)
        driver.replyID = nil
        driver.onEvent?(session, .messageRemoved(message.id))
        await meeting.sendChat(text: "Late answer", sessionID: session, replyingTo: message.id)
        #expect(driver.replyID == nil)
        #expect(driver.broadcasts == 0)
        #expect(meeting.lastError != nil)
        await meeting.leave()
        await meeting.host(displayName: "Me")
        await meeting.sendChat(text: "Wrong call", sessionID: session, replyingTo: message.id)
        #expect(driver.replyID == nil)
        #expect(driver.broadcasts == 0)
    }
}
@MainActor private final class ReplyDriver: MeetingDriver {
    let isDemo = true
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: true, canShare: false, supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var replyID: String?
    var broadcasts = 0
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws { onEvent?(sessionID, .status(.inMeeting)) }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { onEvent?(sessionID, .status(.idle)) }
    func sendChat(text: String, sessionID: UUID) async throws { broadcasts += 1 }
    func sendChatReply(text: String, messageID: String, sessionID: UUID) async throws { replyID = messageID }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws {}
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws {}
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {}
    func stopShare(sessionID: UUID) async throws {}
}
