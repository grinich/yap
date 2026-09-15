import Foundation
import Testing
@testable import YapMeetings

@Suite("Advanced meeting chat") @MainActor
struct AdvancedMeetingChatTests {
    @Test func copiedPanelistsAndUnknownAudiencesAreNeverLabeledPrivateOrRepliedTo() {
        let audience = MeetingChatRecipient(kind: .attendeeAndPanelists, participantID: "4", name: "Attendee + all panelists")
        let message = MeetingChatMessage(senderName: "Panelist", text: "Message", recipient: audience)
        #expect(!audience.label.contains("private"))
        #expect(message.replyRecipient == nil)
        #expect(MeetingChatMessage(senderName: "Someone", text: "Message", recipient: .init(kind: .unavailable, name: "Unknown audience")).replyRecipient == nil)
    }
    private func fixture() async -> (MeetingCoordinator, AdvancedChatDriver, UUID) {
        let driver = AdvancedChatDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Me")
        let session = meeting.sessionID!
        driver.onEvent?(session, .participants([
            MeetingParticipant(id: "1", name: "Me", isSelf: true),
            MeetingParticipant(id: "2", name: "Alex", isHost: true),
            MeetingParticipant(id: "3", name: "Sam")
        ]))
        driver.onEvent?(session, .chatPolicy(MeetingChatPolicy(canPrivate: true, canWaitingRoom: true, canTransferFiles: true)))
        return (meeting, driver, session)
    }

    @Test func privateRepliesUseOriginalSenderRegardlessOfComposerRecipient() async {
        let (meeting, driver, session) = await fixture()
        let message = MeetingChatMessage(senderName: "Alex", text: "Private", sdkID: "private", canReply: true,
            senderID: "2", recipient: .init(kind: .participant, participantID: "1", name: "Me"))
        driver.onEvent?(session, .message(message))
        await meeting.sendChat(text: "Answer", sessionID: session, replyingTo: message.id, recipient: .everyone)
        #expect(driver.sent.last?.recipient.participantID == "2")
        #expect(driver.sent.last?.recipient.kind == .participant)
        #expect(driver.sent.last?.replyToSDKID == "private")
    }

    @Test func recipientDepartureAndPermissionChangesNeverWidenAudience() async {
        let (meeting, driver, session) = await fixture()
        let target = MeetingChatRecipient(kind: .participant, participantID: "3", name: "Sam")
        driver.onEvent?(session, .participants([MeetingParticipant(id: "1", name: "Me", isSelf: true)]))
        await meeting.sendChat(text: "After leaving", sessionID: session, recipient: target)
        #expect(driver.sent.isEmpty)
        #expect(meeting.lastError != nil)
        driver.onEvent?(session, .chatPolicy(MeetingChatPolicy(canEveryone: false)))
        await meeting.sendChat(text: "Restricted", sessionID: session)
        #expect(driver.sent.isEmpty)
    }

    @Test func unknownPrivateSenderAndDeletedReplyCannotBecomeBroadcast() async {
        let (meeting, driver, session) = await fixture()
        let unknown = MeetingChatMessage(senderName: "Unknown", text: "Private", sdkID: "unknown", canReply: true,
            recipient: .init(kind: .participant, participantID: "1", name: "Me"))
        driver.onEvent?(session, .message(unknown))
        await meeting.sendChat(text: "Answer", sessionID: session, replyingTo: unknown.id)
        #expect(driver.sent.isEmpty)
        driver.onEvent?(session, .messageRemoved(unknown.id))
        await meeting.sendChat(text: "Late answer", sessionID: session, replyingTo: unknown.id)
        #expect(driver.sent.isEmpty)
    }

    @Test func oldSessionCannotSendOrDeleteAndFormattingMustMatchText() async {
        let (meeting, driver, session) = await fixture()
        await meeting.sendChat(text: "A", sessionID: session, runs: [.init(text: "B", bold: true)])
        #expect(driver.sent.isEmpty)
        let own = MeetingChatMessage(senderName: "Me", text: "Old", isFromSelf: true, sdkID: "own", canDelete: true)
        driver.onEvent?(session, .message(own))
        await meeting.leave()
        await meeting.host(displayName: "Me")
        await meeting.sendChat(text: "Stale", sessionID: session)
        await meeting.deleteChat(own, sessionID: session)
        #expect(driver.sent.isEmpty)
        #expect(driver.deleted.isEmpty)
    }

