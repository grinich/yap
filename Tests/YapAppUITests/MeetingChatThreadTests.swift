import Foundation
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Chat threads") @MainActor
struct MeetingChatThreadTests {
    @Test func repliesAreGroupedEvenIfReceivedBeforeTheirParentAndOrphansStayVisible() {
        let root = MeetingChatMessage(senderName: "Alex", text: "Hello", sdkID: "root", canReply: true)
        let reply = MeetingChatMessage(senderName: "Sam", text: "Hi", sdkID: "reply", threadID: "root", isReply: true, canReply: true)
        let orphan = MeetingChatMessage(senderName: "Pat", text: "Earlier thread", threadID: "old", isReply: true)
        let grouped = MeetingChatThread.group([reply, root, orphan])
        #expect(grouped.map(\.id) == [root.id, orphan.id])
        #expect(grouped[0].replies.map(\.id) == [reply.id])
        #expect(grouped[1].replies.isEmpty)
        #expect(MeetingChatThread.group([reply]).map(\.id) == [reply.id])
    }
    @Test func replyContextClearsBetweenMeetings() {
        let presentation = YapMeetingPresentation()
        presentation.synchronize(sessionID: UUID())
        presentation.replyingTo = MeetingChatMessage(senderName: "Alex", text: "Old")
        presentation.chatDraft = "Old draft"
        presentation.synchronize(sessionID: UUID())
        #expect(presentation.replyingTo == nil)
        #expect(presentation.chatDraft.isEmpty)
    }

    @Test func openingLatestReplyExpandsItsThreadInsteadOfTargetingAnInvisibleRow() {
        let root = MeetingChatMessage(senderName: "Alex", text: "Plan", sdkID: "root", canReply: true)
        let laterRoot = MeetingChatMessage(senderName: "Pat", text: "Different topic", sdkID: "later")
        let reply = MeetingChatMessage(senderName: "Sam", text: "Back to the plan", threadID: "root", isReply: true)
        let target = MeetingChatThread.latestScrollTarget(in: [root, laterRoot, reply])
        #expect(target?.messageID == reply.id)
        #expect(target?.expandedThreadID == root.id)
    }

    @Test func latestOrphanIsVisibleWithoutExpandingAnUnavailableParent() {
        let reply = MeetingChatMessage(senderName: "Sam", text: "Reply", threadID: "expired", isReply: true)
        let target = MeetingChatThread.latestScrollTarget(in: [reply])
        #expect(target?.messageID == reply.id)
        #expect(target?.expandedThreadID == nil)
        #expect(MeetingChatThread.latestScrollTarget(in: []) == nil)
    }

    @Test func latestRootDoesNotOpenAnUnrelatedThread() {
        let root = MeetingChatMessage(senderName: "Alex", text: "Plan", sdkID: "root")
        let reply = MeetingChatMessage(senderName: "Sam", text: "Reply", threadID: "root", isReply: true)
        let latest = MeetingChatMessage(senderName: "Pat", text: "New topic", sdkID: "latest")
        let target = MeetingChatThread.latestScrollTarget(in: [root, reply, latest])
        #expect(target?.messageID == latest.id)
        #expect(target?.expandedThreadID == nil)
    }

    @Test func repliesPreserveArrivalOrderWithAnExplicitThreadID() {
        let root = MeetingChatMessage(senderName: "Alex", text: "Plan", sdkID: "root-message", threadID: "thread")
        let first = MeetingChatMessage(senderName: "Sam", text: "First", threadID: "thread", isReply: true)
        let other = MeetingChatMessage(senderName: "Pat", text: "Other root", sdkID: "other")
        let second = MeetingChatMessage(senderName: "Sam", text: "Second", threadID: "thread", isReply: true)
        let groups = MeetingChatThread.group([root, first, other, second])
        #expect(groups.map(\.id) == [root.id, other.id])
        #expect(groups.first?.replies.map(\.id) == [first.id, second.id])
    }
}
