import AppKit
import Foundation
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Advanced chat presentation") @MainActor
struct MeetingChatAdvancedUITests {
    @Test func messageTextMenuUsesOnlyItsOwnYapActions() {
        var invoked: [String] = []
        let first = MeetingChatMessageText.MessageTextView()
        first.messageActions = [.init(title: "Reply", perform: { invoked.append("first-reply") }), .init(title: "Copy", perform: { invoked.append("first-copy") })]
        let second = MeetingChatMessageText.MessageTextView()
        second.messageActions = [.init(title: "Delete message", perform: { invoked.append("second-delete") })]
        #expect(first.messageMenu().items.map(\.title) == ["Reply", "Copy"])
        #expect(second.messageMenu().items.map(\.title) == ["Delete message"])
        let openMenu = first.messageMenu()
        first.messageActions = [.init(title: "Delete message", perform: { invoked.append("wrong-deletion") })]
        second.performMessageAction(second.messageMenu().items[0])
        first.performMessageAction(openMenu.items[0])
        #expect(invoked == ["second-delete", "first-reply"])
    }
    @Test func quotingRestrictedAudiencesKeepsTheirAudienceAndClearsOtherThreads() {
        let presentation = YapMeetingPresentation()
        for recipient in [MeetingChatRecipient.panelists, .waitingRoom, .init(kind: .participant, participantID: "1", name: "Me")] {
            presentation.chatRecipient = .everyone
            presentation.replyingTo = MeetingChatMessage(senderName: "Public", text: "Other thread", sdkID: "other")
            let message = MeetingChatMessage(senderName: "Alex", text: "Restricted", senderID: "2", recipient: recipient)
            #expect(presentation.quoteMessage(message))
            #expect(presentation.chatRecipient == message.replyRecipient)
            #expect(presentation.replyingTo == nil)
        }
        let draft = presentation.chatDraft
        #expect(!presentation.quoteMessage(MeetingChatMessage(senderName: "Unknown", text: "Hidden", recipient: .init(kind: .unavailable, name: "Unknown audience"))))
        #expect(presentation.chatDraft == draft)
    }
    @Test func richTextRoundTripPreservesUnicodeAndMixedStyles() {
        let runs: [MeetingChatTextRun] = [
            .init(text: "Hi 👩🏽‍💻 ", bold: true), .init(text: "café", italic: true, underline: true),
            .init(text: " link", strikethrough: true, link: "https://example.com/a")
        ]
        let text = runs.map(\.text).joined()
        #expect(MeetingChatRichText.runs(from: MeetingChatRichText.attributed(runs, fallback: text)) == runs)
    }
    @Test func unsafeLinksAndMismatchedFormattingAreDiscarded() {
        #expect(MeetingChatRichText.safeLink("file:///etc/passwd") == nil)
        #expect(MeetingChatRichText.safeLink("javascript:alert(1)") == nil)
        let text = MeetingChatRichText.attributed([.init(text: "Different", bold: true)], fallback: "Actual")
        #expect(text.string == "Actual")
        #expect(MeetingChatRichText.runs(from: text).isEmpty)
    }
    @Test func addingBoldPreservesItalicAcrossMixedSelection() {
        let view = NSTextView()
        let runs: [MeetingChatTextRun] = [.init(text: "plain "), .init(text: "italic", italic: true)]
        view.textStorage?.setAttributedString(MeetingChatRichText.attributed(runs, fallback: "plain italic"))
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        let state = MeetingChatEditorState(); state.textView = view
        state.toggle(.bold)
        let result = MeetingChatRichText.runs(from: view.attributedString())
        #expect(result.allSatisfy { $0.bold })
        #expect(result.last?.italic == true)
    }
    @Test func privateAndPublicThreadsNeverMergeOnSameThreadID() {
        let root = MeetingChatMessage(senderName: "Alex", text: "Public", sdkID: "same")
        let privateReply = MeetingChatMessage(senderName: "Alex", text: "Private", threadID: "same", isReply: true,
            senderID: "2", recipient: .init(kind: .participant, participantID: "1", name: "Me"))
        let groups = MeetingChatThread.group([root, privateReply])
        #expect(groups.count == 2)
        #expect(groups.first?.replies.isEmpty == true)
    }
    @Test func privateRepliesInBothDirectionsShareOneThread() {
        let root = MeetingChatMessage(senderName: "Alex", text: "Private", sdkID: "root", senderID: "2",
            recipient: .init(kind: .participant, participantID: "1", name: "Me"))
        let reply = MeetingChatMessage(senderName: "Me", text: "Reply", isFromSelf: true, threadID: "root", isReply: true,
            senderID: "1", recipient: .init(kind: .participant, participantID: "2", name: "Alex"))
        #expect(MeetingChatThread.group([root, reply]).first?.replies.map(\.id) == [reply.id])
    }
    @Test func searchAndExportKeepPrivateAudienceAndAttachmentContext() {
        let message = MeetingChatMessage(senderName: "Alex", text: "Café plan", recipient: .init(kind: .participant, participantID: "1", name: "Me"))
        #expect(MeetingChatArchive.matches(message, query: "cafe"))
        #expect(MeetingChatArchive.matches(message, query: "private"))
        let file = MeetingChatAttachment(id: "file", name: "notes.txt", bytes: 3, senderName: "Alex", isFromSelf: false)
        let exported = MeetingChatArchive.text(messages: [message], attachments: [file], title: "Weekly")
        #expect(exported.contains("Me (private)"))
        #expect(exported.contains("Attachment: notes.txt"))
        #expect(MeetingChatArchive.safeFileName("../../notes.txt") == "notes.txt")
    }
    @Test func draftsAndFormattingResetBetweenSessions() {
        let presentation = YapMeetingPresentation()
        presentation.synchronize(sessionID: UUID())
        presentation.chatDraft = "Private"
        presentation.chatRuns = [.init(text: "Private", bold: true)]
        presentation.chatRecipient = .init(kind: .participant, participantID: "2", name: "Alex")
        presentation.synchronize(sessionID: UUID())
        #expect(presentation.chatDraft.isEmpty)
        #expect(presentation.chatRuns.isEmpty)
        #expect(presentation.chatRecipient == .everyone)
    }
}
