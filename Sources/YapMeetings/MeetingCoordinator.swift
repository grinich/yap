import AppKit
import Foundation
import Observation

@MainActor @Observable
public final class MeetingCoordinator {
    public private(set) var status: MeetingStatus = .idle
    public private(set) var roomShareStage: RoomShareStage?
    public var isRoomShare: Bool { roomShareStage != nil }
    public var canChooseSharingContent: Bool {
        if isRoomShare { return status.isActive && status != .leaving && roomShareStage == .choosingContent }
        return status == .inMeeting
    }
    public private(set) var participants: [MeetingParticipant] = []
    public private(set) var unreadChatMessageIDs: Set<UUID> = []
    public private(set) var latestUnreadChatMessageID: UUID?
    @ObservationIgnored public var onUnreadChatMessage: (() -> Void)?
    private var isChatBeingRead = false

    public func setChatBeingRead(_ reading: Bool) {
        isChatBeingRead = reading
        if reading { unreadChatMessageIDs.removeAll() }
    }

    public private(set) var chatMessages: [MeetingChatMessage] = []
    public private(set) var chatLegalNotice: MeetingChatLegalNotice?
    public private(set) var chatPolicy = MeetingChatPolicy()
    public private(set) var chatAttachments: [MeetingChatAttachment] = []
    private var chatAttachmentUnreadIDs: [String: UUID] = [:]
    public var chatRecipients: [MeetingChatRecipient] {
        var result: [MeetingChatRecipient] = []
        if chatPolicy.canEveryone { result.append(.everyone) }
        if chatPolicy.canPanelists { result.append(.panelists) }
        if chatPolicy.canWaitingRoom { result.append(.waitingRoom) }
        if chatPolicy.canPrivate || chatPolicy.onlyHost {
            result += participants.filter { !$0.isSelf && (!chatPolicy.onlyHost || $0.isHost) }.map {
                MeetingChatRecipient(kind: .participant, participantID: $0.id, name: $0.name)
            }
        }
        return result
    }
    public func canChat(to recipient: MeetingChatRecipient) -> Bool {
        isConnected && capabilities.canChat && chatRecipients.contains { $0.id == recipient.id }
    }
    public private(set) var meetingIndicators: [MeetingIndicator] = []
    public private(set) var sharing: MeetingSharingState = .idle
    public private(set) var receivedShares: [ReceivedMeetingShare] = []
    private var lastViewedReceivedShareID: String?
    public private(set) var selectedReceivedShareID: String?
    public private(set) var waitingRoomParticipants: [WaitingRoomParticipant] = []
    public private(set) var isMicrophoneMuted = true
    public private(set) var isCameraEnabled = false
    public private(set) var mediaDevices = MeetingMediaState()
    public private(set) var isPreparingMediaDevices = false
    public private(set) var isApplyingMediaControl = false
    public private(set) var mediaDevicesError: String?
    @ObservationIgnored private var mediaOperation = UUID()
    public private(set) var videoQuality: MeetingVideoQuality?
    public private(set) var cloudRecording = MeetingCloudRecording()
    public private(set) var isApplyingCloudRecordingControl = false
    public private(set) var meetingTitle = ""
    public private(set) var scheduledInterval: DateInterval?
    public private(set) var isHost = false
    public private(set) var invitationURL: URL?
    public private(set) var lastError: String?
    public private(set) var failedRoomShare = false
    public private(set) var sessionID: UUID?
    public private(set) var pageIndex = 0
    public private(set) var layout: MeetingLayout = .gallery
    public private(set) var pinnedParticipantID: String?
    public private(set) var activeSpeakerID: String?
    public var hideSelfView = false {
        didSet {
            if hideSelfView, participants.contains(where: { $0.isSelf && $0.id == pinnedParticipantID }) {
                pinnedParticipantID = nil
            }
            pageIndex = 0
            updateVisibleSubscriptions()
        }
    }
    public var showNonVideoParticipants = false { didSet { pageIndex = 0; updateVisibleSubscriptions() } }
    private var recentSpeakerIDs: [String] = []
    private var markedRoomIDs: Set<String> = []
    public private(set) var shareStripCapacity = 6
    public var visibleShareStripParticipants: [MeetingParticipant] {
        shareStripParticipants(limit: shareStripCapacity)
    }
    /// Match native renderer allocation to the number of tiles the window can show.
    public func setShareStripCapacity(_ capacity: Int) {
        let normalized = max(2, capacity)
        guard shareStripCapacity != normalized else { return }
        shareStripCapacity = normalized
        if selectedReceivedShare != nil { updateVisibleSubscriptions() }
    }
    public func setConferenceRoom(_ id: String, enabled: Bool) {
        if enabled { markedRoomIDs.insert(id) } else { markedRoomIDs.remove(id) }
        updateVisibleSubscriptions()
    }
    public func isConferenceRoom(_ person: MeetingParticipant) -> Bool {
        person.isConferenceRoom || markedRoomIDs.contains(person.id)
    }
    private func isVisible(_ person: MeetingParticipant) -> Bool {
        if person.isSelf { return !hideSelfView && person.isCameraEnabled }
        return showNonVideoParticipants || person.isCameraEnabled
    }
    public var shareStripParticipants: [MeetingParticipant] {
        let eligible = participants.filter { isVisible($0) || (!$0.isSelf && $0.id == activeSpeakerID && $0.isSpeaking) }
        let local = eligible.filter(\.isSelf)
        let rooms = eligible.filter { !$0.isSelf && isConferenceRoom($0) }
        let others = eligible.filter { !$0.isSelf && !isConferenceRoom($0) }.sorted {
            (recentSpeakerIDs.firstIndex(of: $0.id) ?? Int.max) < (recentSpeakerIDs.firstIndex(of: $1.id) ?? Int.max)
        }
        return local + rooms + others
    }
    /// Reserve a slot for the current speaker even when room tiles fill the strip.
    public func shareStripParticipants(limit: Int) -> [MeetingParticipant] {
        let ordered = shareStripParticipants
        var result = Array(ordered.prefix(max(1, limit)))
        if let active = ordered.first(where: { $0.id == activeSpeakerID }), !result.contains(where: { $0.id == active.id }) {
            result[result.count - 1] = active
        }
        return result
    }
    private var galleryOrder: [String]?
    public private(set) var showsAllParticipants = false
    private var limitedPageSize = 100
    /// “Show all” follows the roster; this layout choice does not assert that
    /// the provider can deliver an unlimited number of simultaneous videos.
    public var pageSize: Int { showsAllParticipants ? max(1, participants.count) : limitedPageSize }
    public private(set) var isApplyingControl = false
    public let isDemo: Bool
    public let capabilities: MeetingCapabilities

