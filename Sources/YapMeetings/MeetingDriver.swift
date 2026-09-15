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
    func setHandRaised(_ raised: Bool, sessionID: UUID) async throws
    func sendChat(text: String, sessionID: UUID) async throws
    func sendChatReply(text: String, messageID: String, sessionID: UUID) async throws
    func sendChat(_ draft: MeetingChatDraft, sessionID: UUID) async throws
    func deleteChat(messageID: String, sessionID: UUID) async throws
    func sendChatFile(_ url: URL, recipient: MeetingChatRecipient, sessionID: UUID) async throws
    func receiveChatFile(_ attachmentID: String, to url: URL, sessionID: UUID) async throws
    func cancelChatFile(_ attachmentID: String, sessionID: UUID) async throws
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
    func preparePhotoShutter(_ pcm: Data, sessionID: UUID) async throws
    func isPhotoShutterReady() -> Bool
    func playPhotoShutter() -> Bool
    func cancelPhotoShutter()
    func nativeVideoView(for participantID: String) -> NSView?
    /// The current subscription has reported live video and has usable rendering geometry.
    /// This is a readiness signal; callers must still allow the window compositor to settle.
    func isVideoReadyForCapture(for participantID: String) -> Bool
    func nativeShareView(for sourceID: String) -> NSView?
    /// Subscribe to at most one received screen share and release the previous renderer.
    func setSelectedReceivedShare(_ sourceID: String?)
    /// The driver subscribes only visible tiles and releases hidden video elements.
    func setVisibleParticipants(_ participantIDs: [String])
}

public extension MeetingDriver {
    func setHandRaised(_ raised: Bool, sessionID: UUID) async throws {
        throw MeetingError.unavailable("Raising your hand isn’t available in this meeting.")
    }
    func sendChat(_ draft: MeetingChatDraft, sessionID: UUID) async throws {
        guard draft.recipient.kind == .everyone, draft.runs.isEmpty else {
            throw MeetingError.unavailable("This meeting connection doesn’t support this message format or recipient.")
        }
        if let reply = draft.replyToSDKID { try await sendChatReply(text: draft.text, messageID: reply, sessionID: sessionID) }
        else { try await sendChat(text: draft.text, sessionID: sessionID) }
    }
    func deleteChat(messageID: String, sessionID: UUID) async throws { throw MeetingError.unavailable("Deleting messages isn’t available in this meeting.") }
    func sendChatFile(_ url: URL, recipient: MeetingChatRecipient, sessionID: UUID) async throws { throw MeetingError.unavailable("File sharing isn’t available in this meeting.") }
    func receiveChatFile(_ attachmentID: String, to url: URL, sessionID: UUID) async throws { throw MeetingError.unavailable("This file isn’t available to download.") }
    func cancelChatFile(_ attachmentID: String, sessionID: UUID) async throws { throw MeetingError.unavailable("This file transfer cannot be cancelled.") }
    func sendChatReply(text: String, messageID: String, sessionID: UUID) async throws {
        throw MeetingError.unavailable("Threaded replies aren’t available for this message.")
    }

    func preparePhotoShutter(_ pcm: Data, sessionID: UUID) async throws { throw MeetingError.unavailable("The meeting doesn’t allow the shared shutter sound.") }
    func isPhotoShutterReady() -> Bool { false }
    func playPhotoShutter() -> Bool { false }
    func cancelPhotoShutter() {}

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
    func isVideoReadyForCapture(for participantID: String) -> Bool { false }
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
