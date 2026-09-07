import SwiftUI
import YapMeetings

/// Privacy indicators remain visible independently of the Chat/People sidebar.
/// Their wording and native details panels come from the meeting provider.
struct MeetingIndicatorsBar: View {
    @Bindable var meeting: MeetingCoordinator

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ForEach(meeting.meetingIndicators) { indicator in
                    indicatorButton(indicator).fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(meeting.meetingIndicators) { indicator in indicatorButton(indicator) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.bottom, 12)
    }

    private func indicatorButton(_ indicator: MeetingIndicator) -> some View {
        Button {
            Task { await meeting.showMeetingIndicator(indicator.id) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if indicator.id == "yap.zoom.app-signal" {
                    Image(systemName: "square.grid.2x2.fill").font(.system(size: 12))
                }
                Text(indicator.title).font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "info.circle").font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .yapIconHover(cornerRadius: 8)
        .disabled(!meeting.isConnected || meeting.isApplyingControl)
        .help("Details about \(indicator.title)")
        .accessibilityLabel("\(indicator.title). Show details")
    }
}
