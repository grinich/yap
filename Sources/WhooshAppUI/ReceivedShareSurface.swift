import AppKit
import SwiftUI
import WhooshMeetings

struct ReceivedShareSurface: View {
    @Bindable var meeting: MeetingCoordinator
    let share: ReceivedMeetingShare

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(share.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("Shared by \(share.ownerName)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if meeting.receivedShares.count > 1 {
                    Menu {
                        ForEach(meeting.receivedShares) { source in
                            Button("\(source.ownerName) · \(source.title)") { meeting.selectReceivedShare(source.id) }
                        }
                    } label: {
                        Image(systemName: "rectangle.2.swap")
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
                    .whooshIconHover()
                    .help("Choose shared content").accessibilityLabel("Choose shared content")
                }
                Button { meeting.selectReceivedShare(nil) } label: {
                    Image(systemName: "person.2")
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).whooshIconHover()
                .help("Show people").accessibilityLabel("Show people instead of shared content")
            }
            .padding(12)
            NativeReceivedShareContainer(meeting: meeting, sourceID: share.id, ownerName: share.ownerName)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }
}

private struct NativeReceivedShareContainer: NSViewRepresentable {
    var meeting: MeetingCoordinator
    var sourceID: String
    var ownerName: String

    func makeNSView(context: Context) -> ReceivedShareHostView { ReceivedShareHostView() }

    func updateNSView(_ container: ReceivedShareHostView, context: Context) {
        container.setAccessibilityLabel("Shared content from \(ownerName)")
        container.display(meeting.nativeShareView(for: sourceID))
    }

    static func dismantleNSView(_ container: ReceivedShareHostView, coordinator: ()) {
        container.display(nil)
    }
}

/// Zoom owns the received stream and renderer. Removing this wrapper never
/// creates a second subscription or changes who is broadcasting.
private final class ReceivedShareHostView: NSView {
    private let placeholder = NSTextField(wrappingLabelWithString: "Waiting for shared content…")
    private weak var receivedView: NSView?

    init() {
        super.init(frame: .zero)
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func display(_ view: NSView?) {
        placeholder.isHidden = view != nil
        guard receivedView !== view else { return }
        receivedView?.removeFromSuperview()
        receivedView = view
        if let view {
            view.removeFromSuperview()
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
    }
}