    @ObservationIgnored private let driver: any MeetingDriver
    @ObservationIgnored private var isShutDown = false
    public var cameraEffectsDriver: (any CameraEffectsDriver)? { driver as? any CameraEffectsDriver }
    public var demoDriver: DemoMeetingDriver? { driver as? DemoMeetingDriver }
    @ObservationIgnored private let cloudRecordingConfirmationTimeout: Duration
    @ObservationIgnored private var cloudRecordingCommandID: UUID?
    @ObservationIgnored private var cloudRecordingExpectedStatus: MeetingCloudRecordingStatus?
    @ObservationIgnored private var cloudRecordingDeadline: Task<Void, Never>?

    public init(driver: any MeetingDriver = MissingZoomMeetingDriver(),
                cloudRecordingConfirmationTimeout: Duration = .seconds(10)) {
        self.driver = driver
        self.cloudRecordingConfirmationTimeout = cloudRecordingConfirmationTimeout
        self.isDemo = driver.isDemo
        self.capabilities = driver.capabilities
        driver.onEvent = { [weak self] sessionID, event in self?.receive(event, for: sessionID) }
        (driver as? any MeetingMediaDriver)?.onMediaDevicesChanged = { [weak self] state in
            guard let self, !self.isShutDown else { return }
            self.mediaDevices = state
            self.mediaDevicesError = state.error
        }
    }

