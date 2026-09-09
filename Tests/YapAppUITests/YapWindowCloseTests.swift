import AppKit
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Replacement window close control", .serialized) @MainActor
struct YapWindowCloseTests {
    @Test(arguments: [true, false])
    func welcomeCloseHidesTheRetainedWindowEvenWhenTheFrameworkVetoesClosing(_ permitsClose: Bool) throws {
        let fixture = WindowCloseFixture()
        defer { fixture.cleanUp() }
        fixture.originalDelegate.permitsClose = permitsClose
        let button = try #require(fixture.closeButton)
        #expect(fixture.window.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(fixture.window.hideCount == 0)
        #expect(button.acceptsFirstMouse(for: nil))
        #expect(!button.mouseDownCanMoveWindow)

        button.performClick(nil)

        #expect(!fixture.window.isVisible)
        #expect(fixture.window.hideCount == 1)
        #expect(fixture.model.meetingPresentation.mainWindow === fixture.window)
        #expect(fixture.originalDelegate.shouldCloseCount == 0)
        #expect(fixture.originalDelegate.willCloseCount == 0)
        #expect(!fixture.model.showLeaveConfirmation)
        button.performClick(nil)
        #expect(fixture.window.hideCount == 2)
    }

    @Test func pinControlSitsBesideCloseAndFollowsChromeVisibility() throws {
        let fixture = WindowCloseFixture()
        defer { fixture.cleanUp() }
        let close = try #require(fixture.closeButton)
        let pin = try #require(fixture.window.contentView?.superview?.subviews.compactMap { $0 as? YapWindowPinButton }.first)
        #expect(pin.frame == close.frame.offsetBy(dx: 24, dy: 0))
        #expect(pin.frame.size == CGSize(width: 24, height: 24))
        fixture.coordinator.configureCloseButton(in: fixture.window, isVisible: false)
        #expect(!pin.isEnabled)
        fixture.coordinator.configureCloseButton(in: fixture.window, isVisible: true)
        #expect(pin.isEnabled)
        #expect(fixture.window.hideCount == 0)
    }

    @Test func activeMeetingRequestsConfirmationWithoutClosingOrLeaving() async throws {
        let fixture = WindowCloseFixture()
        defer { fixture.cleanUp() }
        fixture.model.askBeforeLeavingMeeting = true
        await fixture.model.meeting.join(url: URL(string: "https://zoom.us/j/12345678901")!, displayName: "Fixture")
        let sessionID = fixture.model.meeting.sessionID
        #expect(fixture.model.activeCall)

        let button = try #require(fixture.closeButton)
        button.performClick(nil)

        #expect(fixture.model.showLeaveConfirmation)
        #expect(fixture.model.meeting.sessionID == sessionID)
        #expect(fixture.model.meeting.isConnected)
        #expect(fixture.window.hideCount == 0)
        #expect(fixture.originalDelegate.shouldCloseCount == 0)
        #expect(fixture.originalDelegate.willCloseCount == 0)
    }

    @Test(arguments: [true, false], [true, false])
    func commandWUsesTheSameLocalButtonAction(_ activeMeeting: Bool, _ asksBeforeLeaving: Bool) async throws {
        let fixture = WindowCloseFixture()
        defer { fixture.cleanUp() }
        fixture.model.askBeforeLeavingMeeting = asksBeforeLeaving
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
        #expect(fixture.model.showLeaveConfirmation == (activeMeeting && asksBeforeLeaving))
        if activeMeeting && !asksBeforeLeaving {
            for _ in 0..<100 where fixture.model.activeCall { await Task.yield() }
            #expect(!fixture.model.activeCall)
        }
        #expect(fixture.window.hideCount == (activeMeeting ? 0 : 1))
        #expect(fixture.originalDelegate.shouldCloseCount == 0)
        #expect(fixture.originalDelegate.willCloseCount == 0)
    }

