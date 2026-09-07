import AppKit
import Testing
import WhooshMeetings
@testable import WhooshAppUI

@Suite("Replacement window close control", .serialized) @MainActor
struct WhooshWindowCloseTests {
    @Test(arguments: [true, false])
    func hiddenNativeButtonStillPreservesDelegateVetoAndCloseNotification(_ permitsClose: Bool) throws {
        let fixture = WindowCloseFixture()
        defer { fixture.cleanUp() }
        fixture.originalDelegate.permitsClose = permitsClose
        let button = try #require(fixture.closeButton)
        #expect(fixture.window.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(!fixture.window.isVisible)

        button.performClick(nil)

        #expect(fixture.originalDelegate.shouldCloseCount == 1)
        #expect(fixture.originalDelegate.willCloseCount == (permitsClose ? 1 : 0))
        #expect(!fixture.model.showLeaveConfirmation)
    }

    @Test func activeMeetingRequestsConfirmationWithoutClosingOrLeaving() async throws {
        let fixture = WindowCloseFixture()
        defer { fixture.cleanUp() }
        await fixture.model.meeting.join(url: URL(string: "https://zoom.us/j/12345678901")!, displayName: "Fixture")
        let sessionID = fixture.model.meeting.sessionID
        #expect(fixture.model.activeCall)

        let button = try #require(fixture.closeButton)
        button.performClick(nil)

        #expect(fixture.model.showLeaveConfirmation)
        #expect(fixture.model.meeting.sessionID == sessionID)
        #expect(fixture.model.meeting.isConnected)
        #expect(fixture.originalDelegate.shouldCloseCount == 0)
        #expect(fixture.originalDelegate.willCloseCount == 0)
    }

    @Test(arguments: [true, false])
    func commandWUsesTheSameLocalButtonAction(_ activeMeeting: Bool) async throws {
        let fixture = WindowCloseFixture()
        defer { fixture.cleanUp() }
        if activeMeeting {
            await fixture.model.meeting.join(url: URL(string: "https://zoom.us/j/12345678901")!, displayName: "Fixture")
        }
        let button = try #require(fixture.closeButton)
        let ordinaryW = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        let commandW = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        let handledOrdinaryW = button.performKeyEquivalent(with: ordinaryW)
        #expect(!handledOrdinaryW)
        #expect(fixture.originalDelegate.shouldCloseCount == 0)
        #expect(!fixture.model.showLeaveConfirmation)

        let handledCommandW = button.performKeyEquivalent(with: commandW)
        #expect(handledCommandW)
        #expect(fixture.model.showLeaveConfirmation == activeMeeting)
        #expect(fixture.originalDelegate.shouldCloseCount == (activeMeeting ? 0 : 1))
        #expect(fixture.originalDelegate.willCloseCount == (activeMeeting ? 0 : 1))
    }
}

@MainActor
private final class WindowCloseFixture {
    let suite = "WhooshWindowCloseTests.\(UUID())"
    let preferences: UserDefaults
    let model: WhooshModel
    let window: NSWindow
    let originalDelegate = CloseDelegate()
    let coordinator: WindowBehavior.Coordinator

    init() {
        _ = NSApplication.shared
        preferences = UserDefaults(suiteName: suite)!
        model = WhooshModel(preview: true, preferences: preferences,
                            meeting: MeetingCoordinator(driver: DemoMeetingDriver()),
                            reminders: WhooshReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = originalDelegate
        coordinator = WindowBehavior.Coordinator(model: model)
        coordinator.attach(to: window)
        coordinator.configureCloseButton(in: window, isVisible: true)
    }

    var closeButton: WhooshWindowCloseButton? {
        window.contentView?.superview?.subviews.compactMap { $0 as? WhooshWindowCloseButton }.first
    }

    func cleanUp() {
        coordinator.detach()
        window.delegate = nil
        window.close()
        preferences.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class CloseDelegate: NSObject, NSWindowDelegate {
    var permitsClose = true
    var shouldCloseCount = 0
    var willCloseCount = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldCloseCount += 1
        return permitsClose
    }
    func windowWillClose(_ notification: Notification) { willCloseCount += 1 }
}
