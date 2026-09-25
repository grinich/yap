import Foundation
import Testing
@testable import YapAppUI

@Suite("Chat scroll policy")
struct MeetingChatScrollPolicyTests {
    private let history = MeetingChatScrollGeometry(contentHeight: 1_000, visibleMinY: 100, visibleMaxY: 500)

    @Test func incomingMessagesFollowWithinFortyEightPointsOfTheBottom() {
        var policy = MeetingChatScrollPolicy()
        policy.userScrolled(to: .init(contentHeight: 1_000, visibleMinY: 552, visibleMaxY: 952))
        let transitionResult1 = policy.receivedMessage(isFromSelf: false)
        #expect(transitionResult1)
        #expect(!policy.hasNewMessages)
    }

    @Test func readingHistoryPreservesPositionAndProvidesAJumpAction() {
        var policy = MeetingChatScrollPolicy()
        policy.userScrolled(to: history)
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
        policy.userScrolled(to: history)
        let transitionResult4 = policy.receivedMessage(isFromSelf: true)
        #expect(transitionResult4)
        #expect(policy.followsLatest)
        #expect(!policy.hasNewMessages)
    }

    @Test func reopeningStartsAtLatestAndClearsOldUnreadState() {
        var policy = MeetingChatScrollPolicy()
        let session = UUID()
        policy.reopen(sessionID: session)
        policy.userScrolled(to: history)
        _ = policy.receivedMessage(isFromSelf: false)
        policy.reopen(sessionID: session)
        #expect(policy.followsLatest)
        #expect(!policy.hasNewMessages)
    }

    @Test func deliberateScrollDuringRemeasurementTakesPrecedence() {
        var policy = MeetingChatScrollPolicy()
        let remeasured = MeetingChatScrollGeometry(contentHeight: 1_200, visibleMinY: 400, visibleMaxY: 800)
        policy.userScrolled(to: remeasured)
        #expect(!policy.followsLatest)
        let shouldScroll = policy.receivedMessage(isFromSelf: false)
        #expect(!shouldScroll)
        policy.userScrolled(to: .init(contentHeight: 1_200, visibleMinY: 800, visibleMaxY: 1_200))
        #expect(policy.followsLatest)
        #expect(!policy.hasNewMessages)
    }

    @Test func ownReplyStaysWithHistoryWithoutUnreadNotice() {
        var policy = MeetingChatScrollPolicy()
        policy.userScrolled(to: history)
        let shouldScroll = policy.receivedMessage(isFromSelf: true, isReply: true)
        #expect(!shouldScroll)
        #expect(!policy.followsLatest)
        #expect(!policy.hasNewMessages)
    }

    @Test func nativeOffsetChangesPreserveAccessibilityAndKeyboardReadingIntent() {
        var policy = MeetingChatScrollPolicy()
        let bottom = MeetingChatScrollGeometry(contentHeight: 1_000, visibleMinY: 600, visibleMaxY: 1_000,
            contentWidth: 343, viewportWidth: 360)
        let earlier = MeetingChatScrollGeometry(contentHeight: 1_000, visibleMinY: 200, visibleMaxY: 600,
            contentWidth: 343, viewportWidth: 360)
        policy.geometryChanged(from: bottom, to: earlier)
        #expect(!policy.followsLatest)
        policy.geometryChanged(from: earlier, to: bottom)
        #expect(policy.followsLatest)
    }

    @Test func contentAndViewportRemeasurementDoNotCountAsNativeScrolling() {
        let bottom = MeetingChatScrollGeometry(contentHeight: 1_000, visibleMinY: 600, visibleMaxY: 1_000,
            contentWidth: 343, viewportWidth: 360)
        for changed in [
            MeetingChatScrollGeometry(contentHeight: 1_200, visibleMinY: 500, visibleMaxY: 900,
                contentWidth: 343, viewportWidth: 360),
            MeetingChatScrollGeometry(contentHeight: 1_000, visibleMinY: 500, visibleMaxY: 900,
                contentWidth: 263, viewportWidth: 280),
            MeetingChatScrollGeometry(contentHeight: 1_000, visibleMinY: 600, visibleMaxY: 850,
                contentWidth: 343, viewportWidth: 360)
        ] {
            var policy = MeetingChatScrollPolicy()
            policy.geometryChanged(from: bottom, to: changed)
            #expect(policy.followsLatest)
        }
    }

    @Test func sessionChangesResetButRepeatedCurrentSessionDoesNotMoveAReader() {
        var policy = MeetingChatScrollPolicy()
        let session = UUID()
        policy.reopen(sessionID: session)
        policy.userScrolled(to: history)
        let transitionResult7 = policy.synchronize(sessionID: session)
        #expect(!transitionResult7)
        #expect(!policy.followsLatest)
        let transitionResult8 = policy.synchronize(sessionID: UUID())
        #expect(transitionResult8)
        #expect(policy.followsLatest)
        #expect(!policy.hasNewMessages)
    }
}
