import AppKit
import Foundation

/// Synthetic participants and messages for interface tests. No audio, camera,
/// capture, video decoding or network calls occur in this driver.
@MainActor
public final class DemoMeetingDriver: MeetingDriver, MeetingMediaDriver {
    public let isDemo = true
    public let capabilities = MeetingCapabilities(
        canJoin: true, canHost: true, canChat: true, canShare: true,
        supportsNativeVideo: false, confirmedLiveVideoLimit: nil, canReceiveShare: true)
    public var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    public private(set) var participantCount: Int
    public private(set) var visibleParticipantIDs: [String] = []
    private var sessionID: UUID?
    private var request: MeetingRequest?
    private var participants: [MeetingParticipant] = []
    private var recordingStatus: MeetingCloudRecordingStatus = .stopped
    private var fixtureMessageSequence = 0
    private var messages: [String: MeetingChatMessage] = [:]
    private var attachments: [String: MeetingChatAttachment] = [:]
    private var fixtureTransfers: [String: Task<Void, Never>] = [:]
    private var fixtureMediaTest: Task<Void, Never>?
    private var fixtureReceivedShares: [ReceivedMeetingShare] = []
    private var fixtureShareViews: [String: DemoReceivedShareView] = [:]
    private var selectedFixtureShareID: String?
    public var rejectNextControl = false
    public var onMediaDevicesChanged: (@MainActor (MeetingMediaState) -> Void)?
    private var mediaState = MeetingMediaState(isReady: true,
        microphones: [.init(id: "demo-mic", name: "Built-in Microphone (preview)", selected: true), .init(id: "demo-usb-mic", name: "USB Microphone (preview)")],
        speakers: [.init(id: "demo-speaker", name: "Built-in Speakers (preview)", selected: true), .init(id: "demo-headphones", name: "Headphones (preview)")],
        cameras: [.init(id: "demo-camera", name: "Built-in Camera (preview)", selected: true), .init(id: "demo-usb-camera", name: "USB Camera (preview)")],
        microphoneVolume: 70, speakerVolume: 50, canSetMicrophoneVolume: true, canSetSpeakerVolume: true)

    public init(participantCount: Int = 6) {
        self.participantCount = max(1, min(participantCount, 1_000))
    }

    public func connect(_ request: MeetingRequest, sessionID: UUID) async throws {
        guard self.sessionID == nil else { throw MeetingError.alreadyInMeeting }
        self.sessionID = sessionID
        self.request = request
        rebuildParticipants()
        onEvent?(sessionID, .status(.inMeeting))
        onEvent?(sessionID, .participants(participants))
        onEvent?(sessionID, .chatPolicy(MeetingChatPolicy(canPrivate: true, canWaitingRoom: request.isHost,
            canTransferFiles: true, maxFileBytes: 10 * 1_024 * 1_024)))
        mediaState.isInMeeting = true
        onMediaDevicesChanged?(mediaState)
        recordingStatus = .stopped
        onEvent?(sessionID, .cloudRecording(MeetingCloudRecording(status: recordingStatus,
            canControl: request.isHost, unavailableReason: request.isHost ? nil : "Only the host controls recording in this interface preview.")))
        onEvent?(sessionID, .message(MeetingChatMessage(senderName: "Yap demo",
            text: "This is a local demo. Participants, chat and sharing are simulated; no call is connected.")))
    }

    public func leave(sessionID: UUID, endForEveryone: Bool) async throws {
        try requireSession(sessionID)
        if endForEveryone && request?.isHost != true { throw MeetingError.hostRequired }
        stopFixtureScreenShares()
        self.sessionID = nil
        request = nil
        participants = []
        for task in fixtureTransfers.values { task.cancel() }
        fixtureTransfers = [:]; messages = [:]; attachments = [:]
        stopMediaTests()
        mediaState.isInMeeting = false
        onMediaDevicesChanged?(mediaState)
        visibleParticipantIDs = []
        onEvent?(sessionID, .status(.idle))
    }