    @Test func retainedWindowCloseArmsOneRecordingsRefreshOnReveal() throws {
        let fixture = WindowCloseFixture()
        defer { fixture.cleanUp() }
        let probe = RecordingsRevealProbe()
        let observer = NotificationCenter.default.addObserver(forName: yapMainWindowWillHide,
            object: fixture.model, queue: .main) { _ in
                MainActor.assumeIsolated { probe.reveal.windowWillHide() }
            }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(!probe.consumeReveal())
        try #require(fixture.closeButton).performClick(nil)
        #expect(fixture.window.hideCount == 1)
        #expect(!probe.consumeReveal(isVisible: false))
        #expect(probe.consumeReveal())
        #expect(!probe.consumeReveal())
        #expect(!probe.consumeReveal())

        // A later real close permits a new refresh; repeated focus events do not.
        try #require(fixture.closeButton).performClick(nil)
        #expect(probe.consumeReveal())
    }

    @Test func recordingsRevealWaitsUntilTheWindowIsActuallyAvailable() {
        let probe = RecordingsRevealProbe()
        probe.reveal.windowWillHide()
        #expect(!probe.consumeReveal(isVisible: false))
        #expect(!probe.consumeReveal(isMiniaturized: true))
        #expect(!probe.consumeReveal(isApplicationHidden: true))
        #expect(probe.consumeReveal())
        // De-miniaturize, key-window and app-activation notifications can overlap.
        #expect(!probe.consumeReveal())
    }

    @Test(arguments: ["closed", "preview", "account-busy", "active-call"])
    func ineligibleRecordingsRevealDoesNotTurnLaterFocusIntoARefresh(_ reason: String) {
        let probe = RecordingsRevealProbe()
        probe.reveal.windowWillHide()
        #expect(!probe.consumeReveal(recordingsPresented: reason != "closed",
            isPreview: reason == "preview", isAccountBusy: reason == "account-busy",
            hasActiveCall: reason == "active-call"))
        // The view task handles becoming eligible; Settings/sheet focus does not.
        #expect(!probe.consumeReveal())
        probe.reveal.windowWillHide()
        #expect(probe.consumeReveal())
    }
}

@MainActor
private final class RecordingsRevealProbe {
    var reveal = YapRecordingsWindowReveal()

    func consumeReveal(isVisible: Bool = true, isMiniaturized: Bool = false,
                       isApplicationHidden: Bool = false, recordingsPresented: Bool = true,
                       isPreview: Bool = false, isAccountBusy: Bool = false,
                       hasActiveCall: Bool = false) -> Bool {
        reveal.shouldRefresh(isVisible: isVisible, isMiniaturized: isMiniaturized,
            isApplicationHidden: isApplicationHidden, recordingsPresented: recordingsPresented,
            isPreview: isPreview, isAccountBusy: isAccountBusy, hasActiveCall: hasActiveCall)
    }
}

@MainActor
private final class WindowCloseFixture {
    let suite = "YapWindowCloseTests.\(UUID())"
    let preferences: UserDefaults
    let model: YapModel
    let window: CloseTrackingWindow
    let originalDelegate = CloseDelegate()
    let coordinator: WindowBehavior.Coordinator

    init() {
        _ = NSApplication.shared
        preferences = UserDefaults(suiteName: suite)!
        model = YapModel(preview: true, preferences: preferences,
                            meeting: MeetingCoordinator(driver: DemoMeetingDriver()),
                            reminders: YapReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}))
        window = CloseTrackingWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = originalDelegate
        coordinator = WindowBehavior.Coordinator(model: model)
        coordinator.attach(to: window)
        coordinator.configureCloseButton(in: window, isVisible: true)
    }

    var closeButton: YapWindowCloseButton? {
        window.contentView?.superview?.subviews.compactMap { $0 as? YapWindowCloseButton }.first
    }

    func cleanUp() {
        coordinator.detach()
        window.delegate = nil
        window.close()
        preferences.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class CloseTrackingWindow: NSWindow {
    private(set) var hideCount = 0
    override func orderOut(_ sender: Any?) {
        hideCount += 1
        super.orderOut(sender)
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
