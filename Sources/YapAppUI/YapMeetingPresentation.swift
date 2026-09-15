import AppKit
import Observation
import YapMeetings

@MainActor @Observable
public final class YapMeetingPresentation {
    @ObservationIgnored public weak var mainWindow: NSWindow?
    var chatDraft = "" {
        didSet { if chatRuns.map(\.text).joined() != chatDraft { chatRuns = [] } }
    }
    var chatRuns: [MeetingChatTextRun] = []
    var chatRecipient: MeetingChatRecipient = .everyone
    var chatFocusRequest = UUID()
    var replyingTo: MeetingChatMessage?
    private(set) var isSending = false
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var sendID: UUID?

    public init() {}

    @discardableResult
    func quoteMessage(_ message: MeetingChatMessage) -> Bool {
        guard message.recipient.kind != .unavailable, message.recipient.kind != .attendeeAndPanelists else { return false }
        if message.recipient.kind != .everyone {
            guard let recipient = message.replyRecipient else { return false }
            chatRecipient = recipient
            replyingTo = nil
        }
        let quotation = message.text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        chatDraft += (chatDraft.isEmpty ? "" : "\n\n") + "\(message.senderName):\n\(quotation)\n\n"
        chatFocusRequest = UUID()
        return true
    }

    func synchronize(sessionID: UUID?) {
        if self.sessionID != sessionID {
            self.sessionID = sessionID
            chatDraft = ""
            chatRuns = []
            chatRecipient = .everyone
            chatFocusRequest = UUID()
            replyingTo = nil
            isSending = false
            sendID = nil
        }
    }

    func sendMessage(in meeting: MeetingCoordinator) {
        guard !isSending, meeting.isConnected, meeting.capabilities.canChat, !meeting.isApplyingControl,
              !chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              chatDraft.count <= 4_000 else { return }
        let draft = chatDraft
        let runs = chatRuns
        let recipient = chatRecipient
        let replyID = replyingTo?.id
        let session = meeting.sessionID
        let request = UUID()
        sendID = request
        isSending = true
        Task { [weak self] in
            await meeting.sendChat(text: draft, sessionID: session, replyingTo: replyID, recipient: recipient, runs: runs)
            guard let self, self.sendID == request else { return }
            if meeting.sessionID == session, meeting.lastError == nil, self.chatDraft == draft, self.chatRuns == runs,
               self.chatRecipient == recipient, self.replyingTo?.id == replyID {
                self.chatDraft = ""
                self.replyingTo = nil
            }
            self.isSending = false
            self.sendID = nil
        }
    }
}