    public func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws {
        try requireSession(sessionID)
        if !participants.isEmpty { participants[0].isMuted = muted }
        onEvent?(sessionID, .microphoneMuted(muted))
        onEvent?(sessionID, .participants(participants))
    }

    public func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws {
        try requireSession(sessionID)
        if !participants.isEmpty { participants[0].isCameraEnabled = enabled }
        onEvent?(sessionID, .cameraEnabled(enabled))
        onEvent?(sessionID, .participants(participants))
    }

    public func sendChat(text: String, sessionID: UUID) async throws {
        try await sendChat(MeetingChatDraft(text: text), sessionID: sessionID)
    }

    public func sendChat(_ draft: MeetingChatDraft, sessionID: UUID) async throws {
        try requireSession(sessionID); try acceptFixtureControl()
        guard draft.hasValidFormatting else { throw MeetingError.unavailable("Formatting doesn’t match the message.") }
        if draft.recipient.kind == .participant {
            guard participants.contains(where: { $0.id == draft.recipient.participantID && !$0.isSelf }) else {
                throw MeetingError.unavailable("This person has left the preview meeting.")
            }
        }
        fixtureMessageSequence += 1
        publish(MeetingChatMessage(senderName: request?.displayName ?? "You", text: draft.text,
            isFromSelf: true, sdkID: "fixture-sent-\(fixtureMessageSequence)", threadID: draft.replyToSDKID,
            isReply: draft.replyToSDKID != nil, canReply: true, senderID: "demo-self",
            recipient: draft.recipient, runs: draft.runs, canDelete: true), sessionID: sessionID)
    }

    public func sendChatReply(text: String, messageID: String, sessionID: UUID) async throws {
        guard let message = messages[messageID], let recipient = message.replyRecipient else {
            throw MeetingError.unavailable("This message can no longer be replied to.")
        }
        try await sendChat(MeetingChatDraft(text: text, recipient: recipient, replyToSDKID: messageID), sessionID: sessionID)
    }

    public func deleteChat(messageID: String, sessionID: UUID) async throws {
        try requireSession(sessionID); try acceptFixtureControl()
        guard let message = messages[messageID], message.isFromSelf, message.canDelete else {
            throw MeetingError.unavailable("This message can’t be deleted.")
        }
        messages.removeValue(forKey: messageID)
        onEvent?(sessionID, .messageRemoved(message.id))
    }

    public func sendChatFile(_ url: URL, recipient: MeetingChatRecipient, sessionID: UUID) async throws {
        try requireSession(sessionID); try acceptFixtureControl()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let attachment = MeetingChatAttachment(id: UUID().uuidString, name: url.lastPathComponent,
            bytes: UInt64(max(0, size)), senderName: request?.displayName ?? "You", recipient: recipient,
            isFromSelf: true, status: .transferring, progress: 0)
        attachments[attachment.id] = attachment
        onEvent?(sessionID, .chatAttachment(attachment))
        startFixtureTransfer(attachment.id, sessionID: sessionID)
    }

