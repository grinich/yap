import AppKit
import SwiftUI
import YapMeetings

struct ReceivedShareSurface: View {
    @Bindable var meeting: MeetingCoordinator
    let share: ReceivedMeetingShare
    var showsControls = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoomFactor: CGFloat = 1
    @State private var zoomCommand: ShareZoomCommand?

    var body: some View {
        NativeReceivedShareContainer(meeting: meeting, sourceID: share.id,
                                     ownerName: share.ownerName, zoomFactor: $zoomFactor,
                                     zoomCommand: zoomCommand)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .clipped()
            .overlay(alignment: .bottom) {
                HStack(spacing: 8) {
                    shareLabel
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .yapGlassSurface(cornerRadius: 12)
                    Spacer(minLength: 8)
                    zoomControls
                }
                .padding(12)
                .modifier(MeetingChromeVisibility(isVisible: showsControls || zoomFactor > 1.001,
                                                   reduceMotion: reduceMotion))
            }
    }

    private var shareLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle").foregroundStyle(.mint)
            Text("\(share.ownerName)’s screen")
                .font(.caption.weight(.medium)).lineLimit(1)
            if meeting.receivedShares.count > 1 {
                Menu {
                    ForEach(meeting.receivedShares) { source in
                        Button("\(source.ownerName) · \(source.title)") { meeting.selectReceivedShare(source.id) }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuIndicator(.hidden).menuStyle(.button).buttonStyle(.plain).fixedSize()
                .yapIconHover()
                .help("Choose shared content").accessibilityLabel("Choose shared content")
            }
        }
        .help(share.title + " · Shared by " + share.ownerName)
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { zoomCommand = .init(factor: max(1, zoomFactor / 1.25)) } label: {
                Image(systemName: "minus.magnifyingglass").frame(width: 28, height: 28)
            }
            .disabled(zoomFactor <= 1.001)
            .help("Zoom out").accessibilityLabel("Zoom out of shared screen")
            Text("\(Int((zoomFactor * 100).rounded()))%")
                .font(.caption.monospacedDigit()).frame(width: 42)
                .accessibilityLabel("Shared screen zoom")
                .accessibilityValue("\(Int((zoomFactor * 100).rounded())) percent")
            Button { zoomCommand = .init(factor: min(4, zoomFactor * 1.25)) } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 28, height: 28)
            }
            .disabled(zoomFactor >= 3.999)
            .help("Zoom in").accessibilityLabel("Zoom in on shared screen")
            Divider().frame(height: 16).padding(.horizontal, 4)
            Button("Fit") { zoomCommand = .init(factor: 1) }
                .frame(width: 30, height: 28)
                .disabled(zoomFactor <= 1.001)
                .help("Fit shared screen to window").accessibilityLabel("Fit shared screen to window")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .yapGlassSurface(cornerRadius: 12)
        .help("Pinch to zoom. When zoomed in, scroll with two fingers to pan.")
    }
}

private struct ShareZoomCommand {
    let id = UUID()
    let factor: CGFloat
}

private struct NativeReceivedShareContainer: NSViewRepresentable {
    var meeting: MeetingCoordinator
    var sourceID: String
    var ownerName: String
    @Binding var zoomFactor: CGFloat
    var zoomCommand: ShareZoomCommand?

    final class Coordinator { var lastCommandID: UUID? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ReceivedShareViewport { ReceivedShareViewport() }

    func updateNSView(_ container: ReceivedShareViewport, context: Context) {
        container.setAccessibilityLabel("Shared content from \(ownerName)")
        container.zoomDidChange = { factor in
            // AppKit layout can report a change during SwiftUI reconciliation.
            DispatchQueue.main.async { zoomFactor = factor }
        }
        container.display(meeting.nativeShareView(for: sourceID), sourceID: sourceID)
        if let zoomCommand, zoomCommand.id != context.coordinator.lastCommandID {
            context.coordinator.lastCommandID = zoomCommand.id
            container.zoom(to: zoomCommand.factor)
        }
    }

    static func dismantleNSView(_ container: ReceivedShareViewport, coordinator: Coordinator) {
        container.zoomDidChange = nil
        container.display(nil, sourceID: "")
    }
}
