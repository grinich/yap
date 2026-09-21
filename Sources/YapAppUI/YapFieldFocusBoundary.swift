import AppKit
import SwiftUI

/// Tracks a text field without intercepting its clicks or another control’s
/// event. The callback clears the field’s SwiftUI focus without changing its text.
@MainActor
struct YapFieldFocusBoundary: NSViewRepresentable {
    var onOutsideClick: () -> Void

    func makeNSView(context: Context) -> YapFieldFocusBoundaryView {
        let view = YapFieldFocusBoundaryView()
        view.onOutsideClick = onOutsideClick
        return view
    }

    func updateNSView(_ view: YapFieldFocusBoundaryView, context: Context) {
        view.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ view: YapFieldFocusBoundaryView, coordinator: ()) {
        view.stop()
    }
}

@MainActor
final class YapFieldFocusBoundaryView: NSView {
    var onOutsideClick: () -> Void = {}
    private var monitor: Any?
    private var stopped = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard !stopped, window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, let window = self.window,
                      event.window === window, !self.isHiddenOrHasHiddenAncestor else { return }
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(point) { self.onOutsideClick() }
            }
            return event
        }
    }

    func stop() {
        stopped = true
        removeMonitor()
        onOutsideClick = {}
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
