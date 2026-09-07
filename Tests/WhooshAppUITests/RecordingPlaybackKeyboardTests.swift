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

    @Test(arguments: ["s", "v", "S", "V"])
    func speedAndViewCycleOnceWithoutPassingRepeatsToThePlayer(_ key: String) throws {
        let fixture = try RecordingKeyboardFixture()
        defer { fixture.cleanUp() }
        let modifiers: NSEvent.ModifierFlags = key == key.uppercased() ? .capsLock : []
        #expect(fixture.view.handleLocalEvent(try fixture.key(key, modifiers: modifiers)) == nil)
        #expect(fixture.view.handleLocalEvent(try fixture.key(key, modifiers: modifiers, repeating: true)) == nil)
        #expect(fixture.speedCycleCount == (key.lowercased() == "s" ? 1 : 0))
        #expect(fixture.viewCycleCount == (key.lowercased() == "v" ? 1 : 0))
        #expect(fixture.actionCount == 1)
    }

    @Test(arguments: ["left", "right"], [NSEvent.ModifierFlags(), .function, .numericPad, [.function, .numericPad]])
    func bareArrowsJogOnEveryRepeatIncludingAppKitArrowFlags(_ key: String, flags: NSEvent.ModifierFlags) throws {
        let fixture = try RecordingKeyboardFixture()
        defer { fixture.cleanUp() }
        #expect(fixture.view.handleLocalEvent(try fixture.key(key, modifiers: flags)) == nil)
        #expect(fixture.view.handleLocalEvent(try fixture.key(key, modifiers: flags, repeating: true)) == nil)
        let distance: Double = key == "left" ? -10 : 10
        #expect(fixture.jogs == [distance, distance])
        #expect(fixture.actionCount == 2)
    }

    @Test(arguments: ["s", "v", "left", "right"], [NSEvent.ModifierFlags.command, .control, .option, .shift])
    func modifiedShortcutsKeepTheirNormalMeaning(_ key: String, modifiers: NSEvent.ModifierFlags) throws {
        let fixture = try RecordingKeyboardFixture()
        defer { fixture.cleanUp() }
        let event = try fixture.key(key, modifiers: modifiers)
        #expect(fixture.view.handleLocalEvent(event) === event)
        #expect(fixture.actionCount == 0)
    }

    @Test func unrelatedKeysKeyUpsAndFunctionModifiedLettersPassThrough() throws {
        let fixture = try RecordingKeyboardFixture()
        defer { fixture.cleanUp() }
        for key in ["q", "up", "down"] {
            let event = try fixture.key(key)
            #expect(fixture.view.handleLocalEvent(event) === event)
        }
        for key in [" ", "s", "v", "left", "right"] {
            let event = try fixture.key(key, type: .keyUp)
            #expect(fixture.view.handleLocalEvent(event) === event)
        }
        for key in ["s", "v"] {
            let event = try fixture.key(key, modifiers: .function)
            #expect(fixture.view.handleLocalEvent(event) === event)
        }
        #expect(fixture.actionCount == 0)
    }

    @Test func textEntrySelectionAndControlsOutsidePlayerKeepTheirKeys() throws {
        let fixture = try RecordingKeyboardFixture()
        defer { fixture.cleanUp() }
        let transcript = NSTextView()
        transcript.string = "A selected chat message"
        transcript.isEditable = false
        transcript.setSelectedRange(NSRange(location: 2, length: 8))
        let controls: [NSResponder] = [NSSearchField(), NSTextField(), NSTextView(), transcript,
                                      NSButton(), NSSlider(), NSPopUpButton(), NSCollectionView()]
        for control in controls {
            fixture.window.reportedResponder = control
            for key in [" ", "s", "v", "left", "right"] {
                let event = try fixture.key(key)
                #expect(fixture.view.handleLocalEvent(event) === event)
            }
        }
        #expect(fixture.actionCount == 0)
    }

    @Test func nativePlayerAndItsPlayButtonRoutePlaybackShortcutsExactlyOnce() throws {
        let fixture = try RecordingKeyboardFixture()
        defer { fixture.cleanUp() }
        let playerView = AVPlayerView()
        let button = NSButton()
        playerView.addSubview(button)
        for responder in [playerView, button] {
            fixture.window.reportedResponder = responder
            for key in [" ", "s", "v", "left", "right"] {
                #expect(fixture.view.handleLocalEvent(try fixture.key(key)) == nil)
            }
        }
        #expect(fixture.toggleCount == 2)
        #expect(fixture.speedCycleCount == 2)
        #expect(fixture.viewCycleCount == 2)
        #expect(fixture.jogs == [-10, 10, -10, 10])
    }

    @Test func nativePlayerSlidersKeepArrowNavigationButStillSupportSpeedAndViewShortcuts() throws {
        let fixture = try RecordingKeyboardFixture()
        defer { fixture.cleanUp() }
        let playerView = AVPlayerView()
        let slider = NSSlider()
        let focusedChild = NSView()
        slider.addSubview(focusedChild)
        playerView.addSubview(slider)
        for responder in [slider, focusedChild] {
            fixture.window.reportedResponder = responder
            for key in ["left", "right"] {
                let event = try fixture.key(key, modifiers: [.function, .numericPad])
                #expect(fixture.view.handleLocalEvent(event) === event)
            }
            #expect(fixture.view.handleLocalEvent(try fixture.key("s")) == nil)
            #expect(fixture.view.handleLocalEvent(try fixture.key("v")) == nil)
        }
        #expect(fixture.jogs.isEmpty)
        #expect(fixture.speedCycleCount == 2)
        #expect(fixture.viewCycleCount == 2)
    }

    @Test func inactiveHiddenEmptyDetachedAndOtherWindowsAreUnaffected() throws {
        let fixture = try RecordingKeyboardFixture()
        defer { fixture.cleanUp() }
        let otherWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        for key in [" ", "s", "v", "left", "right"] {
            let otherEvent = try fixture.key(key, window: otherWindow)
            #expect(fixture.view.handleLocalEvent(otherEvent) === otherEvent)
        }
        let events = try [" ", "s", "v", "left", "right"].map { try fixture.key($0) }
        func expectPassThrough() {
            for event in events { #expect(fixture.view.handleLocalEvent(event) === event) }
        }
        fixture.window.reportsKey = false
        expectPassThrough()
        fixture.window.reportsKey = true
        fixture.window.reportsVisible = false
        expectPassThrough()
        fixture.window.reportsVisible = true
        fixture.window.reportsMiniaturized = true
        expectPassThrough()
        fixture.window.reportsMiniaturized = false
        fixture.view.isHidden = true
        expectPassThrough()
        fixture.view.isHidden = false
        fixture.view.hasRecording = { false }
        expectPassThrough()
        fixture.view.hasRecording = { true }
        fixture.view.removeFromSuperview()
        expectPassThrough()
        #expect(fixture.actionCount == 0)
    }

    @Test func sheetsNestedMenusAndStoppedViewsDoNotConsumeShortcuts() throws {
        let fixture = try RecordingKeyboardFixture()
        defer { fixture.cleanUp() }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { fixture.window.reportedSheet = nil; sheet.close() }
        let events = try [" ", "s", "v", "left", "right"].map { try fixture.key($0) }
        func expectPassThrough() {
            for event in events { #expect(fixture.view.handleLocalEvent(event) === event) }
        }
        fixture.window.reportedSheet = sheet
        expectPassThrough()
        fixture.window.reportedSheet = nil
        let menu = NSMenu()
        let submenu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: submenu)
        expectPassThrough()
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: submenu)
        expectPassThrough()
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(fixture.view.handleLocalEvent(try fixture.space()) == nil)
        fixture.view.stop()
        expectPassThrough()
        #expect(fixture.actionCount == 1)
    }
}