    @Test func ownDeletionWaitsForProviderEventAndCannotDeleteOthers() async {
        let (meeting, driver, session) = await fixture()
        let own = MeetingChatMessage(senderName: "Me", text: "Own", isFromSelf: true, sdkID: "own", canDelete: true)
        let other = MeetingChatMessage(senderName: "Alex", text: "Other", sdkID: "other", canDelete: true)
        driver.onEvent?(session, .message(own)); driver.onEvent?(session, .message(other))
        await meeting.deleteChat(other, sessionID: session)
        #expect(driver.deleted.isEmpty)
        await meeting.deleteChat(own, sessionID: session)
        #expect(driver.deleted == ["own"])
        #expect(meeting.chatMessages.contains { $0.id == own.id })
        driver.onEvent?(session, .messageRemoved(own.id))
        #expect(!meeting.chatMessages.contains { $0.id == own.id })
    }

    @Test func hostOnlyChatRestrictsRecipientListAndWaitingRoomIsExplicit() async {
        let (meeting, driver, session) = await fixture()
        driver.onEvent?(session, .chatPolicy(MeetingChatPolicy(canEveryone: false, onlyHost: true)))
        #expect(meeting.chatRecipients.map(\.participantID) == ["2"])
        await meeting.sendChat(text: "Waiting room", sessionID: session, recipient: .waitingRoom)
        #expect(driver.sent.isEmpty)
        driver.onEvent?(session, .chatPolicy(MeetingChatPolicy(canWaitingRoom: true)))
        await meeting.sendChat(text: "We’ll admit you shortly", sessionID: session, recipient: .waitingRoom)
        #expect(driver.sent.last?.recipient == .waitingRoom)
    }

    @Test func fileProgressUpdatesExistingTransferAndStaleEventsAreIgnored() async {
        let (meeting, driver, session) = await fixture()
        var file = MeetingChatAttachment(id: "file", name: "notes.txt", bytes: 9, senderName: "Alex", isFromSelf: false)
        driver.onEvent?(session, .chatAttachment(file))
        #expect(meeting.unreadChatMessageIDs.count == 1)
        file.status = .transferring; file.progress = 0.5
        driver.onEvent?(session, .chatAttachment(file))
        #expect(meeting.chatAttachments.count == 1)
        #expect(meeting.chatAttachments.first?.progress == 0.5)
        #expect(meeting.unreadChatMessageIDs.count == 1)
        await meeting.leave()
        await meeting.host(displayName: "Me")
        driver.onEvent?(session, .chatAttachment(file))
        #expect(meeting.chatAttachments.isEmpty)
    }

    @Test func fileValidationChecksExtensionSizeAndRegularFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.TXT")
        try Data("Hello".utf8).write(to: file)
        try MeetingChatFileValidation.validate(file, policy: .init(allowedFileTypes: "*.txt,.pdf", maxFileBytes: 5))
        #expect(throws: (any Error).self) { try MeetingChatFileValidation.validate(file, policy: .init(maxFileBytes: 4)) }
        #expect(throws: (any Error).self) { try MeetingChatFileValidation.validate(file, policy: .init(allowedFileTypes: "pdf")) }
        #expect(throws: (any Error).self) { try MeetingChatFileValidation.validate(directory, policy: .init()) }
    }
}

@MainActor private final class AdvancedChatDriver: MeetingDriver {
    let isDemo = true
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: true, canShare: false, supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var sent: [MeetingChatDraft] = []
    var deleted: [String] = []
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws { onEvent?(sessionID, .status(.inMeeting)) }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { onEvent?(sessionID, .status(.idle)) }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws {}
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws {}
    func sendChat(text: String, sessionID: UUID) async throws { sent.append(MeetingChatDraft(text: text)) }
    func sendChat(_ draft: MeetingChatDraft, sessionID: UUID) async throws { sent.append(draft) }
    func deleteChat(messageID: String, sessionID: UUID) async throws { deleted.append(messageID) }
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {}
    func stopShare(sessionID: UUID) async throws {}
}
