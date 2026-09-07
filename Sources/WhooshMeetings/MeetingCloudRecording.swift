import Foundation

/// The meeting-wide cloud state reported by Zoom, independently of this user's permission to control it.
public enum MeetingCloudRecordingStatus: String, Sendable, Equatable {
    case unavailable, stopped, connecting, recording, paused

    public var isActive: Bool { self == .recording || self == .paused }
}

public struct MeetingCloudRecording: Sendable, Equatable {
    public let status: MeetingCloudRecordingStatus
    public let canControl: Bool
    public let unavailableReason: String?

    public init(status: MeetingCloudRecordingStatus = .unavailable, canControl: Bool = false,
                unavailableReason: String? = nil) {
        self.status = status
        self.canControl = canControl && status != .unavailable
        self.unavailableReason = self.canControl ? nil : unavailableReason
    }
}
