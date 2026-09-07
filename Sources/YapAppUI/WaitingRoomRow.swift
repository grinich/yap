import SwiftUI
import YapMeetings

struct WaitingRoomRow: View {
    @Bindable var meeting: MeetingCoordinator
    let participant: WaitingRoomParticipant
    @State private var isAdmitting = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.clock")
                .font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
                .frame(width: 30)
            Text(participant.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
            Spacer(minLength: 4)
            Button(isAdmitting ? "Admitting…" : "Admit", action: admit)
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
                .disabled(isAdmitting || !meeting.isConnected || !meeting.isHost || !meeting.capabilities.canAdmitParticipants || meeting.isApplyingControl)
                .accessibilityLabel("Admit \(participant.name) to the meeting")
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }

    private func admit() {
        guard !isAdmitting, meeting.isConnected, meeting.isHost, meeting.capabilities.canAdmitParticipants,
              !meeting.isApplyingControl, meeting.waitingRoomParticipants.contains(where: { $0.id == participant.id }) else { return }
        let sessionID = meeting.sessionID
        isAdmitting = true
        Task {
            await meeting.admitParticipant(participant.id)
            guard sessionID == meeting.sessionID else { return }
            isAdmitting = false
            // The waiting-room callback, not command acceptance, removes this row.
        }
    }
}
