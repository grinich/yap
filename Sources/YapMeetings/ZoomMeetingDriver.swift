import AppKit
import Foundation
import AVFoundation

@MainActor
public func makeZoomMeetingDriver(accountClient: ZoomAccountClient) -> any MeetingDriver {
    #if canImport(YapZoomBridge)
    ZoomMeetingDriver(accountClient: accountClient)
    #else
    MissingZoomMeetingDriver()
    #endif
}

#if canImport(YapZoomBridge)
import YapZoomBridge
import ScreenCaptureKit

/// The native Meeting SDK implementation. OAuth and the SDK signature come from the personal Keychain actor.
@MainActor
public final class ZoomMeetingDriver: MeetingDriver, CameraEffectsDriver, MeetingMediaDriver {
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
    public var onCameraEffectsChanged: (@MainActor (CameraEffectsStatus) -> Void)?
    public var onMediaDevicesChanged: (@MainActor (MeetingMediaState) -> Void)?
    private var mediaGeneration = UUID()
    private var lastMediaState = MeetingMediaState()
    private var preferredCameraEffects = CameraEffectsPreferences()
    private var cameraPreparation: Task<CameraEffectsStatus, Error>?
    private var cameraEffectsGeneration = UUID()
    private var cameraEffectsOperation = UUID()
    private var cameraPreviewGeneration = UUID()
    private var cameraEnableGeneration = UUID()
    private var cameraEffectsOpen = false
    private var isShuttingDown = false

    public init(accountClient: ZoomAccountClient) { self.accountClient = accountClient }

