import AppKit
import OSLog
import SwiftUI
import YapMeetings

/// Each recording occurrence owns an independent player and a normal macOS window.
@MainActor
final class RecordingPlayerWindowController: NSWindowController, NSWindowDelegate {
    private static let logger = Logger(subsystem: "app.yap.zoom", category: "recording-window")
    let playback: RecordingLibraryModel
    var onClose: (() -> Void)?
    private let closeButton = YapWindowCloseButton(frame: .zero)

    init(playback: RecordingLibraryModel, meeting: ZoomRecordingMeeting) {
        self.playback = playback
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = meeting.topic.isEmpty ? "Recording" : meeting.topic
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.identifier = NSUserInterfaceItemIdentifier("recording-player-\(meeting.id)")
        window.contentMinSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary]
        window.isMovableByWindowBackground = false
        window.contentView = NSHostingView(rootView:
            StandaloneRecordingPlayerView(playback: playback))
        window.center()
        super.init(window: window)
        window.delegate = self
        YapWindowLevel.shared.register(window)
        closeButton.target = self
        closeButton.action = #selector(closePlayer)
        closeButton.keyEquivalent = "w"
        closeButton.keyEquivalentModifierMask = [.command]
        configureCloseButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(playback:meeting:)") }

    private func configureCloseButton() {
        guard let window, let frameView = window.contentView?.superview else { return }
        if closeButton.superview !== frameView {
            closeButton.removeFromSuperview()
            frameView.addSubview(closeButton, positioned: .above, relativeTo: nil)
        }
        closeButton.frame = NSRect(x: 12, y: frameView.isFlipped ? 12 : frameView.bounds.height - 36,
                                   width: 24, height: 24)
        closeButton.autoresizingMask = [.maxXMargin, frameView.isFlipped ? .maxYMargin : .minYMargin]
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
    }

    @objc private func closePlayer() { window?.performClose(nil) }

    func windowDidResize(_ notification: Notification) { configureCloseButton() }
    func windowDidEnterFullScreen(_ notification: Notification) { configureCloseButton() }
    func windowDidExitFullScreen(_ notification: Notification) { configureCloseButton() }

    func present() {
        window?.deminiaturize(nil)
        showWindow(nil)
        configureCloseButton()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func windowWillClose(_ notification: Notification) {
        // Clear selection too: a closing SwiftUI view must not prepare another player item.
        playback.clear()
        onClose?()
        onClose = nil
    }

    func windowDidMove(_ notification: Notification) {
        guard let origin = window?.frame.origin else { return }
        Self.logger.debug("Recording window moved: x=\(origin.x), y=\(origin.y)")
    }
}

private struct StandaloneRecordingPlayerView: View {
    @Bindable var playback: RecordingLibraryModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        RecordingPlayerView(model: playback, headerLeadingInset: 54)
            .frame(minWidth: 520, minHeight: 360)
            .background {
                if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
                else { YapWindowBackdrop().allowsHitTesting(false).accessibilityHidden(true) }
            }
            .ignoresSafeArea()
            .tint(YapTheme.accent)
    }
}
