import AppKit
import SwiftUI
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Live chat scrolling", .serialized) @MainActor
struct MeetingChatScrollingUITests {
    @Test(arguments: [false, true]) func nativeKeyboardAndAccessibilityScrollingPreserveReadingPosition(accessibility: Bool) async throws {
        let fixture = await ChatScrollingFixture()
        defer { fixture.close() }
        let scroll = try await fixture.scrollView()
        // These AppKit action names describe content movement: down reveals
        // earlier messages. Invoke the actual scroll area's native AX action.
        if accessibility { scroll.accessibilityPerformAction(NSAccessibility.Action(rawValue: "AXScrollDownByPage")) }
        else { scroll.pageUp(nil) }
        await fixture.settle()
        let offset = scroll.contentView.bounds.minY
        #expect(fixture.bottomGap(scroll) > 200)
        fixture.receive("Leave this unread while I finish reading earlier messages.")
        await fixture.settle()
        #expect(abs(scroll.contentView.bounds.minY - offset) < 2)
        #expect(fixture.bottomGap(scroll) > 200)
        for _ in 0..<2 {
            if accessibility { scroll.accessibilityPerformAction(NSAccessibility.Action(rawValue: "AXScrollUpByPage")) }
            else { scroll.pageDown(nil) }
            await fixture.settle()
        }
        #expect(fixture.bottomGap(scroll) < 2)
        fixture.window.setContentSize(NSSize(width: 280, height: 480))
        await fixture.settle()
        #expect(fixture.bottomGap(scroll) < 2)
        fixture.receive("Follow this now that the reader has returned to the end.")
        await fixture.settle()
        #expect(fixture.bottomGap(scroll) < 2)
    }

    @Test func bottomReaderFollowsMessagesFilesAndRepliesToEarlierThreads() async throws {
        let fixture = await ChatScrollingFixture()
        defer { fixture.close() }
        let scroll = try await fixture.scrollView()
        #expect(fixture.bottomGap(scroll) < 2)
        fixture.receive("A new message with enough text to wrap onto a few lines in the chat sidebar.")
        await fixture.settle()
        #expect(fixture.bottomGap(scroll) < 2)
        fixture.driver.receiveFixtureAttachment()
        await fixture.settle()
        #expect(fixture.bottomGap(scroll) < 2)
        fixture.receive("A reply back in the first thread", threadID: "first-thread")
        await fixture.settle()
        #expect(fixture.bottomGap(scroll) < 2, "A new reply in an earlier thread must not pull a bottom reader back into history")
        for index in 0..<5 { fixture.receive("Message in a burst \(index)") }
        await fixture.settle()
        #expect(fixture.bottomGap(scroll) < 2)
        let latest = fixture.receive("The newest topic")
        fixture.receive("An expanded reply with enough detail to wrap across several lines and change height when the sidebar is resized.",
            threadID: latest.sdkID)
        await fixture.settle()
        #expect(fixture.bottomGap(scroll) < 2)
        fixture.window.setContentSize(NSSize(width: 280, height: 480))
        await fixture.settle()
        #expect(fixture.bottomGap(scroll) < 2, "Narrowing the chat and reflowing replies keeps its bottom visible")
        fixture.window.setContentSize(NSSize(width: 430, height: 700))
        await fixture.settle()
        #expect(fixture.bottomGap(scroll) < 2)
        let original = fixture.meeting.chatMessages.last!
        let edited = MeetingChatMessage(id: original.id, senderName: original.senderName,
            text: original.text + "\nAn additional paragraph added after the message arrived.\nAnd one more line.",
            date: original.date, sdkID: original.sdkID, threadID: original.threadID, isReply: true, canReply: true)
        fixture.driver.onEvent?(fixture.meeting.sessionID!, .messageUpdated(edited))
        await fixture.settle()
        #expect(fixture.bottomGap(scroll) < 2, "Edits that grow a message also stay pinned")
    }
}

@MainActor private final class ChatScrollingFixture {
    let driver = DemoMeetingDriver()
    let meeting: MeetingCoordinator
    let window: NSWindow
    let hosting: NSHostingView<MeetingChatView>
    var sequence = 0

    init() async {
        _ = NSApplication.shared
        meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "You", title: "Chat test")
        window = NSWindow(contentRect: NSRect(x: 10_000, y: 10_000, width: 360, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: MeetingChatView(meeting: meeting,
            presentation: YapMeetingPresentation(), isPreview: true))
        let session = meeting.sessionID!
        driver.onEvent?(session, .message(MeetingChatMessage(senderName: "Avery", text: "The first topic",
            sdkID: "first-thread", canReply: true)))
        for index in 0..<35 {
            driver.onEvent?(session, .message(MeetingChatMessage(senderName: "Avery",
                text: "Earlier message \(index) with a little context for the conversation.", sdkID: "history-\(index)", canReply: true)))
        }
        window.contentView = hosting
        await settle()
    }

    @discardableResult func receive(_ text: String, threadID: String? = nil, isFromSelf: Bool = false) -> MeetingChatMessage {
        sequence += 1
        let message = MeetingChatMessage(senderName: isFromSelf ? "You" : "Avery", text: text, isFromSelf: isFromSelf,
            sdkID: "incoming-\(sequence)", threadID: threadID, isReply: threadID != nil, canReply: true)
        driver.onEvent?(meeting.sessionID!, .message(message))
        return message
    }

    func settle() async {
        for _ in 0..<12 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func scrollView() async throws -> NSScrollView {
        await settle()
        func find(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { find(in: $0) }
        }
        return try #require(find(in: hosting).first { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 500 })
    }

    func bottomGap(_ scroll: NSScrollView) -> CGFloat {
        (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.maxY
    }

    func close() { window.contentView = nil; window.close() }

}
