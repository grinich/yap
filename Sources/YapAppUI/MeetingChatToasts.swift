import SwiftUI
import YapMeetings

/// Ephemeral incoming messages; opening chat never replays older history.
struct MeetingChatToasts: View {
    let meeting: MeetingCoordinator
    let isChatOpen: Bool
    let isSuppressed: Bool
    var maximumVisible = 3
    let openChat: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var seen: Set<UUID> = []
    @State private var visible: [UUID] = []

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(visible, id: \.self) { id in
                if let message = meeting.chatMessages.first(where: { $0.id == id }) {
                    Button(action: openChat) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.senderName + (message.recipient.kind == .participant ? " · Private" : "")).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
                            Text(message.text).font(.system(size: 13)).foregroundStyle(.white)
                                .lineLimit(3).multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .help("Open chat")
                    .accessibilityLabel("\(message.senderName) to \(message.recipient.label): \(message.text)")
                    .accessibilityHint("Opens meeting chat")
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .task {
                        do { try await Task.sleep(for: .seconds(15)) } catch { return }
                        withAnimation(.easeInOut(duration: 0.4)) { visible.removeAll { $0 == id } }
                    }
                }
            }
        }
        .frame(maxWidth: 280)
        .environment(\.colorScheme, .dark)
        .onAppear { seen = Set(meeting.chatMessages.map(\.id)) }
        .onChange(of: meeting.chatMessages.map(\.id)) { _, ids in
            let current = Set(ids)
            let incoming = meeting.chatMessages.filter { !seen.contains($0.id) && !$0.isFromSelf }
            seen = current
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35)) {
                visible.removeAll { !current.contains($0) }
                if !isChatOpen && !isSuppressed && meeting.isConnected {
                    visible = Array((visible + incoming.map(\.id)).suffix(maximumVisible))
                }
            }
        }
        .onChange(of: maximumVisible) { _, limit in visible = Array(visible.suffix(limit)) }
        .onChange(of: isChatOpen) { _, open in if open { visible = [] } }
        .onChange(of: isSuppressed) { _, suppressed in if suppressed { visible = [] } }
        .onChange(of: meeting.sessionID) { _, _ in
            visible = []; seen = Set(meeting.chatMessages.map(\.id))
        }
    }
}