    public func connect(_ request: MeetingRequest, sessionID: UUID) async throws {
        guard !isShuttingDown else { throw CancellationError() }
        guard self.sessionID == nil,
              Self.activeOwner == nil || Self.activeOwner === self else { throw MeetingError.alreadyInMeeting }
        let link = try request.url.map(ZoomMeetingLink.init)
        guard request.isHost || request.isRoomShare || link != nil else { throw MeetingError.invalidLink }
        // A settings-only SDK must finish teardown before the meeting SDK is created.
        closeCameraEffects()
        self.sessionID = sessionID
        Self.activeOwner = self
        do {
            var microphoneMuted = request.microphoneMuted
            var cameraEnabled = request.cameraEnabled
            if request.isRoomShare {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw MeetingError.unavailable("Allow Yap microphone access in System Settings to detect a nearby Zoom Room. Your microphone won’t be broadcast to the room.")
                }
            }
            if !request.isRoomShare, !request.microphoneMuted {
                microphoneMuted = !(await AVCaptureDevice.requestAccess(for: .audio))
                try Task.checkCancellation()
                guard self.sessionID == sessionID else { throw CancellationError() }
            }
            if !request.isRoomShare, request.cameraEnabled {
                cameraEnabled = await AVCaptureDevice.requestAccess(for: .video)
                try Task.checkCancellation()
                guard self.sessionID == sessionID else { throw CancellationError() }
            }
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
            let native = makeNativeBridge()
            bridge = native
            let result = request.isRoomShare
                ? native.beginRoomShare(jwt: credentials.sdkJWT, sessionID: sessionID.uuidString)
                : native.begin(jwt: credentials.sdkJWT, zak: credentials.zak,
                meetingNumber: meetingNumber, vanityID: link?.vanityID,
                passcode: link?.embeddedPasscode, registrantToken: link?.registrantToken,
                displayName: request.displayName, host: request.isHost, microphoneMuted: microphoneMuted,
                cameraEnabled: cameraEnabled, sessionID: sessionID.uuidString)
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

    @discardableResult public func shutdown() -> Bool {
        // Active calls must leave through their normal SDK callback first.
        guard sessionID == nil else { return false }
        guard !isShuttingDown else { return true }
        // The SDK can still be busy after the UI considers the call idle.
        // A refusal must retain the owner and callbacks so leaving can finish.
        guard bridge?.shutdown() ?? true else { return false }
        isShuttingDown = true
        cameraEffectsOpen = false
        cameraEffectsGeneration = UUID(); cameraPreviewGeneration = UUID()
        cameraEffectsOperation = UUID(); cameraEnableGeneration = UUID()
        mediaGeneration = UUID()
        cameraPreparation?.cancel(); cameraPreparation = nil
        // Native shutdown already detached before uninitializing. Keep Swift
        // state terminal when cancelled preparation continuations resume later.
        bridge?.eventHandler = nil
        bridge?.cameraEffectsChanged = nil
        bridge?.mediaDevicesChanged = nil
        bridge = nil
        shareTargets = []; chatIDs = [:]; preparedHostMeetingNumber = nil
        lastMediaState = MeetingMediaState()
        if Self.activeOwner === self { Self.activeOwner = nil }
        return true
    }

    public func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws {
        try check(try native(for: sessionID).setMicrophoneMuted(muted), action: muted ? "mute your microphone" : "unmute your microphone")
    }
    public func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws {
        try Task.checkCancellation()
        let native = try native(for: sessionID)
        let generation = UUID()
        cameraEnableGeneration = generation
        if enabled {
            _ = try await applyNativeCameraEffects(preferredCameraEffects, native: native, requiresOpen: false)
            try Task.checkCancellation()
            guard cameraEnableGeneration == generation, self.sessionID == sessionID, bridge === native else { throw CancellationError() }
        } else {
            // An explicit Off must prevent a suspended earlier On from unmuting.
            cameraEffectsOperation = UUID()
        }
        let result = native.setCameraEnabled(enabled)
        if result != 0, enabled, let message = native.cameraEffectsError {
            throw MeetingError.unavailable("Your camera is still off. \(message)")
        }
        try check(result, action: enabled ? "turn on your camera" : "turn off your camera")
    }
    public func setHandRaised(_ raised: Bool, sessionID: UUID) async throws {
        let result = try native(for: sessionID).setHandRaised(raised)
        if result == 6 { throw MeetingError.unavailable("The host or meeting settings don’t allow that hand control.") }
        try check(result, action: raised ? "raise your hand" : "lower your hand")
    }

    public func prepareMediaDevices() async throws -> MeetingMediaState {
        try Task.checkCancellation()
        if bridge?.cameraEffectsReady != true {
            do { _ = try await prepareCameraEffects() }
            catch is CancellationError { throw CancellationError() }
            catch { if bridge?.cameraEffectsReady != true { throw error } }
        }
        try Task.checkCancellation()
        let native = try mediaNative()
        return try mediaReadback(native)
    }

    public func selectMediaDevice(_ deviceID: String, kind: MeetingMediaKind) async throws -> MeetingMediaState {
        try Task.checkCancellation()
        let native = try mediaNative()
        try checkMedia(native.selectMediaDevice(deviceID, kind: kind.rawValue), native: native, action: "select that device")
        return try mediaReadback(native)
    }

    public func setMediaVolume(_ volume: Int, kind: MeetingMediaKind) async throws -> MeetingMediaState {
        try Task.checkCancellation()
        guard (0...100).contains(volume), kind != .camera else { throw MeetingError.unavailable("Choose a volume between 0 and 100%.") }
        let native = try mediaNative()
        try checkMedia(native.setMediaVolume(volume, kind: kind.rawValue), native: native, action: "change the volume")
        return try mediaReadback(native)
    }

    public func setAutomaticMicrophoneVolume(_ enabled: Bool) async throws -> MeetingMediaState {
        try Task.checkCancellation()
        let native = try mediaNative()
        try checkMedia(native.setMicrophoneAutoGain(enabled), native: native, action: "change automatic microphone volume")
        return try mediaReadback(native)
    }

    public func setMediaTest(_ kind: MeetingMediaKind, running: Bool) async throws -> MeetingMediaState {
        try Task.checkCancellation()
        let native = try mediaNative()
        let generation = mediaGeneration, expectedSession = sessionID
        if kind == .microphone, running {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw MeetingError.unavailable("Allow Yap microphone access in System Settings → Privacy & Security → Microphone, then try again.")
            }
        }
        try Task.checkCancellation()
        guard generation == mediaGeneration, sessionID == expectedSession, bridge === native, native.cameraEffectsReady else { throw CancellationError() }
        try checkMedia(native.setMediaTest(kind.rawValue, running: running), native: native, action: "test that device")
        return try mediaReadback(native)
    }

    public func stopMediaTests() {
        mediaGeneration = UUID()
        bridge?.stopMediaTests()
    }

    private func mediaNative() throws -> WHZoomSDKBridge {
        guard let native = bridge, native.cameraEffectsReady, Self.activeOwner === self else {
            throw MeetingError.unavailable("Load the device list first, then try again.")
        }
        return native
    }

    private func mediaReadback(_ native: WHZoomSDKBridge) throws -> MeetingMediaState {
        try acceptMediaSnapshot(native.meetingMediaSnapshot())
    }

