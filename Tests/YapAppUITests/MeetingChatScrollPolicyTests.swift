import Foundation
import Testing
@testable import YapAppUI

@Suite("Chat scroll policy")
struct MeetingChatScrollPolicyTests {
    private let bottom = MeetingChatScrollGeometry(contentHeight: 1_000, visibleMinY: 600, visibleMaxY: 1_000)
    private let history = MeetingChatScrollGeometry(contentHeight: 1_000, visibleMinY: 100, visibleMaxY: 500)

    @Test func incomingMessagesFollowWithinFortyEightPointsOfTheBottom() {
        var policy = MeetingChatScrollPolicy()
        policy.geometryChanged(from: history, to: .init(contentHeight: 1_000, visibleMinY: 552, visibleMaxY: 952))
        let transitionResult1 = policy.receivedMessage(isFromSelf: false)
        #expect(transitionResult1)
        #expect(!policy.hasNewMessages)
    }

    @Test func readingHistoryPreservesPositionAndProvidesAJumpAction() {
        var policy = MeetingChatScrollPolicy()
        policy.geometryChanged(from: bottom, to: history)
        let transitionResult2 = policy.receivedMessage(isFromSelf: false)
        #expect(!transitionResult2)
        let transitionResult3 = policy.receivedMessage(isFromSelf: false)
        #expect(!transitionResult3)
        #expect(policy.hasNewMessages)
        policy.jumpToLatest()
        #expect(policy.followsLatest)
        #expect(!policy.hasNewMessages)
    }

    @Test func ownSentMessageReturnsToTheConversation() {
        var policy = MeetingChatScrollPolicy()
        policy.geometryChanged(from: bottom, to: history)
        let transitionResult4 = policy.receivedMessage(isFromSelf: true)
        #expect(transitionResult4)
        #expect(policy.followsLatest)
        #expect(!policy.hasNewMessages)
    }

    @Test func appendLayoutBeforeMessageCallbackDoesNotLoseBottomPinning() {
        var policy = MeetingChatScrollPolicy()
        policy.geometryChanged(from: bottom, to: .init(contentHeight: 1_200, visibleMinY: 600, visibleMaxY: 1_000))
        let transitionResult5 = policy.receivedMessage(isFromSelf: false)
        #expect(transitionResult5)
        policy.geometryChanged(from: bottom, to: history)
        policy.geometryChanged(from: history, to: .init(contentHeight: 1_200, visibleMinY: 100, visibleMaxY: 500))
        let transitionResult6 = policy.receivedMessage(isFromSelf: false)
        #expect(!transitionResult6)
    }

    @Test func reopeningStartsAtLatestAndClearsOldUnreadState() {
        var policy = MeetingChatScrollPolicy()
        let session = UUID()
        policy.reopen(sessionID: session)
        policy.geometryChanged(from: bottom, to: history)
        _ = policy.receivedMessage(isFromSelf: false)
        policy.reopen(sessionID: session)
        #expect(policy.followsLatest)
        #expect(!policy.hasNewMessages)
    }

    @Test func sessionChangesResetButRepeatedCurrentSessionDoesNotMoveAReader() {
        var policy = MeetingChatScrollPolicy()
        let session = UUID()
        policy.reopen(sessionID: session)
        policy.geometryChanged(from: bottom, to: history)
        let transitionResult7 = policy.synchronize(sessionID: session)
        #expect(!transitionResult7)
        #expect(!policy.followsLatest)
        let transitionResult8 = policy.synchronize(sessionID: UUID())
        #expect(transitionResult8)
        #expect(policy.followsLatest)
        #expect(!policy.hasNewMessages)
    }
}
