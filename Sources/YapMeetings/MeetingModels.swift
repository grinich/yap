import Foundation

public enum MeetingLayout: String, CaseIterable, Sendable {
    case gallery, activeSpeaker
    public var title: String { self == .gallery ? "Gallery View" : "Active Speaker" }
    public var symbol: String { self == .gallery ? "square.grid.2x2" : "rectangle.inset.filled" }
}

public enum MeetingStatus: String, Sendable, Equatable {
    case idle, connecting, waitingForHost, waitingRoom, inMeeting, reconnecting, leaving, failed

    public var isActive: Bool {
        switch self {
        case .connecting, .waitingForHost, .waitingRoom, .inMeeting, .reconnecting, .leaving: true
        case .idle, .failed: false
        }
    }

    public var label: String {
        switch self {
        case .idle: "Ready"
        case .connecting: "Joining…"
        case .waitingForHost: "Waiting for the host"
        case .waitingRoom: "In the waiting room"
        case .inMeeting: "In meeting"
        case .reconnecting: "Reconnecting…"
        case .leaving: "Leaving…"
        case .failed: "Couldn’t connect"
        }
    }
}

/// A local image supplied by the Meeting SDK. The revision changes even when
/// Zoom replaces the image at the same path during a meeting.
public struct MeetingAvatar: Sendable, Hashable {
    public let path: String
    public let revision: Int

    public init?(path: String, revision: Int = 0) {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\0") else { return nil }
        self.path = path
        self.revision = revision
    }
}

public struct MeetingVideoSize: Sendable, Equatable {
    public let width: Double
    public let height: Double
    public var aspectRatio: Double { width / height }

    public init?(width: Double, height: Double) {
        guard width.isFinite, height.isFinite, (1...16_384).contains(width),
              (1...16_384).contains(height), (0.125...8).contains(width / height) else { return nil }
        self.width = width
        self.height = height
    }
}

public struct MeetingParticipant: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var isSelf: Bool
    public var isHost: Bool
    public var isMuted: Bool
    public var isCameraEnabled: Bool
    public var isSpeaking: Bool
    public let avatarSeed: Int
    public var avatar: MeetingAvatar?
    public var videoSize: MeetingVideoSize?
    public var tileAspectRatio: Double { isCameraEnabled ? videoSize?.aspectRatio ?? 16 / 9 : 16 / 9 }

    public init(id: String, name: String, isSelf: Bool = false, isHost: Bool = false,
                isMuted: Bool = true, isCameraEnabled: Bool = false,
                isSpeaking: Bool = false, avatarSeed: Int = 0, avatar: MeetingAvatar? = nil,
                videoSize: MeetingVideoSize? = nil) {
        self.id = id
        self.name = name
        self.isSelf = isSelf
        self.isHost = isHost
        self.isMuted = isMuted
        self.isCameraEnabled = isCameraEnabled
        self.isSpeaking = isSpeaking
        self.avatarSeed = avatarSeed
        self.avatar = avatar
        self.videoSize = videoSize
    }

    public var initials: String {
        name.split(whereSeparator: { $0.isWhitespace }).prefix(2)
            .compactMap(\.first).map(String.init).joined().uppercased()
    }
}

public struct MeetingChatMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let senderName: String
    public let text: String
    public let date: Date
    public let isFromSelf: Bool

    public init(id: UUID = UUID(), senderName: String, text: String,
                date: Date = Date(), isFromSelf: Bool = false) {
        self.id = id
        self.senderName = senderName
        self.text = text
        self.date = date
        self.isFromSelf = isFromSelf
    }
}

public struct MeetingChatLegalNotice: Sendable, Equatable {
    public let prompt: String
    public let explanation: String

    public init(prompt: String, explanation: String) {
        self.prompt = prompt
        self.explanation = explanation
    }
}

/// SDK settings and observed transmission are separate: preferring HD does not
/// guarantee that the account, camera or current connection is sending HD.
public struct MeetingVideoQuality: Sendable, Equatable {
    public let requestsHD: Bool
    public let sendWidth: Int?
    public let sendHeight: Int?
    public let sendFPS: Int?

    public init(requestsHD: Bool, sendWidth: Int? = nil, sendHeight: Int? = nil, sendFPS: Int? = nil) {
        self.requestsHD = requestsHD
        let valid = (sendWidth ?? 0) > 0 && (sendHeight ?? 0) > 0
        self.sendWidth = valid ? sendWidth : nil
        self.sendHeight = valid ? sendHeight : nil
        self.sendFPS = valid && (sendFPS ?? 0) > 0 ? sendFPS : nil
    }
}