    private func acceptMediaSnapshot(_ data: Data) throws -> MeetingMediaState {
        do {
            let state = try MeetingMediaSnapshotDecoder.decode(data)
            lastMediaState = state
            onMediaDevicesChanged?(state)
            return state
        } catch {
            // Keep a confirmed running test visible so its Stop action survives a bad update.
            lastMediaState.error = error.localizedDescription
            onMediaDevicesChanged?(lastMediaState)
            throw error
        }
    }

    private func checkMedia(_ result: Int, native: WHZoomSDKBridge, action: String) throws {
        guard result == 0 else {
            throw MeetingError.unavailable(native.mediaDevicesError ?? "Zoom couldn’t \(action) (code \(result)). Try another device or refresh the list.")
        }
    }
    public func sendChatReply(text: String, messageID: String, sessionID: UUID) async throws {
        try check(try native(for: sessionID).sendChatReply(text, toMessage: messageID), action: "send this reply")
    }
    public func sendChat(text: String, sessionID: UUID) async throws {
        try check(try native(for: sessionID).sendChatText(text), action: "send the message")
    }
    public func sendChat(_ draft: MeetingChatDraft, sessionID: UUID) async throws {
        let payload = try JSONEncoder().encode(draft)
        try check(try native(for: sessionID).sendChatMessage(payload), action: "send the message")
    }
    public func deleteChat(messageID: String, sessionID: UUID) async throws {
        try check(try native(for: sessionID).deleteChatMessage(messageID), action: "delete the message")
    }
    public func sendChatFile(_ url: URL, recipient: MeetingChatRecipient, sessionID: UUID) async throws {
        let payload = try JSONEncoder().encode(recipient)
        try check(try native(for: sessionID).sendChatFile(url.path, recipient: payload), action: "send the file")
    }
    public func receiveChatFile(_ attachmentID: String, to url: URL, sessionID: UUID) async throws {
        try check(try native(for: sessionID).receiveChatFile(attachmentID, path: url.path), action: "download the file")
    }
    public func cancelChatFile(_ attachmentID: String, sessionID: UUID) async throws {
        try check(try native(for: sessionID).cancelChatFile(attachmentID), action: "cancel the file transfer")
    }

    private func decodeChatValue<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    public func availableShareTargets(sessionID: UUID) async throws -> [ShareTarget] {
        _ = try native(for: sessionID)
        // Retry ScreenCaptureKit itself: the CoreGraphics preflight result can
        // lag behind a permission change made while the app is running.
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if MeetingScreenCaptureErrors.permissionWasDenied(error) { throw MeetingError.screenCapturePermissionRequired }
            throw MeetingError.unavailable("Yap couldn’t load windows and displays. Try again.")
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
        if target == .computerAudio {
            guard native.isComputerAudioSharingEnabled() else {
                throw MeetingError.unavailable("Computer audio sharing isn’t available in this meeting. Check the host’s sharing permissions and try again.")
            }
            try check(native.startSharingComputerAudio(), action: "share computer audio")
            return
        }
        guard target.kind != .demo, shareTargets.contains(target), let id = UInt32(target.id) else {
            throw MeetingError.unavailable("Choose an available window or display before sharing.")
        }
        let result = target.kind == .window ? native.startSharingWindow(id) : native.startSharingDisplay(id)
        try check(result, action: "share this screen")
    }
    public func preparePhotoShutter(_ pcm: Data, sessionID: UUID) async throws {
        try check(try native(for: sessionID).preparePhotoShutter(pcm), action: "play the shutter sound for everyone")
    }
    public func isPhotoShutterReady() -> Bool { bridge?.isPhotoShutterReady() ?? false }
    public func playPhotoShutter() -> Bool { bridge?.playPhotoShutter() ?? false }
    public func cancelPhotoShutter() { bridge?.cancelPhotoShutter() }

    public func stopShare(sessionID: UUID) async throws {
        try check(try native(for: sessionID).stopSharing(), action: "stop sharing")
    }

