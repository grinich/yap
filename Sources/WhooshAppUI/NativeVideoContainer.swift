import AppKit
import SwiftUI
import WhooshMeetings

/// Gallery and focus are separate SwiftUI branches, but share one SDK renderer.
/// Their updates and dismantles can overlap during a branch replacement.
struct NativeVideoContainer: View {
    var meeting: MeetingCoordinator
    var participantID: String
    var preservesRendererSize = false
    var fillsFrame = false

    var body: some View {
        GeometryReader { geometry in
            let size = Self.rendererSize(for: geometry.size, fillsFrame: fillsFrame)
            NativeRendererContainer(renderer: meeting.nativeVideoView(for: participantID),
                                    preservesRendererSize: preservesRendererSize)
                .frame(width: size.width, height: size.height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .clipped()
    }

    /// The SDK exposes a resizable view, not an aspect-fill switch. Center-crop
    /// its established 16:9 video canvas without changing the stream or user ID.
    /// Participant labels live outside this container and remain fully visible.
    static func rendererSize(for availableSize: CGSize, fillsFrame: Bool) -> CGSize {
        guard availableSize.width.isFinite, availableSize.height.isFinite,
              availableSize.width > 0, availableSize.height > 0 else { return .zero }
        guard fillsFrame else { return availableSize }
        let ratio = 16.0 / 9.0
        let width = max(availableSize.width, availableSize.height * ratio)
        return CGSize(width: width, height: width / ratio)
    }
}
