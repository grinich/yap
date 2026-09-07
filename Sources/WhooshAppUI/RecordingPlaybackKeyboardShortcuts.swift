import AppKit
import AVKit
import SwiftUI

/// Playback shortcuts belong to the visible recording in this window. Consuming
/// handled events prevents AVPlayerView from also toggling or seeking.
@MainActor
struct RecordingPlaybackKeyboardShortcuts: NSViewRepresentable {
    var model: RecordingLibraryModel

    func makeNSView(context: Context) -> RecordingPlaybackKeyboardView {
        let view = RecordingPlaybackKeyboardView()
        configure(view)
        return view
    }

    func updateNSView(_ view: RecordingPlaybackKeyboardView, context: Context) {
        configure(view)
    }

    private func configure(_ view: RecordingPlaybackKeyboardView) {
        view.hasRecording = { [weak model] in
            guard let model else { return false }
            return !model.isPreview && model.selectedFile != nil
        }
        view.togglePlayback = { [weak model] in
            guard let model, !model.isPreparing, model.playbackError == nil,
                  model.player.currentItem != nil else { return }
            if model.player.rate != 0 || model.player.timeControlStatus != .paused {
                model.player.pause()
            } else {
                // AVPlayer.play() resumes at defaultRate, preserving the speed
                // chosen through AVPlayerView's native playback menu.
                model.player.play()
            }
        }
        view.cycleSpeed = { [weak model] in model?.cyclePlaybackSpeed() }
        view.cycleView = { [weak model] in model?.cyclePlaybackView() }
        view.jogPlayback = { [weak model] seconds in model?.jogPlayback(by: seconds) }
    }

    static func dismantleNSView(_ view: RecordingPlaybackKeyboardView, coordinator: ()) {
        view.stop()
    }
}

@MainActor
final class RecordingPlaybackKeyboardView: NSView {
    var hasRecording: () -> Bool = { false }
    var togglePlayback: () -> Void = {}
    var cycleSpeed: () -> Void = {}
    var cycleView: () -> Void = {}
    var jogPlayback: (Double) -> Void = { _ in }
    private var monitor: Any?
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var stopped = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard !stopped, window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleLocalEvent(event) == nil
            }
            return consumed ? nil : event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(menuBegan),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEnded),
            name: NSMenu.didEndTrackingNotification, object: nil)
    }

    func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        guard !stopped, trackingMenus.isEmpty, !isHiddenOrHasHiddenAncestor,
              let window, window.isKeyWindow, window.isVisible, !window.isMiniaturized,
              event.window === window,
              window.attachedSheet == nil, NSApplication.shared.modalWindow == nil,
              event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let shortcut = Shortcut(event),
              !Self.focusedControlOwnsShortcut(window.firstResponder, shortcut: shortcut),
              hasRecording() else { return event }

        // Held arrows keep jogging; held toggles cycle only once. Consume their
        // repeats as well so a native AVPlayerView cannot handle them a second time.
        switch shortcut {
        case .space: if !event.isARepeat { togglePlayback() }
        case .speed: if !event.isARepeat { cycleSpeed() }
        case .view: if !event.isARepeat { cycleView() }
        case .fullscreen: if !event.isARepeat { window.toggleFullScreen(self) }
        case .backward: jogPlayback(-10)
        case .forward: jogPlayback(10)
        }
        return nil
    }

    private enum Shortcut: Equatable {
        case space, speed, view, fullscreen, backward, forward

        init?(_ event: NSEvent) {
            // AppKit supplies these flags for ordinary arrows, even without Fn.
            if event.keyCode == 123 { self = .backward; return }
            if event.keyCode == 124 { self = .forward; return }
            guard event.modifierFlags.intersection([.function, .numericPad]).isEmpty else { return nil }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " " where event.keyCode == 49: self = .space
            case "s": self = .speed
            case "v": self = .view
            case "f": self = .fullscreen
            default: return nil
            }
        }

        var isJog: Bool { self == .backward || self == .forward }
    }

    private static func focusedControlOwnsShortcut(_ responder: NSResponder?, shortcut: Shortcut) -> Bool {
        // Field editors and selectable chat transcripts are NSTextViews even
        // when the visible field/text was created by SwiftUI.
        if responder is NSText || responder is NSTextField { return true }
        guard let focusedView = responder as? NSView else { return false }
        var hasControl = false
        var hasArrowControl = false
        var ancestor: NSView? = focusedView
        while let view = ancestor {
            if view is NSText || view is NSTextField { return true }
            if view is AVPlayerView { return shortcut.isJog && hasArrowControl }
            if view is NSControl || view is NSCollectionView { hasControl = true }
            if view is NSSlider || view is NSStepper || view is NSSegmentedControl ||
                view is NSPopUpButton || view is NSTableView || view is NSCollectionView {
                hasArrowControl = true
            }
            ancestor = view.superview
        }
        // Preserve native control activation, list selection, and navigation.
        // In particular, focused AVPlayer sliders retain their own arrow keys.
        return hasControl
    }

    @objc private func menuBegan(_ notification: Notification) {
        if let menu = notification.object as? NSMenu { trackingMenus.insert(ObjectIdentifier(menu)) }
    }
    @objc private func menuEnded(_ notification: Notification) {
        if let menu = notification.object as? NSMenu { trackingMenus.remove(ObjectIdentifier(menu)) }
    }

    func stop() {
        stopped = true
        removeMonitor()
        hasRecording = { false }
        togglePlayback = {}
        cycleSpeed = {}
        cycleView = {}
        jogPlayback = { _ in }
    }

    private func removeMonitor() {
        NotificationCenter.default.removeObserver(self)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        trackingMenus.removeAll()
    }
}
