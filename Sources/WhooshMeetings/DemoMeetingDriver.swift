import Foundation

/// Synthetic participants and messages for interface tests. No audio, camera,
/// capture, video decoding or network calls occur in this driver.
@MainActor
public final class DemoMeetingDriver: MeetingDriver {
    public let isDemo = true
    public let capabilities = MeetingCapabilities(
        canJoin: true, canHost: true, canChat: true, canShare: true,
        supportsNativeVideo: false, confirmedLiveVideoLimit: nil)
    public var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    public private(set) var participantCount: Int
    public private(set) var visibleParticipantIDs: [String] = []
    private var sessionID: UUID?
    private var request: MeetingRequest?
    private var participants: [MeetingParticipant] = []
    private var recordingStatus: MeetingCloudRecordingStatus = .stopped

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
        recordingStatus = .stopped
        onEvent?(sessionID, .cloudRecording(MeetingCloudRecording(status: recordingStatus,
            canControl: request.isHost, unavailableReason: request.isHost ? nil : "Only the host controls recording in this interface preview.")))
        onEvent?(sessionID, .message(MeetingChatMessage(senderName: "Zooom demo",
            text: "This is a local demo. Participants, chat and sharing are simulated; no call is connected.")))
    }

    public func leave(sessionID: UUID, endForEveryone: Bool) async throws {
        try requireSession(sessionID)
        if endForEveryone && request?.isHost != true { throw MeetingError.hostRequired }
        self.sessionID = nil
        request = nil
        participants = []
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
        try requireSession(sessionID)
        onEvent?(sessionID, .message(MeetingChatMessage(senderName: request?.displayName ?? "You",
                                                        text: text, isFromSelf: true)))
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
                    isCameraEnabled: local?.isCameraEnabled ?? request.cameraEnabled, avatarSeed: 0)
            }
            let cycle = (index - 1) / names.count
            let name = names[(index - 1) % names.count] + (cycle == 0 ? "" : " \(cycle + 1)")
            return MeetingParticipant(id: "demo-\(index)", name: name,
                isHost: !request.isHost && index == 1, isMuted: index != 1,
                isCameraEnabled: false, isSpeaking: index == 1, avatarSeed: index)
        }
    }
}