    /// Preserve supplied titles; untitled one-to-one calls are identified by the other person.
    public var displayTitle: String {
        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if participants.count == 2, participants.contains(where: \.isSelf),
           let other = participants.first(where: { !$0.isSelf }) {
            let name = other.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return "Your meeting"
    }

    public var isConnected: Bool { status == .inMeeting }
    public var isHandRaised: Bool { participants.first(where: \.isSelf)?.isHandRaised ?? false }
    public var canRaiseHand: Bool { isConnected && !isRoomShare && participants.count > 1 && participants.contains(where: \.isSelf) }

    public func prepareMediaDevices() async {
        guard !isShutDown, !isPreparingMediaDevices, !isApplyingMediaControl else { return }
        guard let media = driver as? any MeetingMediaDriver else {
            mediaDevicesError = "Device controls aren’t available in this build."; return
        }
        let operation = UUID(), expectedSession = sessionID
        mediaOperation = operation; isPreparingMediaDevices = true; mediaDevicesError = nil
        defer { if mediaOperation == operation { isPreparingMediaDevices = false } }
        do {
            let state = try await media.prepareMediaDevices()
            guard !Task.isCancelled, mediaOperation == operation, sessionID == expectedSession else { return }
            mediaDevices = state
            mediaDevicesError = state.error
        } catch is CancellationError {} catch {
            if mediaOperation == operation, sessionID == expectedSession { mediaDevicesError = error.localizedDescription }
        }
    }

    public func selectMediaDevice(_ id: String, kind: MeetingMediaKind) async {
        guard mediaDevices.devices(for: kind).contains(where: { $0.id == id }) else {
            mediaDevicesError = "That device is no longer connected. Refresh the device list and choose another."; return
        }
        await applyMediaControl { try await $0.selectMediaDevice(id, kind: kind) }
    }

    public func setMediaVolume(_ volume: Int, kind: MeetingMediaKind) async {
        guard (0...100).contains(volume), kind != .camera else { return }
        await applyMediaControl { try await $0.setMediaVolume(volume, kind: kind) }
    }

    public func setAutomaticMicrophoneVolume(_ enabled: Bool) async {
        await applyMediaControl { try await $0.setAutomaticMicrophoneVolume(enabled) }
    }

    public func setMediaTest(_ kind: MeetingMediaKind, running: Bool) async {
        await applyMediaControl { try await $0.setMediaTest(kind, running: running) }
    }

    public func stopMediaTests() {
        mediaOperation = UUID(); isApplyingMediaControl = false; isPreparingMediaDevices = false
        (driver as? any MeetingMediaDriver)?.stopMediaTests()
    }

    /// Quit only after the normal leave path confirms that active media ended.
    /// Settings can initialize Zoom even when no meeting has ever been joined.
    @discardableResult public func shutdown() -> Bool {
        guard !status.isActive else { return false }
        guard !isShutDown else { return true }
        guard driver.shutdown() else { return false }
        isShutDown = true
        stopMediaTests()
        resetSession()
        driver.onEvent = nil
        (driver as? any MeetingMediaDriver)?.onMediaDevicesChanged = nil
        return true
    }

    private func applyMediaControl(_ operation: @MainActor (any MeetingMediaDriver) async throws -> MeetingMediaState) async {
        guard !isShutDown, mediaDevices.isReady, !isApplyingMediaControl, !isPreparingMediaDevices,
              let media = driver as? any MeetingMediaDriver else { return }
        let identifier = UUID(), expectedSession = sessionID
        mediaOperation = identifier; isApplyingMediaControl = true; mediaDevicesError = nil
        defer { if mediaOperation == identifier { isApplyingMediaControl = false } }
        do {
            let state = try await operation(media)
            guard !Task.isCancelled, mediaOperation == identifier, sessionID == expectedSession else { return }
            mediaDevices = state
            mediaDevicesError = state.error
        } catch is CancellationError {} catch {
            if mediaOperation == identifier, sessionID == expectedSession { mediaDevicesError = error.localizedDescription }
        }
    }
    public var selectedReceivedShare: ReceivedMeetingShare? {
        receivedShares.first { $0.id == selectedReceivedShareID }
    }
    public var presentationParticipant: MeetingParticipant? {
        let identifier = pinnedParticipantID ?? (layout == .activeSpeaker ? activeSpeakerID : nil)
        return participants.first { $0.id == identifier && (!$0.isSelf || !hideSelfView) }
    }
    public var oneToOneParticipants: (local: MeetingParticipant, remote: MeetingParticipant)? {
        guard selectedReceivedShareID == nil, participants.count == 2,
              let local = participants.first(where: \.isSelf),
              let remote = participants.first(where: { !$0.isSelf }),
              pinnedParticipantID != local.id else { return nil }
        return (local, remote)
    }
    public var pageCount: Int {
        selectedReceivedShare != nil || layout == .activeSpeaker || pinnedParticipantID != nil || oneToOneParticipants != nil ? 1 : max(1, (galleryParticipants.count + pageSize - 1) / pageSize)
    }
    /// Local to this meeting; never changes Zoom's roster or anyone else's view.
    public var galleryParticipants: [MeetingParticipant] {
        let visible = participants.filter { isVisible($0) }
        guard let galleryOrder else { return visible }
        let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        return galleryOrder.compactMap { byID[$0] }
    }
    public static let groupPhotoBatchSize = 49
    public private(set) var isTakingGroupPhoto = false
    private var groupPhotoSessionID: UUID?
    private var groupPhotoSnapshot: [MeetingParticipant] = []
    private var groupPhotoFailure: MeetingError?
    public private(set) var photoBatchParticipants: [MeetingParticipant] = []
    /// Freeze the complete camera-on gallery, including people on other pages.
    /// Later arrivals and newly enabled cameras belong to the next photo.
    public var photoParticipants: [MeetingParticipant] {
        isTakingGroupPhoto ? groupPhotoSnapshot : galleryParticipants.filter(\.isCameraEnabled)
    }

    @discardableResult
    public func beginGroupPhoto(sessionID expectedSessionID: UUID) throws -> [MeetingParticipant] {
        try Task.checkCancellation()
        guard sessionID == expectedSessionID, isConnected else { throw MeetingError.noMeeting }
        guard !isTakingGroupPhoto else { throw MeetingError.operationInProgress }
        let snapshot = galleryParticipants.filter(\.isCameraEnabled)
        guard !snapshot.isEmpty else {
            throw MeetingError.unavailable("Turn on a camera before taking a group photo.")
        }
        groupPhotoSessionID = expectedSessionID
        groupPhotoSnapshot = snapshot
        groupPhotoFailure = nil
        photoBatchParticipants = []
        isTakingGroupPhoto = true
        // Release the normal gallery before allocating the first bounded batch.
        updateVisibleSubscriptions()
        return snapshot
    }

    public func selectGroupPhotoBatch(participantIDs: [String], sessionID expectedSessionID: UUID) throws {
        try validateGroupPhoto(sessionID: expectedSessionID)
        guard !participantIDs.isEmpty, participantIDs.count <= Self.groupPhotoBatchSize,
              Set(participantIDs).count == participantIDs.count else {
            throw MeetingError.unavailable("A group photo can load up to 49 camera feeds at a time.")
        }
        let snapshotByID = Dictionary(uniqueKeysWithValues: groupPhotoSnapshot.map { ($0.id, $0) })
        let batch = participantIDs.compactMap { snapshotByID[$0] }
        guard batch.count == participantIDs.count else {
            throw MeetingError.unavailable("The group photo’s participants changed. Please try again.")
        }
        // Explicitly tear down every old renderer before subscribing to the next
        // batch, including when the caller did not clear the previous batch.
        clearGroupPhotoBatch(sessionID: expectedSessionID)
        try validateGroupPhoto(sessionID: expectedSessionID)
        photoBatchParticipants = batch
        updateVisibleSubscriptions()
    }

    /// Check again after waiting for frames, so a departed person or disabled
    /// camera can never become a blank tile or silently disappear from the photo.
    public func validateGroupPhotoBatch(sessionID expectedSessionID: UUID) throws {
        try validateGroupPhoto(sessionID: expectedSessionID)
        guard !photoBatchParticipants.isEmpty else {
            throw MeetingError.unavailable("The group photo is no longer ready. Please try again.")
        }
    }

    public func clearGroupPhotoBatch(sessionID expectedSessionID: UUID) {
        guard sessionID == expectedSessionID, groupPhotoSessionID == expectedSessionID, isTakingGroupPhoto else { return }
        photoBatchParticipants = []
        updateVisibleSubscriptions()
    }

    public func endGroupPhoto(sessionID expectedSessionID: UUID) {
        guard sessionID == expectedSessionID, groupPhotoSessionID == expectedSessionID else { return }
        clearGroupPhotoState()
        if isConnected { updateVisibleSubscriptions() }
        else { driver.setVisibleParticipants([]) }
    }

    private func validateGroupPhoto(sessionID expectedSessionID: UUID) throws {
        try Task.checkCancellation()
        guard sessionID == expectedSessionID, isConnected else { throw MeetingError.noMeeting }
        guard isTakingGroupPhoto, groupPhotoSessionID == expectedSessionID else {
            throw MeetingError.unavailable("The group photo was canceled. Please try again.")
        }
        reconcileGroupPhotoParticipants()
        if let groupPhotoFailure { throw groupPhotoFailure }
    }

    private func reconcileGroupPhotoParticipants() {
        guard isTakingGroupPhoto, groupPhotoFailure == nil else { return }
        let cameraIDs = Set(participants.lazy.filter(\.isCameraEnabled).map(\.id))
        guard groupPhotoSnapshot.contains(where: { !cameraIDs.contains($0.id) }) else { return }
        groupPhotoFailure = .unavailable("Someone in the group photo left the meeting or turned off their camera. Please try again.")
        photoBatchParticipants = []
        updateVisibleSubscriptions()
    }

    private func clearGroupPhotoState() {
        isTakingGroupPhoto = false
        groupPhotoSessionID = nil
        groupPhotoSnapshot = []
        groupPhotoFailure = nil
        photoBatchParticipants = []
    }
    public func preparePhotoShutter(_ pcm: Data) async throws {
        guard let sessionID, isConnected, !sharing.isSharing, receivedShares.isEmpty else {
            throw MeetingError.unavailable("The shared shutter sound is unavailable while someone is sharing.")
        }
        try await driver.preparePhotoShutter(pcm, sessionID: sessionID)
    }
    public var isPhotoShutterReady: Bool { driver.isPhotoShutterReady() }
    public func playPhotoShutter() -> Bool { driver.playPhotoShutter() }
    public func cancelPhotoShutter() { driver.cancelPhotoShutter() }

    public var visibleParticipants: [MeetingParticipant] {
        if isTakingGroupPhoto { return photoBatchParticipants }
        if selectedReceivedShare != nil { return visibleShareStripParticipants }
        if let pair = oneToOneParticipants { return [pair.remote] + (hideSelfView ? [] : [pair.local]) }
        if let primary = presentationParticipant {
            // Only the speaker and local corner self-view are rendered.
            return [primary] + participants.filter { $0.isSelf && !hideSelfView && $0.id != primary.id }
        }
        let start = min(pageIndex * pageSize, galleryParticipants.count)
        let end = min(start + pageSize, galleryParticipants.count)
        return Array(galleryParticipants[start..<end])
    }

    public func join(url: URL, displayName: String, title: String = "", scheduledInterval: DateInterval? = nil,
                     joinQuietly: Bool = true) async {
        guard Self.isZoomMeetingURL(url) else {
            lastError = MeetingError.invalidLink.localizedDescription
            return
        }
        await connect(MeetingRequest(url: url, displayName: displayName, title: title, isHost: false,
                                     microphoneMuted: joinQuietly, cameraEnabled: !joinQuietly, scheduledInterval: scheduledInterval))
    }

    public func updateCalendarContext(title: String, scheduledInterval: DateInterval?, sessionID: UUID) {
        guard self.sessionID == sessionID, status.isActive, status != .leaving else { return }
        meetingTitle = title
        self.scheduledInterval = scheduledInterval
    }

    public func host(displayName: String, title: String = "", joinQuietly: Bool = true) async {
        await connect(MeetingRequest(url: nil, displayName: displayName, title: title, isHost: true,
                                     microphoneMuted: joinQuietly, cameraEnabled: !joinQuietly))
    }

    public func shareToRoom(displayName: String) async {
        guard !isDemo else { lastError = "Exit preview to share to a Zoom Room."; return }
        await connect(MeetingRequest(url: nil, displayName: displayName, title: "Share screen", isHost: false, isRoomShare: true))
    }

    public func submitRoomSharingCode(_ code: String) async {
        guard let id = sessionID, status.isActive, status != .leaving,
              roomShareStage == .needsCode || roomShareStage == .invalidCode else { return }
        let normalized = code.filter { !$0.isWhitespace }.uppercased()
        guard !normalized.isEmpty, normalized.count <= 32,
              normalized.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            lastError = "Enter the sharing key or meeting ID shown on the room display."
            return
        }
        roomShareStage = .searching
        do { try await driver.submitRoomSharingCode(normalized, sessionID: id) }
        catch {
            guard sessionID == id, status != .leaving else { return }
            roomShareStage = .needsCode
            lastError = error.localizedDescription
        }
    }

