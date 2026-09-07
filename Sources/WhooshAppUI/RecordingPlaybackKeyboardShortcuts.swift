import AppKit
import AVKit
import SwiftUI

/// Space belongs to the visible recording in this window. Consuming handled
/// events here keeps AVPlayerView from also toggling when its controls have focus.
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
            model?.selectedFile != nil && model?.player.currentItem != nil
        }
        view.togglePlayback = { [weak model] in
            guard let model, !model.isPreparing, model.playbackError == nil else { return }
            if model.player.rate != 0 || model.player.timeControlStatus != .paused {
                model.player.pause()
            } else {
                // AVPlayer.play() resumes at defaultRate, preserving the speed
                // chosen through AVPlayerView's native playback menu.
                model.player.play()
            }
        }
    }

    static func dismantleNSView(_ view: RecordingPlaybackKeyboardView, coordinator: ()) {
        view.stop()
    }
}

@MainActor
final class RecordingPlaybackKeyboardView: NSView {
    var hasRecording: () -> Bool = { false }
    var togglePlayback: () -> Void = {}
    private var monitor: Any?
    private var isTrackingMenu = false
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
        guard !stopped, !isTrackingMenu, !isHiddenOrHasHiddenAncestor,
              let window, window.isKeyWindow, event.window === window,
              window.attachedSheet == nil, NSApplication.shared.modalWindow == nil,
              event.type == .keyDown, event.keyCode == 49,
              event.charactersIgnoringModifiers == " ",
              event.modifierFlags.intersection([.command, .control, .option, .shift, .function]).isEmpty,
              !Self.focusedControlOwnsSpace(window.firstResponder), hasRecording() else { return event }

        // Suppress repeated keyDown events too, so holding Space cannot toggle
        // repeatedly through either this handler or the native AVPlayerView.
        if !event.isARepeat { togglePlayback() }
        return nil
    }

    private static func focusedControlOwnsSpace(_ responder: NSResponder?) -> Bool {
        // Field editors are NSTextViews even when the visible field is SwiftUI.
        if responder is NSText || responder is NSTextField { return true }
        guard let focusedView = responder as? NSView else { return false }
        var ancestor: NSView? = focusedView
        while let view = ancestor {
            if view is AVPlayerView { return false }
            ancestor = view.superview
        }
        // Preserve ordinary keyboard activation/editing of controls outside the
        // player, including the search field, video picker, and native buttons.
        return focusedView is NSControl
    }

    @objc private func menuBegan(_ notification: Notification) { isTrackingMenu = true }
    @objc private func menuEnded(_ notification: Notification) { isTrackingMenu = false }

    func stop() {
        stopped = true
        removeMonitor()
        hasRecording = { false }
        togglePlayback = {}
    }

    private func removeMonitor() {
        NotificationCenter.default.removeObserver(self)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isTrackingMenu = false
    }
}