@MainActor
private final class RecordingKeyboardFixture {
    let window: RecordingKeyboardWindow
    let view = RecordingPlaybackKeyboardView()
    var toggleCount = 0
    var speedCycleCount = 0
    var viewCycleCount = 0
    var jogs: [Double] = []
    var actionCount: Int { toggleCount + speedCycleCount + viewCycleCount + jogs.count }

    init() throws {
        _ = NSApplication.shared
        window = RecordingKeyboardWindow(contentRect: CGRect(x: 10_000, y: 10_000, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.hasRecording = { true }
        view.togglePlayback = { [weak self] in self?.toggleCount += 1 }
        view.cycleSpeed = { [weak self] in self?.speedCycleCount += 1 }
        view.cycleView = { [weak self] in self?.viewCycleCount += 1 }
        view.jogPlayback = { [weak self] seconds in self?.jogs.append(seconds) }
        try #require(window.contentView).addSubview(view)
    }

    func space(modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false, window: NSWindow? = nil) throws -> NSEvent {
        try key(" ", modifiers: modifiers, repeating: repeating, window: window)
    }

    func key(_ key: String, modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false,
             window: NSWindow? = nil, type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        let keys: [String: (UInt16, String)] = [" ": (49, " "), "s": (1, key), "v": (9, key), "q": (12, "q"),
            "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "up": (126, "\u{F700}"), "down": (125, "\u{F701}")]
        let (keyCode, characters) = try #require(keys[key.lowercased()])
        return try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: (window ?? self.window).windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: keyCode))
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
    var reportsVisible = true
    var reportsMiniaturized = false
    var reportedResponder: NSResponder?
    var reportedSheet: NSWindow?
    override var isKeyWindow: Bool { reportsKey }
    override var isVisible: Bool { reportsVisible }
    override var isMiniaturized: Bool { reportsMiniaturized }
    override var attachedSheet: NSWindow? { reportedSheet }
    override var firstResponder: NSResponder? { reportedResponder ?? super.firstResponder }
}