    private func connect(_ request: MeetingRequest) async {
        guard !isShutDown, !Task.isCancelled else { return }
        guard !status.isActive else { lastError = MeetingError.alreadyInMeeting.localizedDescription; return }
        let trimmedName = request.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { lastError = MeetingError.invalidName.localizedDescription; return }
        resetSession()
        let newID = UUID()
        sessionID = newID
        meetingTitle = request.title
        scheduledInterval = request.scheduledInterval
        roomShareStage = request.isRoomShare ? .searching : nil
        // A request to host is not proof that Zoom granted the host role.
        isHost = false
        status = .connecting
        let normalizedRequest = MeetingRequest(url: request.url, displayName: trimmedName, title: request.title,
                                               isHost: request.isHost, microphoneMuted: request.isRoomShare || request.microphoneMuted,
                                               cameraEnabled: !request.isRoomShare && request.cameraEnabled,
                                               isRoomShare: request.isRoomShare, scheduledInterval: request.scheduledInterval)
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await driver.connect(normalizedRequest, sessionID: newID)
            } onCancel: { [weak self] in
                Task { @MainActor in
                    guard let self, self.sessionID == newID else { return }
                    await self.leave()
                }
            }
            if Task.isCancelled, sessionID == newID { await leave() }
        } catch is CancellationError {
            guard sessionID == newID, status != .leaving else { return }
            resetSession()
        } catch {
            guard sessionID == newID, status != .leaving else { return }
            resetSession()
            status = .failed
            failedRoomShare = request.isRoomShare
            lastError = error.localizedDescription
        }
    }

    public func leave(endForEveryone: Bool = false) async {
        guard let id = sessionID, status.isActive else { return }
        guard status != .leaving else { return }
        guard !endForEveryone || isHost else { lastError = MeetingError.hostRequired.localizedDescription; return }
        let previousStatus = status
        status = .leaving
        endGroupPhoto(sessionID: id)
        clearCloudRecordingCommand()
        do {
            try await driver.leave(sessionID: id, endForEveryone: endForEveryone)
            // Acceptance of a leave command is not proof that media has stopped.
            // The driver's terminal callback clears the session and allows a new join.
        } catch {
            guard sessionID == id else { return }
            status = previousStatus
            updateVisibleSubscriptions()
            lastError = error.localizedDescription
        }
    }

    /// Used when closing the app: a timeout or cancellation must keep Yap alive
    /// if the driver has not confirmed media teardown. A replacement call is never ignored.
    public func waitForMeetingEnd(timeout: Duration = .seconds(15)) async -> Bool {
        let waitingForSession = sessionID
        guard let waitingForSession else { return !status.isActive && !Task.isCancelled }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: max(.zero, timeout))
        while sessionID == waitingForSession && status.isActive {
            guard !Task.isCancelled, clock.now < deadline else { return false }
            do { try await Task.sleep(for: min(.milliseconds(100), clock.now.duration(to: deadline))) }
            catch { return false }
        }
        return sessionID == nil && !status.isActive && !Task.isCancelled
    }

    public func setMicrophoneMuted(_ muted: Bool) async {
        guard !isRoomShare || muted else { return }
        await applyControl { driver, id in try await driver.setMicrophoneMuted(muted, sessionID: id) }
    }

    public func setCameraEnabled(_ enabled: Bool) async {
        guard !isRoomShare || !enabled else { return }
        await applyControl { driver, id in try await driver.setCameraEnabled(enabled, sessionID: id) }
    }

    public func setHandRaised(_ raised: Bool) async {
        guard canRaiseHand else { return }
        await applyControl { driver, id in try await driver.setHandRaised(raised, sessionID: id) }
    }

    /// Queued UI sends supply the session captured when the person pressed Send.
    /// An old draft must never be delivered to a replacement meeting.
    public func sendChat(text: String, sessionID expectedSessionID: UUID? = nil, replyingTo: UUID? = nil,
                         recipient: MeetingChatRecipient = .everyone, runs: [MeetingChatTextRun] = []) async {
        guard !Task.isCancelled else { return }
        if let expectedSessionID, sessionID != expectedSessionID { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let content = runs.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
        guard content.count <= 4_000 else { lastError = MeetingError.chatTooLong.localizedDescription; return }
        await applyControl(expectedSessionID: expectedSessionID) { driver, id in
            var draft = MeetingChatDraft(text: content, recipient: recipient, runs: runs)
            guard draft.hasValidFormatting else { throw MeetingError.unavailable("Message formatting changed. Please try sending again.") }
            if let replyingTo {
                guard let message = self.chatMessages.first(where: { $0.id == replyingTo }),
                      let target = message.replyRecipient,
                      message.canReply || target.kind == .participant || target.kind == .waitingRoom else {
                    throw MeetingError.unavailable("This message can no longer be replied to.")
                }
                draft.recipient = target
                if message.canReply {
                    guard let sdkID = message.sdkID else { throw MeetingError.unavailable("This message can no longer be replied to.") }
                    draft.replyToSDKID = sdkID
                }
            }
            guard self.canChat(to: draft.recipient) else { throw MeetingError.unavailable("This recipient is no longer available, or the host has restricted chat. Choose a recipient before sending.") }
            try await driver.sendChat(draft, sessionID: id)
        }
    }

    public func deleteChat(_ message: MeetingChatMessage, sessionID expectedSessionID: UUID?) async {
        await applyControl(expectedSessionID: expectedSessionID) { driver, id in
            guard let current = self.chatMessages.first(where: { $0.id == message.id }), current.isFromSelf,
                  current.canDelete, let sdkID = current.sdkID else { throw MeetingError.unavailable("This message can no longer be deleted.") }
            try await driver.deleteChat(messageID: sdkID, sessionID: id)
        }
    }

    public func sendChatFile(_ url: URL, recipient: MeetingChatRecipient, sessionID expectedSessionID: UUID?) async {
        await applyControl(expectedSessionID: expectedSessionID) { driver, id in
            guard self.chatPolicy.canTransferFiles, self.canChat(to: recipient),
                  recipient.kind == .everyone || recipient.kind == .participant else {
                throw MeetingError.unavailable("File sharing isn’t available for this recipient.")
            }
            try MeetingChatFileValidation.validate(url, policy: self.chatPolicy)
            try await driver.sendChatFile(url, recipient: recipient, sessionID: id)
        }
    }

    public func receiveChatFile(_ attachmentID: String, to url: URL, sessionID expectedSessionID: UUID?) async {
        await applyControl(expectedSessionID: expectedSessionID) { driver, id in
            guard let file = self.chatAttachments.first(where: { $0.id == attachmentID }), !file.isFromSelf,
                  file.status == .available || file.status == .failed || file.status == .cancelled else { throw MeetingError.unavailable("This file is no longer available to download.") }
            try await driver.receiveChatFile(attachmentID, to: url, sessionID: id)
        }
    }

    public func cancelChatFile(_ attachmentID: String, sessionID expectedSessionID: UUID?) async {
        await applyControl(expectedSessionID: expectedSessionID) { driver, id in
            guard self.chatAttachments.contains(where: { $0.id == attachmentID && $0.status == .transferring }) else { return }
            try await driver.cancelChatFile(attachmentID, sessionID: id)
        }
    }

    public func startShare(_ target: ShareTarget) async {
        await applyControl { driver, id in try await driver.startShare(target, sessionID: id) }
    }

    /// The chooser presents synchronous action errors locally. Keep unrelated
    /// asynchronous SDK errors in lastError for the application's normal alert.
    public func startShareFromChooser(_ target: ShareTarget) async throws {
        try Task.checkCancellation()
        guard let id = sessionID, canChooseSharingContent else { throw MeetingError.noMeeting }
        if let current = sharing.target, (current.kind == .computerAudio) != (target.kind == .computerAudio) {
            throw MeetingError.unavailable("Stop your current share before switching between computer audio and a screen or window.")
        }
        guard !isApplyingControl else { throw MeetingError.operationInProgress }
        isApplyingControl = true
        defer { if sessionID == id { isApplyingControl = false } }
        do { try await driver.startShare(target, sessionID: id) }
        catch {
            guard !Task.isCancelled, sessionID == id, canChooseSharingContent else { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard sessionID == id, canChooseSharingContent else { throw CancellationError() }
    }

    public func stopShare() async {
        guard sharing.isSharing else { return }
        await applyControl { driver, id in try await driver.stopShare(sessionID: id) }
    }

    public func startCloudRecording() async {
        await applyCloudRecordingControl(from: [.stopped], expecting: .recording) {
            try await $0.startCloudRecording(sessionID: $1)
        }
    }

    public func pauseCloudRecording() async {
        await applyCloudRecordingControl(from: [.recording], expecting: .paused) {
            try await $0.pauseCloudRecording(sessionID: $1)
        }
    }

    public func resumeCloudRecording() async {
        await applyCloudRecordingControl(from: [.paused], expecting: .recording) {
            try await $0.resumeCloudRecording(sessionID: $1)
        }
    }

    public func stopCloudRecording() async {
        await applyCloudRecordingControl(from: [.recording, .paused], expecting: .stopped) {
            try await $0.stopCloudRecording(sessionID: $1)
        }
    }

    private func applyCloudRecordingControl(from allowed: [MeetingCloudRecordingStatus],
        expecting expected: MeetingCloudRecordingStatus,
        operation: @MainActor (any MeetingDriver, UUID) async throws -> Void) async {
        guard !Task.isCancelled else { return }
        guard let id = sessionID, isConnected else { lastError = MeetingError.noMeeting.localizedDescription; return }
        guard !isApplyingCloudRecordingControl else { return }
        guard cloudRecording.canControl else {
            lastError = cloudRecording.unavailableReason ?? "Zoom hasn’t enabled cloud recording controls for you in this meeting."
            return
        }
        guard allowed.contains(cloudRecording.status) else { return }
        let commandID = UUID()
        cloudRecordingCommandID = commandID
        cloudRecordingExpectedStatus = expected
        isApplyingCloudRecordingControl = true
        lastError = nil
        let timeout = cloudRecordingConfirmationTimeout
        cloudRecordingDeadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.sessionID == id, self.cloudRecordingCommandID == commandID else { return }
            self.clearCloudRecordingCommand()
            self.lastError = "Zoom hasn’t confirmed the recording change. Check the recording indicator and try again."
        }
        do { try await operation(driver, id) }
        catch {
            guard sessionID == id, cloudRecordingCommandID == commandID else { return }
            clearCloudRecordingCommand()
            lastError = error.localizedDescription
        }
        // A successful command only acknowledges the request. State changes arrive from Zoom.
    }

    private func clearCloudRecordingCommand() {
        cloudRecordingDeadline?.cancel()
        cloudRecordingDeadline = nil
        cloudRecordingCommandID = nil
        cloudRecordingExpectedStatus = nil
        isApplyingCloudRecordingControl = false
    }

    public func loadAvailableShareTargets() async -> [ShareTarget] {
        guard let id = sessionID, status == .inMeeting else {
            lastError = MeetingError.noMeeting.localizedDescription
            return []
        }
        guard capabilities.canEnumerateShareTargets else { return [] }
        lastError = nil
        do {
            return try await availableShareTargetsForChooser()
        } catch is CancellationError { return [] }
        catch {
            if sessionID == id, status == .inMeeting { lastError = error.localizedDescription }
            return []
        }
    }

    /// Returns source errors to the presenting chooser without setting or
    /// clearing the meeting-wide error. Selection never starts capture.
    public func availableShareTargetsForChooser() async throws -> [ShareTarget] {
        try Task.checkCancellation()
        guard let id = sessionID, canChooseSharingContent else { throw MeetingError.noMeeting }
        guard capabilities.canEnumerateShareTargets else { return [] }
        let targets: [ShareTarget]
        do { targets = try await driver.availableShareTargets(sessionID: id) }
        catch {
            guard !Task.isCancelled, sessionID == id, canChooseSharingContent else { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard sessionID == id, canChooseSharingContent else { throw CancellationError() }
        var seen: Set<String> = []
        return targets.filter {
            (isDemo || $0.kind != .demo) && seen.insert("\($0.kind.rawValue):\($0.id)").inserted
        }
    }

    public func admitParticipant(_ participantID: String) async {
        guard capabilities.canAdmitParticipants, isHost else {
            lastError = "Only the host can admit people from the waiting room."
            return
        }
        guard waitingRoomParticipants.contains(where: { $0.id == participantID }) else {
            lastError = MeetingError.participantNoLongerWaiting.localizedDescription
            return
        }
        await applyControl { driver, id in try await driver.admitParticipant(participantID, sessionID: id) }
    }

    public func selectReceivedShare(_ sourceID: String?) {
        guard sourceID == nil || (status == .inMeeting && receivedShares.contains { $0.id == sourceID }) else { return }
        selectedReceivedShareID = sourceID
        if let sourceID { lastViewedReceivedShareID = sourceID }
        driver.setSelectedReceivedShare(sourceID)
        updateVisibleSubscriptions()
    }

    public func toggleSharedContent() {
        guard isConnected, capabilities.canReceiveShare, !receivedShares.isEmpty else { return }
        if selectedReceivedShareID != nil {
            selectReceivedShare(nil)
        } else {
            let previous = receivedShares.first { $0.id == lastViewedReceivedShareID }
            selectReceivedShare((previous ?? receivedShares[0]).id)
        }
    }

    public func nativeShareView(for sourceID: String) -> NSView? {
        guard status == .inMeeting, sourceID == selectedReceivedShareID,
              receivedShares.contains(where: { $0.id == sourceID }) else { return nil }
        return driver.nativeShareView(for: sourceID)
    }

    public func showMeetingIndicator(_ indicatorID: String) async {
        guard meetingIndicators.contains(where: { $0.id == indicatorID }) else { return }
        await applyControl { driver, id in try await driver.showMeetingIndicator(indicatorID, sessionID: id) }
    }

    private func applyControl(expectedSessionID: UUID? = nil,
        _ operation: @MainActor (any MeetingDriver, UUID) async throws -> Void) async {
        guard !Task.isCancelled else { return }
        if let expectedSessionID, sessionID != expectedSessionID { return }
        guard let id = sessionID, status == .inMeeting else { lastError = MeetingError.noMeeting.localizedDescription; return }
        guard !isApplyingControl else { lastError = MeetingError.operationInProgress.localizedDescription; return }
        isApplyingControl = true
        lastError = nil
        defer { if sessionID == id { isApplyingControl = false } }
        do { try await operation(driver, id) }
        catch { if sessionID == id { lastError = error.localizedDescription } }
    }

    public func dismissError() { lastError = nil; failedRoomShare = false }

    public func setLayout(_ layout: MeetingLayout) {
        self.layout = layout
        pinnedParticipantID = nil
        pageIndex = 0
        reconcileActiveSpeaker()
        selectReceivedShare(nil)
        updateVisibleSubscriptions()
    }

    /// Insert at the target's current slot, shifting the intervening tiles.
    /// A drag from an ended meeting must not reorder a replacement meeting.
    @discardableResult
    public func moveGalleryParticipant(_ identifier: String, to targetID: String, sessionID expectedSessionID: UUID) -> Bool {
        guard sessionID == expectedSessionID, isConnected, layout == .gallery,
              pinnedParticipantID == nil, selectedReceivedShareID == nil,
              oneToOneParticipants == nil else { return false }
        let visibleIDs = Set(galleryParticipants.map(\.id))
        guard visibleIDs.contains(identifier), visibleIDs.contains(targetID) else { return false }
        // Keep hidden people in the order so showing self or non-video tiles
        // works immediately, without waiting for another Zoom roster callback.
        var order = galleryOrder ?? participants.map(\.id)
        guard let source = order.firstIndex(of: identifier), let target = order.firstIndex(of: targetID),
              source != target else { return false }
        order.insert(order.remove(at: source), at: target)
        galleryOrder = order
        updateVisibleSubscriptions()
        return true
    }

    private func reconcileGalleryOrder() {
        guard let galleryOrder else { return }
        let present = Set(participants.map(\.id))
        var retained = galleryOrder.filter { present.contains($0) }
        let known = Set(retained)
        retained.append(contentsOf: participants.lazy.map(\.id).filter { !known.contains($0) })
        self.galleryOrder = retained
    }

    public func setPinnedParticipant(_ identifier: String?) {
        pinnedParticipantID = identifier.flatMap { id in
            participants.contains { $0.id == id && (!$0.isSelf || !hideSelfView) } ? id : nil
        }
        pageIndex = 0
        if pinnedParticipantID != nil { selectReceivedShare(nil) }
        updateVisibleSubscriptions()
    }

    private func reconcileActiveSpeaker() {
        if let pinnedParticipantID, !participants.contains(where: { $0.id == pinnedParticipantID }) {
            self.pinnedParticipantID = nil
        }
        // Like a conversation view, show the other participants while they are
        // present; keep self available in the strip and as the solo fallback.
        let others = participants.filter { !$0.isSelf }
        let candidates = others.isEmpty ? participants : others
        let speaking = candidates.filter { $0.isSpeaking && !$0.isMuted }.map(\.id)
        let present = Set(participants.map(\.id))
        recentSpeakerIDs = speaking + recentSpeakerIDs.filter { present.contains($0) && !speaking.contains($0) }
        let current = candidates.first { $0.id == activeSpeakerID }
        if let current, current.isSpeaking && !current.isMuted { return }
        activeSpeakerID = candidates.first(where: { $0.isSpeaking && !$0.isMuted })?.id
            ?? current?.id ?? candidates.first(where: \.isCameraEnabled)?.id ?? candidates.first?.id
    }

    public func setPageSize(_ size: Int) {
        showsAllParticipants = false
        limitedPageSize = max(1, min(size, 1_000))
        pageIndex = min(pageIndex, pageCount - 1)
        updateVisibleSubscriptions()
    }

    public func showAllParticipants() {
        showsAllParticipants = true
        pageIndex = 0
        updateVisibleSubscriptions()
    }

    public func setPage(_ index: Int) {
        pageIndex = max(0, min(index, pageCount - 1))
        updateVisibleSubscriptions()
    }

    public func nativeVideoView(for participantID: String) -> NSView? {
        guard status == .inMeeting, visibleParticipants.contains(where: { $0.id == participantID }) else { return nil }
        return driver.nativeVideoView(for: participantID)
    }

    public func isVideoReadyForCapture(for participantID: String) -> Bool {
        guard isConnected, visibleParticipants.contains(where: { $0.id == participantID && $0.isCameraEnabled }) else { return false }
        return driver.isVideoReadyForCapture(for: participantID)
    }

    public func setDemoParticipantCount(_ count: Int) {
        (driver as? DemoMeetingDriver)?.setParticipantCount(count)
    }

    private func receive(_ event: MeetingDriverEvent, for incomingID: UUID) {
        guard incomingID == sessionID else { return }
        // Once leaving, only terminal callbacks are accepted. A late join success must not reopen a call.
        if status == .leaving {
            switch event {
            case .status(.idle), .status(.failed), .failure, .controlError: break
            default: return
            }
        }
        switch event {
        case .roomShare(let stage):
            if isRoomShare { roomShareStage = stage }
        case .status(let next):
            if next == .idle { resetSession() }
            else if next == .failed {
                let wasRoomShare = isRoomShare
                resetSession()
                status = .failed
                failedRoomShare = wasRoomShare
                lastError = wasRoomShare ? "Room sharing ended unexpectedly. You can try again or share using Zoom Workplace." : "The meeting ended unexpectedly. Please try joining again."
            }
            else {
                status = next
                if next != .inMeeting {
                    endGroupPhoto(sessionID: incomingID)
                    clearCloudRecordingCommand()
                } else {
                    updateVisibleSubscriptions()
                }
            }
        case .participants(let updated):
            var seen: Set<String> = []
            participants = updated.filter { seen.insert($0.id).inserted }
            reconcileGroupPhotoParticipants()
            reconcileGalleryOrder()
            reconcileActiveSpeaker()
            if let local = participants.first(where: \.isSelf) {
                isHost = local.isHost
                isMicrophoneMuted = local.isMuted
                isCameraEnabled = local.isCameraEnabled
            }
            pageIndex = min(pageIndex, pageCount - 1)
            updateVisibleSubscriptions()
        case .message(let message):
            if !chatMessages.contains(where: { $0.id == message.id }) {
                chatMessages.append(message)
                if !message.isFromSelf && !isChatBeingRead {
                    unreadChatMessageIDs.insert(message.id)
                    latestUnreadChatMessageID = message.id
                    onUnreadChatMessage?()
                }
                if chatMessages.count > 1_000 { chatMessages.removeFirst(chatMessages.count - 1_000) }
            }
        case .messageUpdated(let message):
            if let index = chatMessages.firstIndex(where: { $0.id == message.id }) { chatMessages[index] = message }
        case .messageRemoved(let id):
            chatMessages.removeAll { $0.id == id }
            unreadChatMessageIDs.remove(id)
        case .microphoneMuted(let muted): isMicrophoneMuted = muted
        case .chatLegalNotice(let notice): chatLegalNotice = notice
        case .chatPolicy(let policy): chatPolicy = policy
        case .chatAttachment(let file):
            if let index = chatAttachments.firstIndex(where: { $0.id == file.id }) { chatAttachments[index] = file }
            else {
                chatAttachments.append(file)
                if !file.isFromSelf && !isChatBeingRead {
                    let unreadID = chatAttachmentUnreadIDs[file.id] ?? UUID()
                    chatAttachmentUnreadIDs[file.id] = unreadID
                    unreadChatMessageIDs.insert(unreadID)
                    latestUnreadChatMessageID = unreadID
                    onUnreadChatMessage?()
                }
            }
        case .meetingIndicators(let updated):
            var seen: Set<String> = []
            meetingIndicators = updated.filter { seen.insert($0.id).inserted }
        case .cameraEnabled(let enabled):
            isCameraEnabled = enabled
            if !enabled, isTakingGroupPhoto, groupPhotoSnapshot.contains(where: \.isSelf) {
                groupPhotoFailure = .unavailable("Someone in the group photo left the meeting or turned off their camera. Please try again.")
                photoBatchParticipants = []
                updateVisibleSubscriptions()
            }
        case .videoQuality(let quality): videoQuality = quality
        case .cloudRecording(let state):
            cloudRecording = state
            if state.status == cloudRecordingExpectedStatus || !state.canControl {
                clearCloudRecordingCommand()
            }
        case .cloudRecordingControlError(let message):
            clearCloudRecordingCommand()
            lastError = message
        case .sharing(let state): sharing = state
        case .receivedShares(let updated):
            let hadNoShares = receivedShares.isEmpty
            let selectedSourceDisappeared = selectedReceivedShareID != nil && !updated.contains { $0.id == selectedReceivedShareID }
            var seen: Set<String> = []
            receivedShares = updated.filter { seen.insert($0.id).inserted }
            // An explicit Show people selection stays put across metadata updates.
            // Select automatically only for a new sharing session or a disappearing selected source.
            if selectedSourceDisappeared || (hadNoShares && !receivedShares.isEmpty) {
                selectedReceivedShareID = receivedShares.first?.id
                if let selectedReceivedShareID { lastViewedReceivedShareID = selectedReceivedShareID }
                driver.setSelectedReceivedShare(selectedReceivedShareID)
            }
            updateVisibleSubscriptions()
        case .waitingRoomParticipants(let updated):
            var seen: Set<String> = []
            waitingRoomParticipants = updated.filter { seen.insert($0.id).inserted }
        case .hostChanged(let host): isHost = host
        case .invitation(let url): invitationURL = url
        case .controlError(let message): lastError = message
        case .failure(let message):
            let wasRoomShare = isRoomShare
            resetSession()
            status = .failed
            failedRoomShare = wasRoomShare
            lastError = message
        }
    }

    private func updateVisibleSubscriptions() {
        driver.setVisibleParticipants(visibleParticipants.map(\.id))
    }

    private func resetSession() {
        mediaOperation = UUID()
        isPreparingMediaDevices = false; isApplyingMediaControl = false
        mediaDevices = MeetingMediaState(); mediaDevicesError = nil
        failedRoomShare = false
        roomShareStage = nil
        sessionID = nil
        status = .idle
        participants = []
        galleryOrder = nil
        pinnedParticipantID = nil
        activeSpeakerID = nil
        recentSpeakerIDs = []
        markedRoomIDs = []
        clearGroupPhotoState()
        chatMessages = []
        chatAttachments = []
        chatAttachmentUnreadIDs = [:]
        chatPolicy = MeetingChatPolicy()
        unreadChatMessageIDs.removeAll()
        latestUnreadChatMessageID = nil
        isChatBeingRead = false
        chatLegalNotice = nil
        meetingIndicators = []
        sharing = .idle
        receivedShares = []
        selectedReceivedShareID = nil
        lastViewedReceivedShareID = nil
        waitingRoomParticipants = []
        isMicrophoneMuted = true
        isCameraEnabled = false
        videoQuality = nil
        cloudRecording = MeetingCloudRecording()
        clearCloudRecordingCommand()
        meetingTitle = ""
        scheduledInterval = nil
        isHost = false
        invitationURL = nil
        lastError = nil
        pageIndex = 0
        isApplyingControl = false
        driver.setVisibleParticipants([])
        driver.setSelectedReceivedShare(nil)
    }

    public nonisolated static func isZoomMeetingURL(_ url: URL) -> Bool {
        (try? ZoomMeetingLink(url)) != nil
    }
}
