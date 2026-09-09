import AppKit
import Foundation

/// The SDK implementation owns its delegates, native video elements and subscriptions.
/// Every callback carries its session ID so late callbacks cannot affect the next call.
@MainActor
public protocol MeetingDriver: AnyObject {
    var isDemo: Bool { get }
    var capabilities: MeetingCapabilities { get }
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)? { get set }
    /// Throw only before joining or after native teardown. An error must never leave media running.
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws
    /// Returning may acknowledge a request. Emit .status(.idle) only after native media has stopped.
    /// Likewise .status(.failed) and .failure are terminal; command failures should throw instead.
    func leave(sessionID: UUID, endForEveryone: Bool) async throws
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws
    func sendChat(text: String, sessionID: UUID) async throws
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws
    func stopShare(sessionID: UUID) async throws
    func submitRoomSharingCode(_ code: String, sessionID: UUID) async throws
    func startCloudRecording(sessionID: UUID) async throws
    func pauseCloudRecording(sessionID: UUID) async throws
    func resumeCloudRecording(sessionID: UUID) async throws
    func stopCloudRecording(sessionID: UUID) async throws
    /// Enumerate only in response to a person's explicit sharing action; this can request screen permission.
    func availableShareTargets(sessionID: UUID) async throws -> [ShareTarget]
    func admitParticipant(_ participantID: String, sessionID: UUID) async throws
    func showMeetingIndicator(_ indicatorID: String, sessionID: UUID) async throws
    func nativeVideoView(for participantID: String) -> NSView?
    func nativeShareView(for sourceID: String) -> NSView?
    /// Subscribe to at most one received screen share and release the previous renderer.
    func setSelectedReceivedShare(_ sourceID: String?)
    /// The driver subscribes only visible tiles and releases hidden video elements.
    func setVisibleParticipants(_ participantIDs: [String])
}

public extension MeetingDriver {
    func submitRoomSharingCode(_ code: String, sessionID: UUID) async throws {
        throw MeetingError.unavailable("Zoom Room sharing isn’t available in this build.")
    }
    func startCloudRecording(sessionID: UUID) async throws { throw cloudRecordingUnavailable }
    func pauseCloudRecording(sessionID: UUID) async throws { throw cloudRecordingUnavailable }
    func resumeCloudRecording(sessionID: UUID) async throws { throw cloudRecordingUnavailable }
    func stopCloudRecording(sessionID: UUID) async throws { throw cloudRecordingUnavailable }
    private var cloudRecordingUnavailable: MeetingError {
        .unavailable("Cloud recording isn’t available in this meeting.")
    }
    func nativeVideoView(for participantID: String) -> NSView? { nil }
    func setVisibleParticipants(_ participantIDs: [String]) {}
    func availableShareTargets(sessionID: UUID) async throws -> [ShareTarget] {
        throw MeetingError.unavailable("Choosing a screen to share isn’t available in this build.")
    }
    func admitParticipant(_ participantID: String, sessionID: UUID) async throws {
        throw MeetingError.unavailable("Waiting room controls aren’t available in this build.")
    }
    func showMeetingIndicator(_ indicatorID: String, sessionID: UUID) async throws {
        throw MeetingError.unavailable("Meeting privacy details aren’t available in this build.")
    }
    func nativeShareView(for sourceID: String) -> NSView? { nil }
    func setSelectedReceivedShare(_ sourceID: String?) {}
}

/// This is intentionally unavailable, not a simulated implementation of Zoom.
/// Replace with a compile-verified ZoomSDK driver after installing the current SDK.
@MainActor
public final class MissingZoomMeetingDriver: MeetingDriver {
    public static let setupMessage = "Live Zoom calls aren’t connected in this build. The current macOS Meeting SDK and your Zoom developer configuration are needed. You can explore Yap using the clearly labeled demo."
    public let isDemo = false
    public let capabilities = MeetingCapabilities(
        canJoin: false, canHost: false, canChat: false, canShare: false,
        supportsNativeVideo: false, unavailabilityReason: setupMessage)
    public var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?

    public init() {}

    public func connect(_ request: MeetingRequest, sessionID: UUID) async throws {
        throw MeetingError.unavailable(Self.setupMessage)
    }
    public func leave(sessionID: UUID, endForEveryone: Bool) async throws {}
    public func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    public func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    public func sendChat(text: String, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    public func startShare(_ target: ShareTarget, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    public func stopShare(sessionID: UUID) async throws { throw MeetingError.noMeeting }
}
