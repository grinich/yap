import AppKit
import Foundation
import Observation

@MainActor @Observable
public final class MeetingCoordinator {
    public private(set) var status: MeetingStatus = .idle
    public private(set) var participants: [MeetingParticipant] = []
    public private(set) var chatMessages: [MeetingChatMessage] = []
    public private(set) var chatLegalNotice: MeetingChatLegalNotice?
    public private(set) var meetingIndicators: [MeetingIndicator] = []
    public private(set) var sharing: MeetingSharingState = .idle
    public private(set) var receivedShares: [ReceivedMeetingShare] = []
    public private(set) var selectedReceivedShareID: String?
    public private(set) var waitingRoomParticipants: [WaitingRoomParticipant] = []
    public private(set) var isMicrophoneMuted = true
    public private(set) var isCameraEnabled = false
    public private(set) var videoQuality: MeetingVideoQuality?
    public private(set) var cloudRecording = MeetingCloudRecording()
    public private(set) var isApplyingCloudRecordingControl = false
    public private(set) var meetingTitle = ""
    public private(set) var isHost = false
    public private(set) var invitationURL: URL?
    public private(set) var lastError: String?
    public private(set) var sessionID: UUID?
    public private(set) var pageIndex = 0
    public private(set) var showsAllParticipants = false
    private var limitedPageSize = 100
    /// “Show all” follows the roster; this layout choice does not assert that
    /// the provider can deliver an unlimited number of simultaneous videos.
    public var pageSize: Int { showsAllParticipants ? max(1, participants.count) : limitedPageSize }
    public private(set) var isApplyingControl = false
    public let isDemo: Bool
    public let capabilities: MeetingCapabilities

