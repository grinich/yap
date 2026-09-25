import AppKit
import SwiftUI
import Testing
import YapMeetings
@testable import YapAppUI

/// The actual meeting view in an unordered window: no Zoom, capture, or posted input.
@Suite("Meeting controls and unread chat", .serialized) @MainActor
struct MeetingControlsVisibilityTests {
    @Test(arguments: [true, false])
    func unreadMessagesDoNotPinControlsAfterPointerExit(_ receivingShare: Bool) async throws {
        let fixture = MeetingControlsFixture()
        defer { fixture.cleanUp() }
        await fixture.model.hostMeeting()
        if receivingShare { fixture.model.showReceivedShareFixture() }
        await fixture.settle()
        #expect((fixture.model.meeting.selectedReceivedShare != nil) == receivingShare)
        let pointer = try #require(fixture.pointer)
        let driver = try #require(fixture.model.meeting.demoDriver)

        pointer.mouseEntered(with: try fixture.pointerEvent())
        await fixture.settle()
        try #require(fixture.model.areMeetingControlsVisible)
        driver.receiveFixtureMessage()
        driver.receiveFixtureAttachment()
        let unread = fixture.model.meeting.unreadChatMessageIDs
        try #require(!unread.isEmpty)

        pointer.mouseExited(with: try fixture.pointerEvent())
        await fixture.settle()
        #expect(!fixture.model.areMeetingControlsVisible)
        #expect(fixture.model.meeting.unreadChatMessageIDs == unread)

        // A new message outside the window must still notify without revealing
        // the whole header, share overlay, and call toolbar over the content.
        driver.receiveFixtureMessage()
        await fixture.settle()
        #expect(!fixture.model.areMeetingControlsVisible)
        #expect(fixture.model.meeting.unreadChatMessageIDs.count == unread.count + 1)

        fixture.model.sidebar = .chat
        await fixture.settle()
        #expect(!fixture.model.areMeetingControlsVisible)
        fixture.model.meeting.setChatBeingRead(true)
        await fixture.settle()
        #expect(fixture.model.meeting.unreadChatMessageIDs.isEmpty)
        #expect(!fixture.model.areMeetingControlsVisible)
        fixture.model.sidebar = nil
        await fixture.settle()
        #expect(!fixture.model.areMeetingControlsVisible)

        pointer.mouseEntered(with: try fixture.pointerEvent())
        await fixture.settle()
        #expect(fixture.model.areMeetingControlsVisible)
        pointer.mouseExited(with: try fixture.pointerEvent())
        await fixture.settle()
        #expect(!fixture.model.areMeetingControlsVisible)

        // Open native menus must keep their controls available even outside.
        let menu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        await fixture.settle()
        #expect(fixture.model.areMeetingControlsVisible)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        await fixture.settle()
        #expect(!fixture.model.areMeetingControlsVisible)
        await fixture.model.leaveMeeting()
    }
}

@MainActor private final class MeetingControlsFixture {
    let suite = "MeetingControlsVisibilityTests.\(UUID())"
    let preferences: UserDefaults
    let model: YapModel
    let window: ControlsFixtureWindow
    let hosting: NSHostingView<MeetingView>

    init() {
        _ = NSApplication.shared
        preferences = UserDefaults(suiteName: suite)!
        preferences.set("None", forKey: "chatNotificationSound")
        model = YapModel(preview: true, preferences: preferences,
            meeting: MeetingCoordinator(driver: DemoMeetingDriver()),
            reminders: YapReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}),
            loadGoogleConfiguration: { nil })
        window = ControlsFixtureWindow(contentRect: CGRect(x: 10_000, y: 10_000, width: 1_000, height: 740),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: MeetingView(model: model))
        window.contentView = hosting
    }

    var pointer: YapWindowPointerTrackingView? { findPointer(in: hosting) }
    private func findPointer(in view: NSView) -> YapWindowPointerTrackingView? {
        if let pointer = view as? YapWindowPointerTrackingView { return pointer }
        return view.subviews.lazy.compactMap { self.findPointer(in: $0) }.first
    }

    func pointerEvent() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 400, y: 300),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 0, pressure: 0))
    }

    func settle() async {
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func cleanUp() {
        pointer?.stop()
        window.contentView = nil
        window.close()
        preferences.removePersistentDomain(forName: suite)
    }
}

/// Supplies visibility for native tracking without ordering the window onscreen.
@MainActor private final class ControlsFixtureWindow: NSWindow {
    override var isVisible: Bool { true }
    override var isOnActiveSpace: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { [.visible] }
}
