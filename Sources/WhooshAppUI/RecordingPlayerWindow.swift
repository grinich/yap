import AppKit
import OSLog
import SwiftUI
import WhooshMeetings

/// Each recording occurrence owns an independent player and a normal macOS window.
@MainActor
final class RecordingPlayerWindowController: NSWindowController, NSWindowDelegate {
    private static let logger = Logger(subsystem: "app.whoosh.zoom", category: "recording-window")
    let playback: RecordingLibraryModel
    var onClose: (() -> Void)?

    init(playback: RecordingLibraryModel, meeting: ZoomRecordingMeeting) {
        self.playback = playback
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = meeting.topic.isEmpty ? "Recording" : meeting.topic
        window.subtitle = meeting.startTime.formatted(date: .abbreviated, time: .shortened)
        window.identifier = NSUserInterfaceItemIdentifier("recording-player-\(meeting.id)")
        window.contentMinSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = NSHostingView(rootView:
            RecordingPlayerView(model: playback, allowsWindowDragging: true)
                .frame(minWidth: 520, minHeight: 360)
                .background {
                    Color(nsColor: .windowBackgroundColor)
                        .contentShape(Rectangle())
                        .gesture(WindowDragGesture())
                        .allowsWindowActivationEvents()
                }
                .tint(WhooshTheme.accent))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(playback:meeting:)") }

    func present() {
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func windowWillClose(_ notification: Notification) {
        playback.stopPlayback()
        playback.chat.clear()
        onClose?()
        onClose = nil
    }

    func windowDidMove(_ notification: Notification) {
        guard let origin = window?.frame.origin else { return }
        Self.logger.debug("Recording window moved: x=\(origin.x), y=\(origin.y)")
    }
}
