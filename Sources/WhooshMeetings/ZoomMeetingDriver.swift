import AppKit
import Foundation

@MainActor
public func makeZoomMeetingDriver(accountClient: ZoomAccountClient) -> any MeetingDriver {
    #if canImport(WhooshZoomBridge)
    ZoomMeetingDriver(accountClient: accountClient)
    #else
    MissingZoomMeetingDriver()
    #endif
}

#if canImport(WhooshZoomBridge)
import WhooshZoomBridge
import ScreenCaptureKit

/// The native Meeting SDK implementation. OAuth and the SDK signature come from the personal Keychain actor.
@MainActor
public final class ZoomMeetingDriver: MeetingDriver {
    public let isDemo = false
    public let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: true, canShare: true,
        supportsNativeVideo: true, canAdmitParticipants: true, canReceiveShare: true, canEnumerateShareTargets: true)
    public var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    private let accountClient: ZoomAccountClient
    private var bridge: WHZoomSDKBridge?
    private var sessionID: UUID?
    private var shareTargets: [ShareTarget] = []
    private var chatIDs: [String: UUID] = [:]
    private var preparedHostMeetingNumber: Int64?
    private static weak var activeOwner: ZoomMeetingDriver?

    public init(accountClient: ZoomAccountClient) { self.accountClient = accountClient }

    public func connect(_ request: MeetingRequest, sessionID: UUID) async throws {
        guard self.sessionID == nil,
              Self.activeOwner == nil || Self.activeOwner === self else { throw MeetingError.alreadyInMeeting }
        let link = try request.url.map(ZoomMeetingLink.init)
        guard request.isHost || link != nil else { throw MeetingError.invalidLink }
        self.sessionID = sessionID
        Self.activeOwner = self
        do {
            let credentials: ZoomMeetingCredentials
            let meetingNumber: Int64
            if request.isHost && link == nil {
                let hosting = try await accountClient.hostingCredentials(title: request.title)
                credentials = hosting.credentials
                meetingNumber = hosting.meetingNumber
            } else {
                credentials = try await accountClient.meetingCredentials()
                meetingNumber = link?.meetingNumber ?? 0
            }
            try Task.checkCancellation()
            guard self.sessionID == sessionID else { throw CancellationError() }
            preparedHostMeetingNumber = request.isHost && link == nil ? meetingNumber : nil
            guard credentials.zakExpiresAt > Date().addingTimeInterval(5) else {
                throw MeetingError.unavailable("Your Zoom sign-in key expired before joining. Please try again.")
            }
            let native = WHZoomSDKBridge()
            native.eventHandler = { [weak self] identifier, event, data in
                // The bridge delivers immutable data on the main thread, even if Zoom's callback was elsewhere.
                MainActor.assumeIsolated { self?.receive(identifier: identifier, event: event, data: data) }
            }
            bridge = native
            let result = native.begin(jwt: credentials.sdkJWT, zak: credentials.zak,
                meetingNumber: meetingNumber, vanityID: link?.vanityID,
                passcode: link?.embeddedPasscode, registrantToken: link?.registrantToken,
                displayName: request.displayName, host: request.isHost, sessionID: sessionID.uuidString)
            try check(result, action: "start the meeting connection")
        } catch {
            if self.sessionID == sessionID {
                self.sessionID = nil; bridge = nil; preparedHostMeetingNumber = nil; Self.activeOwner = nil
            }
            throw error
        }
    }

    public func leave(sessionID: UUID, endForEveryone: Bool) async throws {
        guard self.sessionID == sessionID else { return }
        if let bridge { bridge.leave(endForEveryone: endForEveryone) }
        else {
            // Cancellation while awaiting OAuth/ZAK has not started any native media.
            self.sessionID = nil; Self.activeOwner = nil
            onEvent?(sessionID, .status(.idle))
        }
    }

    public func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws {
        try check(try native(for: sessionID).setMicrophoneMuted(muted), action: muted ? "mute your microphone" : "unmute your microphone")
    }
    public func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws {
        try check(try native(for: sessionID).setCameraEnabled(enabled), action: enabled ? "turn on your camera" : "turn off your camera")
    }
    public func sendChat(text: String, sessionID: UUID) async throws {
        try check(try native(for: sessionID).sendChatText(text), action: "send the message")
    }

    public func availableShareTargets(sessionID: UUID) async throws -> [ShareTarget] {
        _ = try native(for: sessionID)
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if MeetingScreenCaptureErrors.permissionWasDenied(error) { throw MeetingError.screenCapturePermissionRequired }
            throw MeetingError.unavailable("Zooom couldn’t load windows and displays. Try again.")
        }
        try Task.checkCancellation()
        let native = try native(for: sessionID)
        var targets = content.windows.compactMap { window -> ShareTarget? in
            guard window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier,
                  window.frame.width > 1, window.frame.height > 1, native.isWindowShareable(window.windowID) else { return nil }
            let app = window.owningApplication?.applicationName ?? "App"
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ShareTarget(id: String(window.windowID), title: title.isEmpty ? app : "\(app) — \(title)", kind: .window)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if native.isDesktopSharingEnabled() {
            targets += content.displays.enumerated().map { index, display in
                let screen = NSScreen.screens.first {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
                }
                return ShareTarget(id: String(display.displayID), title: screen?.localizedName ?? "Display \(index + 1)", kind: .display)
            }
        }
        shareTargets = targets
        return targets
    }

    public func startShare(_ target: ShareTarget, sessionID: UUID) async throws {
        let native = try native(for: sessionID)
        guard target.kind != .demo, shareTargets.contains(target), let id = UInt32(target.id) else {
            throw MeetingError.unavailable("Choose an available window or display before sharing.")
        }
        let result = target.kind == .window ? native.startSharingWindow(id) : native.startSharingDisplay(id)
        try check(result, action: "share this screen")
    }
    public func stopShare(sessionID: UUID) async throws {
        try check(try native(for: sessionID).stopSharing(), action: "stop screen sharing")
    }
    public func startCloudRecording(sessionID: UUID) async throws {
        try check(try native(for: sessionID).setCloudRecordingEnabled(true), action: "start cloud recording")
    }
    public func pauseCloudRecording(sessionID: UUID) async throws {
        try check(try native(for: sessionID).pauseCloudRecording(), action: "pause cloud recording")
    }
    public func resumeCloudRecording(sessionID: UUID) async throws {
        try check(try native(for: sessionID).resumeCloudRecording(), action: "resume cloud recording")
    }
    public func stopCloudRecording(sessionID: UUID) async throws {
        try check(try native(for: sessionID).setCloudRecordingEnabled(false), action: "stop cloud recording")
    }
    public func admitParticipant(_ participantID: String, sessionID: UUID) async throws {
        guard let id = UInt32(participantID) else { throw MeetingError.participantNoLongerWaiting }
        try check(try native(for: sessionID).admitParticipant(id), action: "admit this person")
    }
    public func showMeetingIndicator(_ indicatorID: String, sessionID: UUID) async throws {
        try check(try native(for: sessionID).showMeetingIndicator(indicatorID), action: "show meeting privacy details")
    }
    public func setVisibleParticipants(_ participantIDs: [String]) { bridge?.setVisibleParticipants(participantIDs) }
    public func nativeVideoView(for participantID: String) -> NSView? { bridge?.videoView(forParticipant: participantID) }
    public func setSelectedReceivedShare(_ sourceID: String?) { bridge?.selectReceivedShare(sourceID) }
    public func nativeShareView(for sourceID: String) -> NSView? { bridge?.shareView(forSource: sourceID) }

    private func native(for sessionID: UUID) throws -> WHZoomSDKBridge {
        guard self.sessionID == sessionID, let bridge else { throw MeetingError.noMeeting }
        return bridge
    }
    private func check(_ code: Int, action: String) throws {
        guard code == 0 else { throw MeetingError.unavailable("Zoom could not \(action) (SDK code \(code)).") }
    }
    private func receive(identifier: String, event: String, data: Data) {
        guard let id = UUID(uuidString: identifier), id == sessionID,
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
        switch event {
        case "status":
            guard let raw = value as? String, let status = MeetingStatus(rawValue: raw) else { return }
            if status == .inMeeting, let number = preparedHostMeetingNumber {
                preparedHostMeetingNumber = nil
                Task { await accountClient.markHostedMeetingStarted(number) }
            }
            if status == .idle { clearNativeState() }
            onEvent?(id, .status(status))
        case "failure":
            clearNativeState()
            onEvent?(id, .failure(value as? String ?? "Zoom could not connect."))
        case "controlError": onEvent?(id, .controlError(value as? String ?? "Zoom could not complete that action."))
        case "cloudRecordingError":
            onEvent?(id, .cloudRecordingControlError(value as? String ?? "Zoom could not change cloud recording."))
        case "cloudRecording":
            guard let item = value as? [String: Any], let raw = item["state"] as? String,
                  let state = MeetingCloudRecordingStatus(rawValue: raw) else { return }
            onEvent?(id, .cloudRecording(MeetingCloudRecording(status: state,
                canControl: item["canControl"] as? Bool ?? false,
                unavailableReason: item["unavailableReason"] as? String)))
        case "participants":
            let people = (value as? [[String: Any]] ?? []).compactMap { item -> MeetingParticipant? in
                guard let identifier = item["id"] as? String else { return nil }
                return MeetingParticipant(id: identifier, name: item["name"] as? String ?? "Participant",
                    isSelf: item["isSelf"] as? Bool ?? false, isHost: item["isHost"] as? Bool ?? false,
                    isMuted: item["isMuted"] as? Bool ?? true, isCameraEnabled: item["isCameraEnabled"] as? Bool ?? false,
                    isSpeaking: item["isSpeaking"] as? Bool ?? false, avatarSeed: Int(identifier) ?? 0,
                    avatar: (item["avatarPath"] as? String).flatMap {
                        MeetingAvatar(path: $0, revision: item["avatarRevision"] as? Int ?? 0)
                    }, videoSize: MeetingVideoSize(width: item["videoWidth"] as? Double ?? 0,
                                                  height: item["videoHeight"] as? Double ?? 0))
            }
            onEvent?(id, .participants(people))
        case "chat", "chatEdited":
            guard let item = value as? [String: Any], let text = item["text"] as? String else { return }
            let externalID = item["id"] as? String ?? ""
            let messageID = externalID.isEmpty ? UUID() : chatIDs[externalID] ?? UUID()
            if !externalID.isEmpty { chatIDs[externalID] = messageID }
            let message = MeetingChatMessage(id: messageID, senderName: item["senderName"] as? String ?? "Participant",
                text: text, date: Date(timeIntervalSince1970: item["timestamp"] as? Double ?? Date().timeIntervalSince1970),
                isFromSelf: item["isFromSelf"] as? Bool ?? false)
            onEvent?(id, event == "chatEdited" ? .messageUpdated(message) : .message(message))
        case "chatDeleted":
            if let externalID = value as? String, let messageID = chatIDs[externalID] {
                onEvent?(id, .messageRemoved(messageID))
            }
        case "chatLegalNotice":
            let item = value as? [String: String]
            onEvent?(id, .chatLegalNotice(item.map { MeetingChatLegalNotice(prompt: $0["prompt"] ?? "", explanation: $0["explanation"] ?? "") }))
        case "waitingRoom":
            onEvent?(id, .waitingRoomParticipants((value as? [[String: String]] ?? []).compactMap {
                guard let identifier = $0["id"] else { return nil }
                return WaitingRoomParticipant(id: identifier, name: $0["name"] ?? "Participant")
            }))
        case "receivedShares":
            onEvent?(id, .receivedShares((value as? [[String: String]] ?? []).compactMap {
                guard let identifier = $0["id"], let ownerID = $0["ownerID"] else { return nil }
                return ReceivedMeetingShare(id: identifier, ownerID: ownerID, ownerName: $0["ownerName"] ?? "Participant", title: $0["title"] ?? "Shared screen")
            }))
        case "sharing":
            guard let item = value as? [String: Any] else { return }
            if item["active"] as? Bool == true {
                let windowID = (item["windowID"] as? NSNumber)?.uint32Value ?? 0
                let displayID = (item["displayID"] as? NSNumber)?.uint32Value ?? 0
                let target = MeetingShareSourceLabel.target(windowID: windowID, displayID: displayID, available: shareTargets)
                onEvent?(id, .sharing(.sharing(target)))
            } else { onEvent?(id, .sharing(.idle)) }
        case "invitation":
            if let string = value as? String, let url = URL(string: string), (try? ZoomMeetingLink(url)) != nil {
                onEvent?(id, .invitation(url))
            }
        case "videoQuality":
            guard let item = value as? [String: Any] else { return }
            onEvent?(id, .videoQuality(MeetingVideoQuality(
                requestsHD: item["requestsHD"] as? Bool ?? false,
                sendWidth: (item["sendWidth"] as? NSNumber)?.intValue,
                sendHeight: (item["sendHeight"] as? NSNumber)?.intValue,
                sendFPS: (item["sendFPS"] as? NSNumber)?.intValue)))
        case "indicators":
            onEvent?(id, .meetingIndicators((value as? [[String: String]] ?? []).compactMap {
                guard let identifier = $0["id"] else { return nil }
                return MeetingIndicator(id: identifier, title: $0["title"] ?? "Meeting privacy")
            }))
        default: break
        }
    }
    private func clearNativeState() {
        sessionID = nil; shareTargets = []; chatIDs = [:]; preparedHostMeetingNumber = nil
        bridge?.eventHandler = nil; bridge = nil
        if Self.activeOwner === self { Self.activeOwner = nil }
    }
}
#endif