    public func submitRoomSharingCode(_ code: String, sessionID: UUID) async throws {
        try check(try native(for: sessionID).submitRoomSharingCode(code), action: "connect to the Zoom Room")
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
    public func isVideoReadyForCapture(for participantID: String) -> Bool {
        bridge?.isVideoReadyForCapture(forParticipant: participantID) ?? false
    }
    public func setSelectedReceivedShare(_ sourceID: String?) { bridge?.selectReceivedShare(sourceID) }
    public func nativeShareView(for sourceID: String) -> NSView? { bridge?.shareView(forSource: sourceID) }

    public func setPreferredCameraEffects(_ preferences: CameraEffectsPreferences) {
        preferredCameraEffects = preferences
        if let bridge { setNativePreferences(preferences, on: bridge) }
    }

    public func prepareCameraEffects() async throws -> CameraEffectsStatus {
        try Task.checkCancellation()
        guard !isShuttingDown else { throw CancellationError() }
        guard Self.activeOwner == nil || Self.activeOwner === self else {
            throw MeetingError.unavailable("Another Yap meeting is using the camera settings. Open Camera settings in that meeting.")
        }
        cameraEffectsOpen = true
        if let cameraPreparation { return try await awaitCameraPreparation(cameraPreparation, generation: cameraEffectsGeneration) }
        if let bridge, bridge.cameraEffectsReady {
            return try await applyNativeCameraEffects(preferredCameraEffects, native: bridge)
        }
        guard sessionID == nil else {
            throw MeetingError.unavailable("Wait for Zoom to finish connecting, then reopen Camera settings.")
        }
        // Reserve the process-wide SDK before the signature request can suspend.
        Self.activeOwner = self
        let generation = cameraEffectsGeneration
        let task = Task { @MainActor [weak self] () throws -> CameraEffectsStatus in
            guard let self else { throw CancellationError() }
            do {
                let jwt = try await accountClient.cameraSettingsSignature()
                try Task.checkCancellation()
                guard generation == cameraEffectsGeneration, cameraEffectsOpen, sessionID == nil else { throw CancellationError() }
                let native = makeNativeBridge()
                bridge = native
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let result = native.prepareCameraEffects(jwt: jwt) { code, message in
                        if code == 0 { continuation.resume() }
                        else { continuation.resume(throwing: MeetingError.unavailable(message ?? "Zoom couldn’t prepare Camera settings. Try again.")) }
                    }
                    if result != 0 { continuation.resume(throwing: MeetingError.unavailable("Zoom couldn’t prepare Camera settings (SDK code \(result)). Try again.")) }
                }
                try Task.checkCancellation()
                guard generation == cameraEffectsGeneration, cameraEffectsOpen, bridge === native, sessionID == nil else { throw CancellationError() }
                let status = try await applyNativeCameraEffects(preferredCameraEffects, native: native)
                cameraPreparation = nil
                return status
            } catch {
                if generation == cameraEffectsGeneration, sessionID == nil {
                    cameraPreparation = nil
                    if let native = bridge, native.cameraEffectsReady {
                        // Keep recovery controls usable when saved effects no longer work.
                        if let status = try? Self.decodeCameraEffects(native.cameraEffectsSnapshot()) { onCameraEffectsChanged?(status) }
                    } else {
                        bridge?.cameraEffectsChanged = nil
                        bridge?.closeCameraEffects()
                        bridge = nil
                        if Self.activeOwner === self { Self.activeOwner = nil }
                    }
                }
                throw error
            }
        }
        cameraPreparation = task
        return try await awaitCameraPreparation(task, generation: generation)
    }

