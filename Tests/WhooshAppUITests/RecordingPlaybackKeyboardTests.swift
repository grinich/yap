import AppKit
import AVKit
import Testing
@testable import WhooshAppUI

@Suite("Recording playback keyboard", .serialized) @MainActor
struct RecordingPlaybackKeyboardTests {
    @Test func spaceTogglesOnceAndConsumesNativePlayerRepeats() throws {
        let fixture = try RecordingKeyboardFixture()
        defer { fixture.cleanUp() }

        #expect(fixture.view.handleLocalEvent(try fixture.space()) == nil)
        #expect(fixture.toggleCount == 1)
        #expect(fixture.view.handleLocalEvent(try fixture.space(repeating: true)) == nil)
        #expect(fixture.toggleCount == 1)
        #expect(fixture.view.handleLocalEvent(try fixture.space()) == nil)
        #expect(fixture.toggleCount == 2)
    }

    @Test(arguments: [NSEvent.ModifierFlags.command, .control, .option, .shift, .function])
    func modifiedSpaceKeepsItsNormalMeaning(_ modifiers: NSEvent.ModifierFlags) throws {
        let fixture = try RecordingKeyboardFixture()
        defer { fixture.cleanUp() }
        let event = try fixture.space(modifiers: modifiers)
        #expect(fixture.view.handleLocalEvent(event) === event)
        #expect(fixture.toggleCount == 0)
    }

    @Test func textEntryAndControlsOutsidePlayerKeepSpace() throws {
        let fixture = try RecordingKeyboardFixture()
        defer { fixture.cleanUp() }
        let controls: [NSResponder] = [NSSearchField(), NSTextField(), NSTextView(), NSButton(), NSSlider()]
        for control in controls {
            fixture.window.reportedResponder = control
            let event = try fixture.space()
            #expect(fixture.view.handleLocalEvent(event) === event)
        }
        #expect(fixture.toggleCount == 0)
    }

    @Test func nativePlayerControlsUseOnlyTheRecordingToggle() throws {
        let fixture = try RecordingKeyboardFixture()
        defer { fixture.cleanUp() }
        let playerView = AVPlayerView()
        let button = NSButton()
        playerView.addSubview(button)
        fixture.window.reportedResponder = button

        #expect(fixture.view.handleLocalEvent(try fixture.space()) == nil)
        #expect(fixture.toggleCount == 1)
    }

    @Test func inactiveHiddenEmptyDetachedAndOtherWindowsAreUnaffected() throws {
        let fixture = try RecordingKeyboardFixture()
        defer { fixture.cleanUp() }
        let otherWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        let otherEvent = try fixture.space(window: otherWindow)
        #expect(fixture.view.handleLocalEvent(otherEvent) === otherEvent)

        let event = try fixture.space()
        fixture.window.reportsKey = false
        #expect(fixture.view.handleLocalEvent(event) === event)
        fixture.window.reportsKey = true
        fixture.view.isHidden = true
        #expect(fixture.view.handleLocalEvent(event) === event)
        fixture.view.isHidden = false
        fixture.view.hasRecording = { false }
        #expect(fixture.view.handleLocalEvent(event) === event)
        fixture.view.hasRecording = { true }
        fixture.view.removeFromSuperview()
        #expect(fixture.view.handleLocalEvent(event) === event)
        #expect(fixture.toggleCount == 0)
    }

    @Test func trackingMenusAndStoppedViewsDoNotConsumeSpace() throws {
        let fixture = try RecordingKeyboardFixture()
        defer { fixture.cleanUp() }
        let event = try fixture.space()
        let menu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(fixture.view.handleLocalEvent(event) === event)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(fixture.view.handleLocalEvent(event) == nil)
        fixture.view.stop()
        #expect(fixture.view.handleLocalEvent(event) === event)
        #expect(fixture.toggleCount == 1)
    }
}

@MainActor
private final class RecordingKeyboardFixture {
    let window: RecordingKeyboardWindow
    let view = RecordingPlaybackKeyboardView()
    var toggleCount = 0

    init() throws {
        _ = NSApplication.shared
        window = RecordingKeyboardWindow(contentRect: CGRect(x: 10_000, y: 10_000, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.hasRecording = { true }
        view.togglePlayback = { [weak self] in self?.toggleCount += 1 }
        try #require(window.contentView).addSubview(view)
    }

    func space(modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false, window: NSWindow? = nil) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: (window ?? self.window).windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeating, keyCode: 49))
    }

    func cleanUp() {
        view.stop()
        view.removeFromSuperview()
        window.close()
    }
}

@MainActor
private final class RecordingKeyboardWindow: NSWindow {
    var reportsKey = true
    var reportedResponder: NSResponder?
    override var isKeyWindow: Bool { reportsKey }
    override var firstResponder: NSResponder? { reportedResponder ?? super.firstResponder }
}
