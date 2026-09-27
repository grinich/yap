import SwiftUI
import YapMeetings

struct ReceivedShareTile: View {
    var meeting: MeetingCoordinator
    let share: ReceivedMeetingShare

    var body: some View {
        Button { meeting.selectReceivedShare(share.id) } label: {
            GeometryReader { geometry in
                let compact = geometry.size.height < 90
                let cornerRadius: CGFloat = compact ? 7 : 12
                let inset = min(compact ? 6.0 : 12.0, max(0, min(geometry.size.width, geometry.size.height)) * 0.1)
                let fontSize = max(1, min(compact ? 9.0 : 11.0, geometry.size.height * 0.2))
                ReceivedShareSurface(meeting: meeting, share: share, showsControls: false)
                    .allowsHitTesting(false)
                    .overlay(alignment: .bottom) {
                        HStack(spacing: compact ? 3 : 6) {
                            Text("\(share.ownerName)’s screen")
                                .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .foregroundStyle(.mint)
                        }
                        .font(.system(size: fontSize, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(inset)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.8)],
                                                   startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(.mint.opacity(0.45), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Expand \(share.ownerName)’s screen")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(share.ownerName)’s screen")
        .accessibilityHint("Expand shared screen")
    }
}
