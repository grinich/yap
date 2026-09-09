import AppKit
import Observation
import YapMeetings

@MainActor @Observable
public final class YapMeetingPresentation {
    @ObservationIgnored public weak var mainWindow: NSWindow?
    var chatDraft = ""
    private(set) var isSending = false
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var sendID: UUID?

    public init() {}

    func synchronize(sessionID: UUID?) {
        if self.sessionID != sessionID {
            self.sessionID = sessionID
            chatDraft = ""
            isSending = false
            sendID = nil
        }
    }

    func sendMessage(in meeting: MeetingCoordinator) {
        guard !isSending, meeting.isConnected, meeting.capabilities.canChat, !meeting.isApplyingControl,
              !chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              chatDraft.count <= 4_000 else { return }
        let draft = chatDraft
        let session = meeting.sessionID
        let request = UUID()
        sendID = request
        isSending = true
        Task { [weak self] in
            await meeting.sendChat(text: draft, sessionID: session)
            guard let self, self.sendID == request else { return }
            if meeting.sessionID == session, meeting.lastError == nil, self.chatDraft == draft {
                self.chatDraft = ""
            }
            self.isSending = false
            self.sendID = nil
        }
    }
}