    public func receiveChatFile(_ id: String, to url: URL, sessionID: UUID) async throws {
        try requireSession(sessionID); try acceptFixtureControl()
        guard var attachment = attachments[id], !attachment.isFromSelf else { throw MeetingError.noMeeting }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw MeetingError.unavailable("Choose a new filename for this preview attachment.") }
        attachment.status = .transferring; attachment.progress = 0
        attachments[id] = attachment
        onEvent?(sessionID, .chatAttachment(attachment))
        startFixtureTransfer(id, sessionID: sessionID, destination: url)
    }

    public func cancelChatFile(_ id: String, sessionID: UUID) async throws {
        try requireSession(sessionID)
        guard var attachment = attachments[id] else { throw MeetingError.noMeeting }
        fixtureTransfers.removeValue(forKey: id)?.cancel()
        attachment.status = .cancelled
        attachments[id] = attachment
        onEvent?(sessionID, .chatAttachment(attachment))
    }

    public func setHandRaised(_ raised: Bool, sessionID: UUID) async throws {
        try requireSession(sessionID); try acceptFixtureControl()
        guard let index = participants.firstIndex(where: \.isSelf) else { throw MeetingError.noMeeting }
        participants[index].isHandRaised = raised
        onEvent?(sessionID, .participants(participants))
    }

    public func prepareMediaDevices() async throws -> MeetingMediaState {
        try acceptFixtureControl(); return mediaState
    }

    public func selectMediaDevice(_ deviceID: String, kind: MeetingMediaKind) async throws -> MeetingMediaState {
        try acceptFixtureControl()
        let devices = mediaState.devices(for: kind)
        guard devices.contains(where: { $0.id == deviceID }) else { throw MeetingError.unavailable("This preview device was disconnected.") }
        let updated = devices.map { MeetingMediaDevice(id: $0.id, name: $0.name, selected: $0.id == deviceID) }
        switch kind {
        case .microphone: mediaState.microphones = updated
        case .speaker: mediaState.speakers = updated
        case .camera: mediaState.cameras = updated
        }
        stopMediaTests(); return mediaState
    }

    public func setMediaVolume(_ volume: Int, kind: MeetingMediaKind) async throws -> MeetingMediaState {
        try acceptFixtureControl()
        switch kind {
        case .microphone: mediaState.microphoneVolume = min(100, max(0, volume))
        case .speaker: mediaState.speakerVolume = min(100, max(0, volume))
        case .camera: throw MeetingError.unavailable("Cameras do not have volume.")
        }
        onMediaDevicesChanged?(mediaState); return mediaState
    }

    public func setAutomaticMicrophoneVolume(_ enabled: Bool) async throws -> MeetingMediaState {
        try acceptFixtureControl(); mediaState.automaticMicrophoneVolume = enabled
        onMediaDevicesChanged?(mediaState); return mediaState
    }

    public func setMediaTest(_ kind: MeetingMediaKind, running: Bool) async throws -> MeetingMediaState {
        try acceptFixtureControl()
        stopMediaTests()
        if kind == .microphone { mediaState.microphoneTest = running ? "recording" : "idle" }
        if kind == .speaker { mediaState.speakerTestRunning = running }
        if running {
            fixtureMediaTest = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(kind == .microphone ? 5 : 10))
                    guard let self, !Task.isCancelled else { return }
                    if kind == .microphone {
                        self.mediaState.microphoneTest = "playing"
                        self.onMediaDevicesChanged?(self.mediaState)
                        try await Task.sleep(for: .seconds(5))
                    }
                    self.stopMediaTests()
                } catch {}
            }
        }
        onMediaDevicesChanged?(mediaState); return mediaState
    }

    public func stopMediaTests() {
        fixtureMediaTest?.cancel(); fixtureMediaTest = nil
        mediaState.microphoneTest = "idle"; mediaState.speakerTestRunning = false
        onMediaDevicesChanged?(mediaState)
    }

    private func acceptFixtureControl() throws {
        guard rejectNextControl else { return }
        rejectNextControl = false
        throw MeetingError.unavailable("The preview rejected this action. Try again.")
    }

    private func publish(_ message: MeetingChatMessage, sessionID: UUID) {
        if let sdkID = message.sdkID { messages[sdkID] = message }
        onEvent?(sessionID, .message(message))
    }

    private func startFixtureTransfer(_ id: String, sessionID: UUID, destination: URL? = nil) {
        fixtureTransfers[id]?.cancel()
        fixtureTransfers[id] = Task { [weak self] in
            do {
                for step in 1...4 {
                    try await Task.sleep(for: .milliseconds(750))
                    guard let self, self.sessionID == sessionID, !Task.isCancelled,
                          var attachment = self.attachments[id] else { return }
                    attachment.progress = Double(step) / 4
                    if step == 4 {
                        if let destination {
                            try Data("This is a local Yap chat attachment fixture.\n".utf8).write(to: destination, options: .withoutOverwriting)
                        }
                        attachment.status = .completed
                    }
                    self.attachments[id] = attachment
                    self.onEvent?(sessionID, .chatAttachment(attachment))
                }
                self?.fixtureTransfers.removeValue(forKey: id)
            } catch is CancellationError {} catch {
                guard let self, self.sessionID == sessionID, var attachment = self.attachments[id] else { return }
                attachment.status = .failed
                self.attachments[id] = attachment
                self.onEvent?(sessionID, .chatAttachment(attachment))
                self.fixtureTransfers.removeValue(forKey: id)
            }
        }
    }

    public func startShare(_ target: ShareTarget, sessionID: UUID) async throws {
        try requireSession(sessionID)
        let simulated = ShareTarget(id: target.id, title: target.title, kind: .demo)
        onEvent?(sessionID, .sharing(.sharing(simulated)))
    }

    public func stopShare(sessionID: UUID) async throws {
        try requireSession(sessionID)
        onEvent?(sessionID, .sharing(.idle))
    }

    /// Supplies two local vector documents to the normal received-share UI.
    /// They are never captured from a display or transmitted to a meeting.
    public func receiveFixtureScreenShares() {
        guard let sessionID else { return }
        let presenter = participants.first(where: { !$0.isSelf })
        fixtureReceivedShares = DemoReceivedShareDocument.allCases.map {
            ReceivedMeetingShare(id: $0.sourceID, ownerID: presenter?.id ?? "demo-presenter",
                ownerName: presenter?.name ?? "Preview presenter", title: $0.title)
        }
        onEvent?(sessionID, .receivedShares(fixtureReceivedShares))
    }

    public func stopFixtureScreenShares() {
        for view in fixtureShareViews.values { view.removeFromSuperview() }
        fixtureShareViews = [:]
        fixtureReceivedShares = []
        selectedFixtureShareID = nil
        if let sessionID { onEvent?(sessionID, .receivedShares([])) }
    }

    public func setSelectedReceivedShare(_ sourceID: String?) {
        let selection = fixtureReceivedShares.contains { $0.id == sourceID } ? sourceID : nil
        if selectedFixtureShareID != selection, let selectedFixtureShareID {
            fixtureShareViews[selectedFixtureShareID]?.removeFromSuperview()
        }
        selectedFixtureShareID = selection
    }

    public func nativeShareView(for sourceID: String) -> NSView? {
        guard sessionID != nil, selectedFixtureShareID == sourceID,
              fixtureReceivedShares.contains(where: { $0.id == sourceID }),
              let document = DemoReceivedShareDocument.allCases.first(where: { $0.sourceID == sourceID }) else { return nil }
        if let view = fixtureShareViews[sourceID] { return view }
        let view = DemoReceivedShareView(document: document)
        fixtureShareViews[sourceID] = view
        return view
    }

    public func startCloudRecording(sessionID: UUID) async throws { try setRecording(.recording, sessionID: sessionID) }
    public func pauseCloudRecording(sessionID: UUID) async throws { try setRecording(.paused, sessionID: sessionID) }
    public func resumeCloudRecording(sessionID: UUID) async throws { try setRecording(.recording, sessionID: sessionID) }
    public func stopCloudRecording(sessionID: UUID) async throws { try setRecording(.stopped, sessionID: sessionID) }

    private func setRecording(_ status: MeetingCloudRecordingStatus, sessionID: UUID) throws {
        try requireSession(sessionID)
        guard request?.isHost == true else { throw MeetingError.unavailable("Only the host controls recording in this interface preview.") }
        recordingStatus = status
        onEvent?(sessionID, .cloudRecording(MeetingCloudRecording(status: status, canControl: true)))
    }

    public func setVisibleParticipants(_ participantIDs: [String]) {
        visibleParticipantIDs = participantIDs
    }

    public func setParticipantCount(_ count: Int) {
        participantCount = max(1, min(count, 1_000))
        guard let sessionID else { return }
        rebuildParticipants()
        onEvent?(sessionID, .participants(participants))
    }

    /// Deterministic, explicitly local events for testing the real meeting UI.
    public func receiveFixtureMessage() {
        guard let sessionID else { return }
        fixtureMessageSequence += 1
        let name = participants.first(where: { !$0.isSelf })?.name ?? "Avery Chen"
        publish(MeetingChatMessage(senderName: name,
            text: "Preview message \(fixtureMessageSequence): the agenda is ready. https://example.com/agenda",
            sdkID: "fixture-incoming-\(fixtureMessageSequence)", canReply: true, senderID: "demo-1"), sessionID: sessionID)
    }

    public func receiveFixtureThread() {
        guard let sessionID else { return }
        fixtureMessageSequence += 1
        let rootID = "fixture-thread-\(fixtureMessageSequence)"
        publish(MeetingChatMessage(senderName: "Avery Chen",
            text: "Which design should we discuss first?", sdkID: rootID, canReply: true, senderID: "demo-1"), sessionID: sessionID)
        for (index, text) in ["Let’s start with the new calendar menu.", "Then the chat controls — I have a few ideas."].enumerated() {
            publish(MeetingChatMessage(senderName: index == 0 ? "Jordan Ellis" : "Sam Rivera",
                text: text, sdkID: "\(rootID)-reply-\(index)", threadID: rootID, isReply: true, canReply: true,
                senderID: "demo-\(index + 2)"), sessionID: sessionID)
        }
    }

    /// A scrollable history ending in a thread started by you, including mixed senders
    /// and wrapped replies. Exercises the same rows as a real incoming conversation.
    public func receiveFixtureChatHistory() {
        guard let sessionID else { return }
        for index in 0..<16 {
            fixtureMessageSequence += 1
            publish(MeetingChatMessage(senderName: index.isMultiple(of: 3) ? "Jordan Ellis" : "Avery Chen",
                text: index.isMultiple(of: 3) ? "A longer update for the team: the new calendar menu is ready to review, and the next step is checking how it feels in a busy meeting." : "The agenda is ready for item \(index + 1).",
                sdkID: "fixture-history-\(fixtureMessageSequence)", canReply: true, senderID: "demo-1"), sessionID: sessionID)
        }
        fixtureMessageSequence += 1
        let rootID = "fixture-history-thread-\(fixtureMessageSequence)"
        publish(MeetingChatMessage(senderName: request?.displayName ?? "You",
            text: "Can we put the new customer stories on the homepage?", isFromSelf: true,
            sdkID: rootID, canReply: true, senderID: "demo-self"), sessionID: sessionID)
        for (index, text) in ["Yes — they’re on the standard terms.", "I’ll send over the approved copy. There are a couple of longer quotes we can use, too.", "Perfect, thank you! 🙌"].enumerated() {
            let isSelf = index == 2
            publish(MeetingChatMessage(senderName: isSelf ? (request?.displayName ?? "You") : (index == 0 ? "Avery Chen" : "Jordan Ellis"),
                text: text, isFromSelf: isSelf, sdkID: "\(rootID)-reply-\(index)", threadID: rootID,
                isReply: true, canReply: true, senderID: isSelf ? "demo-self" : "demo-\(index + 1)"), sessionID: sessionID)
        }
    }

    public func receiveFixturePrivateMessage() {
        guard let sessionID else { return }
        fixtureMessageSequence += 1
        publish(MeetingChatMessage(senderName: "Avery Chen", text: "Can you review the notes privately after this call?",
            sdkID: "fixture-private-\(fixtureMessageSequence)", canReply: true, senderID: "demo-1",
            recipient: .init(kind: .participant, participantID: "demo-self", name: request?.displayName ?? "You")), sessionID: sessionID)
    }

    public func receiveFixtureFormatting() {
        guard let sessionID else { return }
        fixtureMessageSequence += 1
        let runs: [MeetingChatTextRun] = [.init(text: "Next steps 👋\n", bold: true),
            .init(text: "Review the calendar menu", italic: true), .init(text: " and "),
            .init(text: "read the notes", underline: true, link: "https://example.com/notes"),
            .init(text: ".\nOld deadline", strikethrough: true)]
        publish(MeetingChatMessage(senderName: "Jordan Ellis", text: runs.map(\.text).joined(),
            sdkID: "fixture-format-\(fixtureMessageSequence)", canReply: true, senderID: "demo-2", runs: runs), sessionID: sessionID)
    }

    public func receiveFixtureWaitingRoomMessage() {
        guard let sessionID else { return }
        fixtureMessageSequence += 1
        publish(MeetingChatMessage(senderName: "Riley Park", text: "Hi! I’m waiting to be admitted.",
            sdkID: "fixture-waiting-\(fixtureMessageSequence)", senderID: "demo-waiting-1",
            recipient: .waitingRoom), sessionID: sessionID)
    }

    public func setFixtureChatEnabled(_ enabled: Bool) {
        guard let sessionID else { return }
        onEvent?(sessionID, .chatPolicy(MeetingChatPolicy(canEveryone: enabled, canPrivate: enabled,
            canWaitingRoom: enabled && request?.isHost == true, canTransferFiles: enabled,
            maxFileBytes: 10 * 1_024 * 1_024)))
    }

    public func receiveFixtureAttachment() {
        guard let sessionID else { return }
        let attachment = MeetingChatAttachment(id: UUID().uuidString, name: "Preview meeting notes.txt", bytes: 44,
            senderName: "Avery Chen", isFromSelf: false)
        attachments[attachment.id] = attachment
        onEvent?(sessionID, .chatAttachment(attachment))
    }

    public func simulateFixtureDeviceDisconnect() {
        mediaState.microphones = [.init(id: "demo-mic", name: "Built-in Microphone (preview)", selected: true)]
        mediaState.speakers = [.init(id: "demo-speaker", name: "Built-in Speakers (preview)", selected: true)]
        mediaState.cameras = [.init(id: "demo-camera", name: "Built-in Camera (preview)", selected: true)]
        stopMediaTests()
    }

    private func requireSession(_ id: UUID) throws {
        guard id == sessionID else { throw MeetingError.noMeeting }
    }

    private func rebuildParticipants() {
        guard let request else { return }
        let local = participants.first(where: \.isSelf)
        let names = ["Avery Chen", "Jordan Ellis", "Sam Rivera", "Riley Park", "Morgan Lee", "Alex Reed",
                     "Taylor Kim", "Drew Brooks", "Casey Stone", "Quinn Patel", "Jamie Fox", "Robin Hart",
                     "Finley Lane", "Cameron Bell", "Dakota Gray", "Emery West", "Rowan Quinn", "Sage Liu"]
        participants = (0..<participantCount).map { index in
            if index == 0 {
                return MeetingParticipant(id: "demo-self", name: request.displayName, isSelf: true,
                    isHost: request.isHost, isMuted: local?.isMuted ?? request.microphoneMuted,
                    isCameraEnabled: local?.isCameraEnabled ?? request.cameraEnabled, avatarSeed: 0,
                    isHandRaised: local?.isHandRaised ?? false)
            }
            let cycle = (index - 1) / names.count
            let name = names[(index - 1) % names.count] + (cycle == 0 ? "" : " \(cycle + 1)")
            return MeetingParticipant(id: "demo-\(index)", name: name,
                isHost: !request.isHost && index == 1, isMuted: index != 1,
                isCameraEnabled: false, isSpeaking: index == 1, avatarSeed: index)
        }
    }
}