    private func awaitCameraPreparation(_ task: Task<CameraEffectsStatus, Error>, generation: UUID) async throws -> CameraEffectsStatus {
        let status = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.cameraEffectsGeneration == generation else { return }
                self.closeCameraEffects()
            }
        }
        try Task.checkCancellation()
        guard generation == cameraEffectsGeneration, cameraEffectsOpen else { throw CancellationError() }
        return status
    }

    public func applyCameraEffects(_ preferences: CameraEffectsPreferences) async throws -> CameraEffectsStatus {
        try Task.checkCancellation()
        guard cameraEffectsOpen, let bridge, bridge.cameraEffectsReady else {
            throw MeetingError.unavailable("Reopen Camera settings and wait for Zoom to finish preparing.")
        }
        return try await applyNativeCameraEffects(preferences, native: bridge)
    }

    public func startCameraEffectsPreview() async throws -> NSView {
        try Task.checkCancellation()
        guard sessionID == nil else {
            throw MeetingError.unavailable("Use your meeting self-view to check camera effects. Local preview is available before joining a meeting.")
        }
        guard cameraEffectsOpen, let native = bridge, native.cameraEffectsReady else {
            throw MeetingError.unavailable("Wait for Camera settings to finish preparing, then try Preview again.")
        }
        let generation = cameraEffectsGeneration
        let previewGeneration = UUID()
        cameraPreviewGeneration = previewGeneration
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw MeetingError.unavailable("Allow Yap camera access in System Settings → Privacy & Security → Camera, then try Preview again.")
        }
        try Task.checkCancellation()
        guard generation == cameraEffectsGeneration, previewGeneration == cameraPreviewGeneration,
              cameraEffectsOpen, bridge === native else { throw CancellationError() }
        guard let view = native.startCameraEffectsPreview() else {
            throw MeetingError.unavailable(native.cameraEffectsError ?? "Zoom couldn’t start the camera preview. Try again.")
        }
        return view
    }

    public func stopCameraEffectsPreview() {
        cameraPreviewGeneration = UUID()
        bridge?.stopCameraEffectsPreview()
    }

    public func closeCameraEffects() {
        mediaGeneration = UUID()
        cameraEffectsOpen = false
        cameraEffectsGeneration = UUID(); cameraPreviewGeneration = UUID()
        cameraPreparation?.cancel(); cameraPreparation = nil
        bridge?.cameraEffectsChanged = nil
        bridge?.closeCameraEffects()
        if sessionID == nil {
            bridge?.eventHandler = nil; bridge = nil
            if Self.activeOwner === self { Self.activeOwner = nil }
        }
    }

    private func makeNativeBridge() -> WHZoomSDKBridge {
        let native = WHZoomSDKBridge()
        native.eventHandler = { [weak self] identifier, event, data in
            MainActor.assumeIsolated { self?.receive(identifier: identifier, event: event, data: data) }
        }
        native.mediaDevicesChanged = { [weak self, weak native] data in
            MainActor.assumeIsolated {
                guard let self, let native, self.bridge === native else { return }
                _ = try? self.acceptMediaSnapshot(data)
            }
        }
        installCameraEffectsHandler(on: native)
        setNativePreferences(preferredCameraEffects, on: native)
        return native
    }

    private func installCameraEffectsHandler(on native: WHZoomSDKBridge) {
        native.cameraEffectsChanged = { [weak self, weak native] data in
            MainActor.assumeIsolated {
                guard let self, let native, self.cameraEffectsOpen, self.bridge === native,
                      let status = try? Self.decodeCameraEffects(data) else { return }
                self.onCameraEffectsChanged?(status)
            }
        }
    }

    private func setNativePreferences(_ preferences: CameraEffectsPreferences, on native: WHZoomSDKBridge) {
        let (background, path) = Self.nativeBackground(preferences.background)
        native.setPreferredCameraEffects(background: background, imagePath: path, autoFraming: preferences.autoFraming)
    }

    private func applyNativeCameraEffects(_ preferences: CameraEffectsPreferences, native: WHZoomSDKBridge,
                                          requiresOpen: Bool = true) async throws -> CameraEffectsStatus {
        try Task.checkCancellation()
        installCameraEffectsHandler(on: native)
        let generation = cameraEffectsGeneration
        let expectedSession = sessionID
        let operation = UUID()
        cameraEffectsOperation = operation
        let (background, path) = Self.nativeBackground(preferences.background)
        let initialResult = native.applyCameraEffects(background: background, imagePath: path, autoFraming: preferences.autoFraming)
        let result = try await CameraEffectsConfirmation.wait(initialResult: initialResult,
            isPending: { native.cameraEffectsAwaitingConfirmation },
            isCurrent: { self.cameraEffectsGeneration == generation && self.cameraEffectsOperation == operation &&
                self.sessionID == expectedSession && self.bridge === native && native.cameraEffectsReady &&
                (!requiresOpen || self.cameraEffectsOpen) },
            confirm: { native.confirmCameraEffects(background: background, imagePath: path, autoFraming: preferences.autoFraming) })
        guard result == 0 else {
            throw MeetingError.unavailable(native.cameraEffectsError ?? "Zoom couldn’t apply the camera effects. Try again.")
        }
        let status = try Self.decodeCameraEffects(native.cameraEffectsSnapshot())
        guard status.appliedPreferences == preferences else {
            throw MeetingError.unavailable("Zoom hasn’t confirmed those camera effects yet. Try again before starting your camera.")
        }
        if cameraEffectsOpen { onCameraEffectsChanged?(status) }
        return status
    }

    private static func nativeBackground(_ choice: CameraBackgroundChoice) -> (String, String?) {
        switch choice {
        case .none: return ("none", nil)
        case .blur: return ("blur", nil)
        case .image(let path): return ("image", path)
        }
    }

    private static func decodeCameraEffects(_ data: Data) throws -> CameraEffectsStatus {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeetingError.unavailable("Zoom couldn’t report the camera settings. Try again.")
        }
        var preferences: CameraEffectsPreferences?
        if let applied = value["applied"] as? [String: Any], let kind = applied["background"] as? String {
            let choice: CameraBackgroundChoice?
            switch kind {
            case "none": choice = .some(.none)
            case "blur": choice = .blur
            case "image": choice = (applied["imagePath"] as? String).map { .image(path: $0) }
            default: choice = nil
            }
            if let choice { preferences = CameraEffectsPreferences(background: choice, autoFraming: applied["autoFraming"] as? Bool ?? false) }
        }
        return CameraEffectsStatus(supportsBlur: value["supportsBlur"] as? Bool ?? false,
            supportsImageBackgrounds: value["supportsImageBackgrounds"] as? Bool ?? false,
            canAddImages: value["canAddImages"] as? Bool ?? false,
            isInMeeting: value["isInMeeting"] as? Bool ?? false,
            isCameraOn: value["isCameraOn"] as? Bool ?? false,
            isPreviewing: value["isPreviewing"] as? Bool ?? false, appliedPreferences: preferences,
            previewError: value["previewError"] as? String)
    }

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
        case "roomShare":
            if let raw = value as? String, let stage = RoomShareStage(rawValue: raw) { onEvent?(id, .roomShare(stage)) }
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
                                                  height: item["videoHeight"] as? Double ?? 0),
                    isConferenceRoom: item["isConferenceRoom"] as? Bool ?? false,
                    isHandRaised: item["handRaised"] as? Bool ?? false)
            }
            onEvent?(id, .participants(people))
        case "chat", "chatEdited":
            guard let item = value as? [String: Any], let text = item["text"] as? String else { return }
            let externalID = item["id"] as? String ?? ""
            let messageID = externalID.isEmpty ? UUID() : chatIDs[externalID] ?? UUID()
            if !externalID.isEmpty { chatIDs[externalID] = messageID }
            let message = MeetingChatMessage(id: messageID, senderName: item["senderName"] as? String ?? "Participant",
                text: text, date: Date(timeIntervalSince1970: item["timestamp"] as? Double ?? Date().timeIntervalSince1970),
                isFromSelf: item["isFromSelf"] as? Bool ?? false, sdkID: externalID.isEmpty ? nil : externalID,
                threadID: (item["threadID"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                isReply: item["isReply"] as? Bool ?? false, canReply: item["canReply"] as? Bool ?? false,
                senderID: item["senderID"] as? String,
                recipient: decodeChatValue(MeetingChatRecipient.self, from: item["recipient"]) ?? MeetingChatRecipient(kind: .unavailable, name: "Unknown audience"),
                runs: decodeChatValue([MeetingChatTextRun].self, from: item["runs"]) ?? [],
                canDelete: item["canDelete"] as? Bool ?? false)
            onEvent?(id, event == "chatEdited" ? .messageUpdated(message) : .message(message))
        case "chatDeleted":
            if let externalID = value as? String, let messageID = chatIDs[externalID] {
                onEvent?(id, .messageRemoved(messageID))
            }
        case "chatLegalNotice":
            let item = value as? [String: String]
            onEvent?(id, .chatLegalNotice(item.map { MeetingChatLegalNotice(prompt: $0["prompt"] ?? "", explanation: $0["explanation"] ?? "") }))
        case "chatPolicy":
            if let policy = decodeChatValue(MeetingChatPolicy.self, from: value) { onEvent?(id, .chatPolicy(policy)) }
        case "chatAttachment":
            if let file = decodeChatValue(MeetingChatAttachment.self, from: value) { onEvent?(id, .chatAttachment(file)) }
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
                let target = MeetingShareSourceLabel.target(windowID: windowID, displayID: displayID, available: shareTargets, computerAudio: item["computerAudio"] as? Bool == true)
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
        mediaGeneration = UUID()
        lastMediaState = MeetingMediaState()
        onMediaDevicesChanged?(lastMediaState)
        cameraEffectsGeneration = UUID(); cameraPreviewGeneration = UUID()
        cameraPreparation?.cancel(); cameraPreparation = nil
        sessionID = nil; shareTargets = []; chatIDs = [:]; preparedHostMeetingNumber = nil
        bridge?.cameraEffectsChanged = nil
        bridge?.eventHandler = nil; bridge = nil
        if Self.activeOwner === self { Self.activeOwner = nil }
    }
}
#endif
