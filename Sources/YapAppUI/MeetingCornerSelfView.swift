import AppKit
import SwiftUI
import YapMeetings

struct MeetingCornerSelfView: View {
    let participant: MeetingParticipant
    let meeting: MeetingCoordinator
    let compactHeight: Bool
    let showsControls: Bool
    @State private var corner: MeetingSelfViewLayout.Corner = .topRight
    @State private var translation: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let frame = MeetingSelfViewLayout.frame(in: geometry.size, aspectRatio: participant.tileAspectRatio,
                                                   compactHeight: compactHeight, corner: corner, showsControls: showsControls)
            ParticipantTile(participant: participant, meeting: meeting, allowsNativeVideo: true, showsInfo: false)
                .frame(width: frame.width, height: frame.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
                .overlay {
                    SelfViewDragSurface(onDrag: { translation = $0 }, onEnd: { offset in
                        let target = MeetingSelfViewLayout.nearestCorner(to: CGPoint(x: frame.midX + offset.width,
                                                                                   y: frame.midY + offset.height), in: geometry.size)
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                            corner = target
                            translation = .zero
                        }
                    })
                }
                .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
                .position(x: frame.midX + translation.width, y: frame.midY + translation.height)
                .animation(reduceMotion ? nil : MeetingChromeVisibility.animation(isVisible: showsControls), value: showsControls)
                .accessibilityLabel("Your self-view")
                .accessibilityHint("Drag to a corner")
                .accessibilityAction(named: "Move to top left") { corner = .topLeft }
                .accessibilityAction(named: "Move to top right") { corner = .topRight }
                .accessibilityAction(named: "Move to bottom left") { corner = .bottomLeft }
                .accessibilityAction(named: "Move to bottom right") { corner = .bottomRight }
        }
    }
}

private struct SelfViewDragSurface: NSViewRepresentable {
    var onDrag: (CGSize) -> Void
    var onEnd: (CGSize) -> Void
    func makeNSView(context: Context) -> SelfViewDragView { SelfViewDragView() }
    func updateNSView(_ view: SelfViewDragView, context: Context) {
        view.onDrag = onDrag; view.onEnd = onEnd
    }
}

private final class SelfViewDragView: NSView {
    var onDrag: ((CGSize) -> Void)?
    var onEnd: ((CGSize) -> Void)?
    private var start: NSPoint?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { start = event.locationInWindow }
    private func translation(_ event: NSEvent) -> CGSize {
        guard let start else { return .zero }
        return CGSize(width: event.locationInWindow.x - start.x, height: start.y - event.locationInWindow.y)
    }
    override func mouseDragged(with event: NSEvent) { onDrag?(translation(event)) }
    override func mouseUp(with event: NSEvent) { onEnd?(translation(event)); start = nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