/// Visible while supplied by Zoom. Selecting it opens the SDK's authoritative details panel.
public struct MeetingIndicator: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public struct ShareTarget: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case window, display, demo }
    public let id: String
    public let title: String
    public let kind: Kind

    public init(id: String, title: String, kind: Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

public struct WaitingRoomParticipant: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// A source confirmed by the meeting SDK. Its ID is distinct from the owner's user ID.
public struct ReceivedMeetingShare: Identifiable, Sendable, Equatable {
    public let id: String
    public let ownerID: String
    public let ownerName: String
    public let title: String

    public init(id: String, ownerID: String, ownerName: String, title: String = "Shared screen") {
        self.id = id
        self.ownerID = ownerID
        self.ownerName = ownerName
        self.title = title
    }
}

public enum MeetingSharingState: Sendable, Equatable {
    case idle
    case sharing(ShareTarget)

    public var isSharing: Bool { if case .sharing = self { true } else { false } }
    public var target: ShareTarget? { if case .sharing(let target) = self { target } else { nil } }
}

public struct MeetingCapabilities: Sendable, Equatable {
    public let canJoin: Bool
    public let canHost: Bool
    public let canChat: Bool
    public let canShare: Bool
    public let supportsNativeVideo: Bool
    public let canAdmitParticipants: Bool
    public let canReceiveShare: Bool
    public let canEnumerateShareTargets: Bool
    /// A measured live SDK limit, never inferred from the number of mock tiles.
    public let confirmedLiveVideoLimit: Int?
    public let unavailabilityReason: String?

    public init(canJoin: Bool, canHost: Bool, canChat: Bool, canShare: Bool,
                supportsNativeVideo: Bool, confirmedLiveVideoLimit: Int? = nil,
                unavailabilityReason: String? = nil, canAdmitParticipants: Bool = false,
                canReceiveShare: Bool = false, canEnumerateShareTargets: Bool = false) {
        self.canJoin = canJoin
        self.canHost = canHost
        self.canChat = canChat
        self.canShare = canShare
        self.supportsNativeVideo = supportsNativeVideo
        self.canAdmitParticipants = canAdmitParticipants
        self.canReceiveShare = canReceiveShare
        self.canEnumerateShareTargets = canEnumerateShareTargets
        self.confirmedLiveVideoLimit = confirmedLiveVideoLimit
        self.unavailabilityReason = unavailabilityReason
    }
}

/// Request values stay in memory. Meeting links and passcodes must not enter logs.
public struct MeetingRequest: Sendable, Equatable {
    public let url: URL?
    public let displayName: String
    public let title: String
    public let isHost: Bool
    public let microphoneMuted: Bool
    public let cameraEnabled: Bool

    public init(url: URL?, displayName: String, title: String, isHost: Bool,
                microphoneMuted: Bool = true, cameraEnabled: Bool = false) {
        self.url = url
        self.displayName = displayName
        self.title = title
        self.isHost = isHost
        self.microphoneMuted = microphoneMuted
        self.cameraEnabled = cameraEnabled
    }
}

public enum MeetingDriverEvent: Sendable {
    case status(MeetingStatus)
    case participants([MeetingParticipant])
    case message(MeetingChatMessage)
    case messageUpdated(MeetingChatMessage)
    case messageRemoved(UUID)
    case chatLegalNotice(MeetingChatLegalNotice?)
    case meetingIndicators([MeetingIndicator])
    case microphoneMuted(Bool)
    case cameraEnabled(Bool)
    case videoQuality(MeetingVideoQuality)
    case cloudRecording(MeetingCloudRecording)
    case cloudRecordingControlError(String)
    case sharing(MeetingSharingState)
    case receivedShares([ReceivedMeetingShare])
    case waitingRoomParticipants([WaitingRoomParticipant])
    case hostChanged(Bool)
    case invitation(URL)
    /// An asynchronous action failed while the meeting continues, for example screen capture permission.
    case controlError(String)
    case failure(String)
}

public enum MeetingError: LocalizedError, Sendable, Equatable {
    case unavailable(String)
    case noMeeting
    case operationInProgress
    case alreadyInMeeting
    case hostRequired
    case invalidName
    case invalidLink
    case chatTooLong
    case participantNoLongerWaiting
    case screenCapturePermissionRequired

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .noMeeting: "Join a meeting first."
        case .operationInProgress: "Please wait for the current action to finish."
        case .alreadyInMeeting: "Leave your current meeting before joining another."
        case .hostRequired: "Only the host can end the meeting for everyone."
        case .invalidName: "Enter the name you want people to see."
        case .invalidLink: "Enter a valid Zoom meeting link."
        case .chatTooLong: "Please keep your message under 4,000 characters."
        case .participantNoLongerWaiting: "This person is no longer in the waiting room."
        case .screenCapturePermissionRequired: "Allow Yap in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        }
    }
}
