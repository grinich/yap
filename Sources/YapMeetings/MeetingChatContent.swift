import Foundation

public struct MeetingChatRecipient: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case everyone, participant, waitingRoom, panelists, attendeeAndPanelists, unavailable }
    public var kind: Kind
    public var participantID: String?
    public var name: String
    public var id: String { kind.rawValue + ":" + (participantID ?? "") }
    public static let everyone = Self(kind: .everyone, name: "Everyone")
    public static let waitingRoom = Self(kind: .waitingRoom, name: "Waiting Room")
    public static let panelists = Self(kind: .panelists, name: "All Panelists")
    public init(kind: Kind, participantID: String? = nil, name: String) {
        self.kind = kind; self.participantID = participantID; self.name = name
    }
    public var label: String { kind == .participant ? "\(name) (private)" : name }
}

/// Text segments keep formatting offsets out of the app model. The bridge converts
/// each segment to the NSString ranges required by the native SDK.
public struct MeetingChatTextRun: Codable, Equatable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool
    public var link: String?
    public init(text: String, bold: Bool = false, italic: Bool = false,
                underline: Bool = false, strikethrough: Bool = false, link: String? = nil) {
        self.text = text; self.bold = bold; self.italic = italic
        self.underline = underline; self.strikethrough = strikethrough; self.link = link
    }
}

public struct MeetingChatDraft: Codable, Equatable, Sendable {
    public var text: String
    public var recipient: MeetingChatRecipient
    public var runs: [MeetingChatTextRun]
    public var replyToSDKID: String?
    public init(text: String, recipient: MeetingChatRecipient = .everyone,
                runs: [MeetingChatTextRun] = [], replyToSDKID: String? = nil) {
        self.text = text; self.recipient = recipient; self.runs = runs; self.replyToSDKID = replyToSDKID
    }
    public var hasValidFormatting: Bool { runs.isEmpty || runs.map(\.text).joined() == text }
}

public struct MeetingChatPolicy: Codable, Equatable, Sendable {
    public var canEveryone: Bool
    public var canPrivate: Bool
    public var onlyHost: Bool
    public var canWaitingRoom: Bool
    public var canPanelists: Bool
    public var canTransferFiles: Bool
    public var allowedFileTypes: String
    public var maxFileBytes: UInt64
    public init(canEveryone: Bool = true, canPrivate: Bool = false, onlyHost: Bool = false,
                canWaitingRoom: Bool = false, canPanelists: Bool = false, canTransferFiles: Bool = false,
                allowedFileTypes: String = "", maxFileBytes: UInt64 = 0) {
        self.canEveryone = canEveryone; self.canPrivate = canPrivate; self.onlyHost = onlyHost
        self.canWaitingRoom = canWaitingRoom; self.canPanelists = canPanelists
        self.canTransferFiles = canTransferFiles; self.allowedFileTypes = allowedFileTypes; self.maxFileBytes = maxFileBytes
    }
}

public struct MeetingChatAttachment: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case available, transferring, completed, failed, cancelled }
    public var id: String
    public var name: String
    public var bytes: UInt64
    public var date: Date
    public var senderName: String
    public var recipient: MeetingChatRecipient
    public var isFromSelf: Bool
    public var status: Status
    public var progress: Double
    public init(id: String, name: String, bytes: UInt64, date: Date = .now, senderName: String,
                recipient: MeetingChatRecipient = .everyone, isFromSelf: Bool, status: Status = .available, progress: Double = 0) {
        self.id = id; self.name = name; self.bytes = bytes; self.date = date; self.senderName = senderName
        self.recipient = recipient; self.isFromSelf = isFromSelf; self.status = status; self.progress = min(1, max(0, progress))
    }
}

public extension MeetingChatMessage {
    /// A private reply stays private even if the user selected Everyone elsewhere.
    /// Missing sender identity disables replying instead of widening the audience.
    var replyRecipient: MeetingChatRecipient? {
        guard recipient.kind != .unavailable, recipient.kind != .attendeeAndPanelists else { return nil }
        guard recipient.kind == .participant else { return recipient }
        if isFromSelf { return recipient.participantID == nil ? nil : recipient }
        guard let senderID, !senderID.isEmpty else { return nil }
        return MeetingChatRecipient(kind: .participant, participantID: senderID, name: senderName)
    }
}