    @ObservationIgnored private let driver: any MeetingDriver
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
    }

    public var isConnected: Bool { status == .inMeeting }
    public var selectedReceivedShare: ReceivedMeetingShare? {
        receivedShares.first { $0.id == selectedReceivedShareID }
    }
    public var pageCount: Int { max(1, (participants.count + pageSize - 1) / pageSize) }
    public var visibleParticipants: [MeetingParticipant] {
        let start = min(pageIndex * pageSize, participants.count)
        let end = min(start + pageSize, participants.count)
        return Array(participants[start..<end])
    }

    public func join(url: URL, displayName: String, title: String = "Zoom meeting") async {
        guard Self.isZoomMeetingURL(url) else {
            lastError = MeetingError.invalidLink.localizedDescription
            return
        }
        await connect(MeetingRequest(url: url, displayName: displayName, title: title, isHost: false))
    }

    public func host(displayName: String, title: String = "Instant meeting") async {
        await connect(MeetingRequest(url: nil, displayName: displayName, title: title, isHost: true))
    }

    private func connect(_ request: MeetingRequest) async {
        guard !Task.isCancelled else { return }
        guard !status.isActive else { lastError = MeetingError.alreadyInMeeting.localizedDescription; return }
        let trimmedName = request.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { lastError = MeetingError.invalidName.localizedDescription; return }
        resetSession()
        let newID = UUID()
        sessionID = newID
        meetingTitle = request.title
        // A request to host is not proof that Zoom granted the host role.
        isHost = false
        status = .connecting
        let normalizedRequest = MeetingRequest(url: request.url, displayName: trimmedName, title: request.title,
                                               isHost: request.isHost, microphoneMuted: true, cameraEnabled: false)
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
            lastError = error.localizedDescription
        }
    }

    public func leave(endForEveryone: Bool = false) async {
        guard let id = sessionID, status.isActive else { return }
        guard status != .leaving else { return }
        guard !endForEveryone || isHost else { lastError = MeetingError.hostRequired.localizedDescription; return }
        let previousStatus = status
        status = .leaving
        clearCloudRecordingCommand()
        do {
            try await driver.leave(sessionID: id, endForEveryone: endForEveryone)
            // Acceptance of a leave command is not proof that media has stopped.
            // The driver's terminal callback clears the session and allows a new join.
        } catch {
            guard sessionID == id else { return }
            status = previousStatus
            lastError = error.localizedDescription
        }
    }

    /// Used when closing the app: a timeout or cancellation must keep Whoosh alive
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
        await applyControl { driver, id in try await driver.setMicrophoneMuted(muted, sessionID: id) }
    }

    public func setCameraEnabled(_ enabled: Bool) async {
        await applyControl { driver, id in try await driver.setCameraEnabled(enabled, sessionID: id) }
    }

    /// Queued UI sends supply the session captured when the person pressed Send.
    /// An old draft must never be delivered to a replacement meeting.
    public func sendChat(text: String, sessionID expectedSessionID: UUID? = nil) async {
        guard !Task.isCancelled else { return }
        if let expectedSessionID, sessionID != expectedSessionID { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count <= 4_000 else { lastError = MeetingError.chatTooLong.localizedDescription; return }
        await applyControl(expectedSessionID: expectedSessionID) { driver, id in
            try await driver.sendChat(text: trimmed, sessionID: id)
        }
    }

    public func startShare(_ target: ShareTarget) async {
        await applyControl { driver, id in try await driver.startShare(target, sessionID: id) }
    }

    /// The chooser presents synchronous action errors locally. Keep unrelated
    /// asynchronous SDK errors in lastError for the application's normal alert.
    public func startShareFromChooser(_ target: ShareTarget) async throws {
        try Task.checkCancellation()
        guard let id = sessionID, status == .inMeeting else { throw MeetingError.noMeeting }
        guard !isApplyingControl else { throw MeetingError.operationInProgress }
        isApplyingControl = true
        defer { if sessionID == id { isApplyingControl = false } }
        do { try await driver.startShare(target, sessionID: id) }
        catch {
            guard !Task.isCancelled, sessionID == id, status == .inMeeting else { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard sessionID == id, status == .inMeeting else { throw CancellationError() }
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
        guard let id = sessionID, status == .inMeeting else { throw MeetingError.noMeeting }
        guard capabilities.canEnumerateShareTargets else { return [] }
        let targets: [ShareTarget]
        do { targets = try await driver.availableShareTargets(sessionID: id) }
        catch {
            guard !Task.isCancelled, sessionID == id, status == .inMeeting else { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard sessionID == id, status == .inMeeting else { throw CancellationError() }
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
        driver.setSelectedReceivedShare(sourceID)
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

    public func dismissError() { lastError = nil }

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
        case .status(let next):
            if next == .idle { resetSession() }
            else if next == .failed {
                resetSession()
                status = .failed
                lastError = "The meeting ended unexpectedly. Please try joining again."
            }
            else {
                status = next
                if next != .inMeeting { clearCloudRecordingCommand() }
            }
        case .participants(let updated):
            var seen: Set<String> = []
            participants = updated.filter { seen.insert($0.id).inserted }
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
                if chatMessages.count > 1_000 { chatMessages.removeFirst(chatMessages.count - 1_000) }
            }
        case .messageUpdated(let message):
            if let index = chatMessages.firstIndex(where: { $0.id == message.id }) { chatMessages[index] = message }
        case .messageRemoved(let id): chatMessages.removeAll { $0.id == id }
        case .microphoneMuted(let muted): isMicrophoneMuted = muted
        case .chatLegalNotice(let notice): chatLegalNotice = notice
        case .meetingIndicators(let updated):
            var seen: Set<String> = []
            meetingIndicators = updated.filter { seen.insert($0.id).inserted }
        case .cameraEnabled(let enabled): isCameraEnabled = enabled
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
                driver.setSelectedReceivedShare(selectedReceivedShareID)
            }
        case .waitingRoomParticipants(let updated):
            var seen: Set<String> = []
            waitingRoomParticipants = updated.filter { seen.insert($0.id).inserted }
        case .hostChanged(let host): isHost = host
        case .invitation(let url): invitationURL = url
        case .controlError(let message): lastError = message
        case .failure(let message):
            resetSession()
            status = .failed
            lastError = message
        }
    }

    private func updateVisibleSubscriptions() {
        driver.setVisibleParticipants(visibleParticipants.map(\.id))
    }

    private func resetSession() {
        sessionID = nil
        status = .idle
        participants = []
        chatMessages = []
        chatLegalNotice = nil
        meetingIndicators = []
        sharing = .idle
        receivedShares = []
        selectedReceivedShareID = nil
        waitingRoomParticipants = []
        isMicrophoneMuted = true
        isCameraEnabled = false
        videoQuality = nil
        cloudRecording = MeetingCloudRecording()
        clearCloudRecordingCommand()
        meetingTitle = ""
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
