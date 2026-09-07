import Foundation
import Testing
@testable import WhooshMeetings

@Suite("Meeting session safety") @MainActor
struct MeetingCoordinatorTests {
    private let meetingURL = URL(string: "https://example.zoom.us/j/12345678901?pwd=fixture")!

    @Test func liveServiceDoesNotPretendToConnect() async {
        let coordinator = MeetingCoordinator()
        await coordinator.join(url: meetingURL, displayName: "Test")
        #expect(coordinator.status == .failed)
        #expect(!coordinator.isDemo)
        #expect(!coordinator.isConnected)
        #expect(!coordinator.capabilities.canJoin)
        #expect(coordinator.participants.isEmpty)
        #expect(coordinator.lastError == MissingZoomMeetingDriver.setupMessage)
        #expect(coordinator.sessionID == nil)
    }

    @Test func hostControlsChatSharingAndLeave() async {
        let coordinator = MeetingCoordinator(driver: DemoMeetingDriver(participantCount: 3))
        await coordinator.host(displayName: "  Test Person  ", title: "Design review")
        #expect(coordinator.status == .inMeeting)
        #expect(coordinator.isHost)
        #expect(coordinator.isMicrophoneMuted)
        #expect(!coordinator.isCameraEnabled)
        #expect(coordinator.participants.first?.name == "Test Person")
        #expect(coordinator.meetingTitle == "Design review")
        await coordinator.setMicrophoneMuted(false)
        await coordinator.setCameraEnabled(true)
        #expect(!coordinator.isMicrophoneMuted)
        #expect(coordinator.isCameraEnabled)
        await coordinator.sendChat(text: "  Hello  ")
        #expect(coordinator.chatMessages.last?.text == "Hello")
        #expect(coordinator.chatMessages.last?.isFromSelf == true)
        await coordinator.startShare(ShareTarget(id: "preview", title: "Test window", kind: .window))
        #expect(coordinator.sharing.target?.kind == .demo)
        await coordinator.stopShare()
        #expect(coordinator.sharing == .idle)
        await coordinator.leave(endForEveryone: true)
        #expect(coordinator.status == .idle)
        #expect(coordinator.participants.isEmpty)
        #expect(coordinator.chatMessages.isEmpty)
        #expect(coordinator.isMicrophoneMuted)
        #expect(!coordinator.isCameraEnabled)
        #expect(coordinator.sessionID == nil)
    }

    @Test func participantCannotEndMeetingForEveryone() async {
        let coordinator = MeetingCoordinator(driver: DemoMeetingDriver())
        await coordinator.join(url: meetingURL, displayName: "Guest")
        await coordinator.leave(endForEveryone: true)
        #expect(coordinator.status == .inMeeting)
        #expect(coordinator.lastError == MeetingError.hostRequired.localizedDescription)
        await coordinator.leave()
        #expect(coordinator.status == .idle)
    }

    @Test func repeatedJoinDoesNotReplaceExistingCall() async {
        let coordinator = MeetingCoordinator(driver: DemoMeetingDriver())
        await coordinator.host(displayName: "Host", title: "Existing")
        let sessionID = coordinator.sessionID
        await coordinator.join(url: meetingURL, displayName: "Guest", title: "New")
        #expect(coordinator.sessionID == sessionID)
        #expect(coordinator.meetingTitle == "Existing")
        #expect(coordinator.lastError == MeetingError.alreadyInMeeting.localizedDescription)
    }

    @Test func staleCallbacksCannotReopenOrUnmuteAnotherCall() async {
        let driver = DemoMeetingDriver()
        let coordinator = MeetingCoordinator(driver: driver)
        await coordinator.host(displayName: "Host")
        let staleID = coordinator.sessionID!
        await coordinator.leave()
        await coordinator.host(displayName: "Host")
        driver.onEvent?(staleID, .microphoneMuted(false))
        driver.onEvent?(staleID, .status(.idle))
        driver.onEvent?(staleID, .failure("Old connection failed"))
        #expect(coordinator.isMicrophoneMuted)
        #expect(coordinator.status == .inMeeting)
        #expect(coordinator.lastError == nil)
        #expect(coordinator.sessionID != staleID)
    }

    @Test func defaultPageShows100AndPaginatesLargerMockGridsWithoutClaimingLiveCapacity() async {
        let driver = DemoMeetingDriver(participantCount: 144)
        let coordinator = MeetingCoordinator(driver: driver)
        await coordinator.host(displayName: "Test")
        #expect(coordinator.pageSize == 100)
        #expect(coordinator.participants.count == 144)
        #expect(coordinator.visibleParticipants.count == 100)
        #expect(coordinator.pageCount == 2)
        #expect(Set(driver.visibleParticipantIDs).count == 100)
        #expect(coordinator.capabilities.confirmedLiveVideoLimit == nil)
        #expect(!coordinator.capabilities.supportsNativeVideo)
        coordinator.setPage(1)
        #expect(coordinator.visibleParticipants.count == 44)
        #expect(coordinator.visibleParticipants.first?.id == "demo-100")
        coordinator.setDemoParticipantCount(3)
        #expect(coordinator.pageIndex == 0)
        #expect(coordinator.visibleParticipants.count == 3)
        coordinator.setPageSize(0)
        coordinator.setPage(99)
        #expect(coordinator.pageSize == 1)
        #expect(coordinator.pageIndex == 2)
        #expect(coordinator.visibleParticipants.count == 1)
    }

    @Test func showAllFollowsRosterChangesAndClearsTheOldPage() async throws {
        let driver = DemoMeetingDriver(participantCount: 144)
        let coordinator = MeetingCoordinator(driver: driver)
        await coordinator.host(displayName: "Test")
        coordinator.setPage(1)
        coordinator.showAllParticipants()
        #expect(coordinator.showsAllParticipants)
        #expect(coordinator.pageIndex == 0)
        #expect(coordinator.pageCount == 1)
        #expect(coordinator.visibleParticipants.count == 144)
        #expect(driver.visibleParticipantIDs == coordinator.participants.map(\.id))

        coordinator.setDemoParticipantCount(244)
        coordinator.setPage(999)
        #expect(coordinator.pageIndex == 0)
        #expect(coordinator.pageCount == 1)
        #expect(coordinator.pageSize == 244)
        #expect(driver.visibleParticipantIDs.count == 244)
        coordinator.setDemoParticipantCount(3)
        #expect(coordinator.visibleParticipants.count == 3)
        #expect(driver.visibleParticipantIDs.count == 3)

        let session = try #require(coordinator.sessionID)
        driver.onEvent?(session, .participants([]))
        #expect(coordinator.pageSize == 1)
        #expect(coordinator.pageCount == 1)
        #expect(coordinator.visibleParticipants.isEmpty)
        #expect(driver.visibleParticipantIDs.isEmpty)
    }

    @Test(arguments: [25, 49, 100])
    func selectingPageSizeRestoresPagingAfterShowAll(_ size: Int) async {
        let driver = DemoMeetingDriver(participantCount: 240)
        let coordinator = MeetingCoordinator(driver: driver)
        await coordinator.host(displayName: "Test")
        coordinator.showAllParticipants()
        coordinator.setPageSize(size)
        #expect(!coordinator.showsAllParticipants)
        #expect(coordinator.pageSize == size)
        #expect(coordinator.visibleParticipants.count == size)
        #expect(driver.visibleParticipantIDs.count == size)
        coordinator.setPage(1)
        #expect(coordinator.pageIndex == 1)
        #expect(coordinator.visibleParticipants.first?.id == "demo-\(size)")
        #expect(driver.visibleParticipantIDs == coordinator.visibleParticipants.map(\.id))
    }

    @Test func showAllCanBeSelectedBeforeJoiningAndSurvivesSessionReset() async throws {
        let driver = DemoMeetingDriver(participantCount: 144)
        let coordinator = MeetingCoordinator(driver: driver)
        coordinator.showAllParticipants()
        #expect(coordinator.pageSize == 1)
        await coordinator.host(displayName: "Test")
        let oldSession = try #require(coordinator.sessionID)
        // Model a provider roster larger than the demo driver's sample cap.
        let largeRoster = (0..<1_205).map { MeetingParticipant(id: "fixture-\($0)", name: "Person \($0)") }
        driver.onEvent?(oldSession, .participants(largeRoster))
        #expect(coordinator.visibleParticipants.count == 1_205)
        #expect(coordinator.pageCount == 1)
        #expect(driver.visibleParticipantIDs.count == 1_205)
        #expect(coordinator.capabilities.confirmedLiveVideoLimit == nil)
        await coordinator.leave()
        #expect(coordinator.showsAllParticipants)
        #expect(coordinator.pageIndex == 0)
        #expect(driver.visibleParticipantIDs.isEmpty)
        await coordinator.host(displayName: "Test")
        driver.onEvent?(oldSession, .participants(largeRoster))
        #expect(coordinator.visibleParticipants.count == 144)
        #expect(driver.visibleParticipantIDs.count == 144)
        #expect(coordinator.pageCount == 1)
    }

    @Test func queuedChatCannotSendAnOldDraftIntoAReplacementMeeting() async throws {
        let coordinator = MeetingCoordinator(driver: DemoMeetingDriver(participantCount: 2))
        await coordinator.host(displayName: "Test")
        let originalSession = try #require(coordinator.sessionID)
        await coordinator.leave()
        await coordinator.host(displayName: "Test")
        let replacementSession = try #require(coordinator.sessionID)
        let originalMessages = coordinator.chatMessages
        #expect(replacementSession != originalSession)

        // A queued Send task can begin only after its original meeting ended.
        await coordinator.sendChat(text: "Private draft from the first meeting", sessionID: originalSession)
        #expect(coordinator.chatMessages == originalMessages)
        #expect(coordinator.lastError == nil)
        #expect(!coordinator.isApplyingControl)
        await coordinator.sendChat(text: "Current meeting message", sessionID: replacementSession)
        #expect(coordinator.chatMessages.last?.text == "Current meeting message")
        #expect(coordinator.chatMessages.last?.isFromSelf == true)
    }

    @Test func cancelledControlsDoNotActivateMediaOrSendContent() async {
        let coordinator = MeetingCoordinator(driver: DemoMeetingDriver(participantCount: 2))
        await coordinator.host(displayName: "Test")
        let originalMessages = coordinator.chatMessages
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await coordinator.setCameraEnabled(true)
            await coordinator.setMicrophoneMuted(false)
            await coordinator.sendChat(text: "Cancelled draft")
            await coordinator.startShare(ShareTarget(id: "cancelled", title: "Cancelled share", kind: .demo))
        }
        await task.value
        #expect(!coordinator.isCameraEnabled)
        #expect(coordinator.isMicrophoneMuted)
        #expect(!coordinator.sharing.isSharing)
        #expect(coordinator.chatMessages == originalMessages)
        #expect(coordinator.lastError == nil)
        #expect(!coordinator.isApplyingControl)
    }

    @Test func controlsAreNeverOptimisticWhenDriverRejectsThem() async {
        let driver = RejectedControlsDriver()
        let coordinator = MeetingCoordinator(driver: driver)
        await coordinator.host(displayName: "Test")
        await coordinator.setMicrophoneMuted(false)
        #expect(coordinator.isMicrophoneMuted)
        #expect(coordinator.lastError == "Microphone permission denied")
        #expect(!coordinator.isApplyingControl)
        await coordinator.startShare(ShareTarget(id: "window", title: "Document", kind: .window))
        #expect(coordinator.sharing == .idle)
    }

    @Test func rejectsUntrustedMeetingLinksAndEmptyNames() async {
        for url in ["https://zoom.us.evil.example/j/12345678901", "https://evilzoom.us/j/12345678901",
                    "http://zoom.us/j/12345678901", "https://zoom.us@evil.example/j/12345678901",
                    "https://zoom.us/j/"] {
            let coordinator = MeetingCoordinator(driver: DemoMeetingDriver())
            await coordinator.join(url: URL(string: url)!, displayName: "Test")
            #expect(coordinator.status == .idle)
            #expect(coordinator.lastError == MeetingError.invalidLink.localizedDescription)
        }
        let coordinator = MeetingCoordinator(driver: DemoMeetingDriver())
        await coordinator.host(displayName: " \n ")
        #expect(coordinator.sessionID == nil)
        #expect(coordinator.lastError == MeetingError.invalidName.localizedDescription)
    }

    @Test func rejectsOversizedMessagesAndDeduplicatesCallbacks() async {
        let driver = DemoMeetingDriver()
        let coordinator = MeetingCoordinator(driver: driver)
        await coordinator.host(displayName: "Test")
        let originalCount = coordinator.chatMessages.count
        await coordinator.sendChat(text: " \n ")
        await coordinator.sendChat(text: String(repeating: "a", count: 4_001))
        #expect(coordinator.chatMessages.count == originalCount)
        let message = MeetingChatMessage(senderName: "Avery", text: "Example")
        driver.onEvent?(coordinator.sessionID!, .message(message))
        driver.onEvent?(coordinator.sessionID!, .message(message))
        #expect(coordinator.chatMessages.count == originalCount + 1)
        let edited = MeetingChatMessage(id: message.id, senderName: message.senderName, text: "Updated")
        driver.onEvent?(coordinator.sessionID!, .messageUpdated(edited))
        #expect(coordinator.chatMessages.last?.text == "Updated")
        driver.onEvent?(coordinator.sessionID!, .messageRemoved(message.id))
        #expect(coordinator.chatMessages.count == originalCount)
        driver.onEvent?(coordinator.sessionID!, .messageUpdated(edited))
        #expect(coordinator.chatMessages.count == originalCount)
    }

    @Test func requestedHostingDoesNotGrantRoleBeforeDriverConfirmsIt() async {
        let driver = ControlledSessionDriver()
        let coordinator = MeetingCoordinator(driver: driver)
        await coordinator.host(displayName: "Test")
        #expect(!coordinator.isHost)
        await coordinator.leave(endForEveryone: true)
        #expect(driver.leaveRequests == 0)
        #expect(coordinator.lastError == MeetingError.hostRequired.localizedDescription)
        driver.onEvent?(coordinator.sessionID!, .hostChanged(true))
        await coordinator.leave(endForEveryone: true)
        #expect(driver.leaveRequests == 1)
    }

    @Test func acceptedLeaveDoesNotPretendMediaHasStopped() async {
        let driver = ControlledSessionDriver()
        let coordinator = MeetingCoordinator(driver: driver)
        await coordinator.host(displayName: "Test")
        let id = coordinator.sessionID!
        await coordinator.leave()
        #expect(coordinator.status == .leaving)
        #expect(coordinator.sessionID == id)
        driver.onEvent?(id, .controlError("Zoom has not confirmed that the connection stopped."))
        #expect(coordinator.lastError == "Zoom has not confirmed that the connection stopped.")
        #expect(coordinator.sessionID == id)
        driver.onEvent?(id, .status(.inMeeting))
        #expect(coordinator.status == .leaving)
        await coordinator.host(displayName: "Another call")
        #expect(driver.connectRequests == 1)
        #expect(await !coordinator.waitForMeetingEnd(timeout: .milliseconds(10)))
        #expect(coordinator.status == .leaving)
        driver.onEvent?(id, .status(.idle))
        #expect(await coordinator.waitForMeetingEnd(timeout: .zero))
    }

    @Test func terminationWaitObservesDelayedTerminalCallback() async {
        let driver = ControlledSessionDriver()
        let coordinator = MeetingCoordinator(driver: driver)
        await coordinator.host(displayName: "Test")
        let id = coordinator.sessionID!
        await coordinator.leave()
        let waiter = Task { await coordinator.waitForMeetingEnd(timeout: .seconds(1)) }
        await Task.yield()
        driver.onEvent?(id, .status(.idle))
        #expect(await waiter.value)
        #expect(coordinator.sessionID == nil)
    }

    @Test func terminationWaitCancellationDoesNotClearSession() async {
        let driver = ControlledSessionDriver()
        let coordinator = MeetingCoordinator(driver: driver)
        await coordinator.host(displayName: "Test")
        await coordinator.leave()
        let waiter = Task { await coordinator.waitForMeetingEnd(timeout: .seconds(1)) }
        waiter.cancel()
        #expect(await !waiter.value)
        #expect(coordinator.status == .leaving)
        #expect(coordinator.sessionID != nil)
    }

    @Test func terminationWaitDoesNotIgnoreAReplacementCall() async {
        let driver = ControlledSessionDriver()
        let coordinator = MeetingCoordinator(driver: driver)
        await coordinator.host(displayName: "Test")
        let oldID = coordinator.sessionID!
        await coordinator.leave()
        let waiter = Task { await coordinator.waitForMeetingEnd(timeout: .seconds(1)) }
        await Task.yield()
        driver.onEvent?(oldID, .status(.idle))
        await coordinator.host(displayName: "New call")
        #expect(await !waiter.value)
        #expect(coordinator.status == .inMeeting)
    }

    @Test func terminalFailureCleansStateAndAllowsRetry() async {
        let driver = ControlledSessionDriver()
        let coordinator = MeetingCoordinator(driver: driver)
        await coordinator.host(displayName: "Test")
        let id = coordinator.sessionID!
        driver.onEvent?(id, .participants([MeetingParticipant(id: "self", name: "Test", isSelf: true)]))
        driver.onEvent?(id, .status(.failed))
        #expect(coordinator.status == .failed)
        #expect(coordinator.sessionID == nil)
        #expect(coordinator.participants.isEmpty)
        await coordinator.host(displayName: "Test")
        #expect(driver.connectRequests == 2)
        #expect(coordinator.status == .inMeeting)
        #expect(coordinator.sessionID != id)
    }

    @Test func cancellingPendingJoinRequestsTeardownAndRejectsLateSuccess() async {
        let driver = SuspendedConnectDriver()
        let coordinator = MeetingCoordinator(driver: driver)
        let join = Task { await coordinator.host(displayName: "Test") }
        await driver.waitForConnect()
        let id = coordinator.sessionID!
        join.cancel()
        await driver.waitForLeave()
        #expect(coordinator.status == .leaving)
        driver.onEvent?(id, .status(.inMeeting))
        #expect(coordinator.status == .leaving)
        driver.resumeConnect()
        await join.value
        #expect(coordinator.status == .leaving)
        driver.onEvent?(id, .status(.idle))
        #expect(coordinator.sessionID == nil)
    }

    @Test func receivedShareSelectionTracksSourcesAndReleasesOnLeave() async {
        let driver = MeetingExtrasDriver()
        let coordinator = MeetingCoordinator(driver: driver)
        await coordinator.host(displayName: "Test")
        let id = coordinator.sessionID!
        let first = ReceivedMeetingShare(id: "11", ownerID: "1", ownerName: "First")
        let second = ReceivedMeetingShare(id: "22", ownerID: "2", ownerName: "Second")
        driver.onEvent?(id, .receivedShares([first, first, second]))
        #expect(coordinator.receivedShares.count == 2)
        #expect(coordinator.selectedReceivedShare == first)
        #expect(driver.selectedShare == "11")
        coordinator.selectReceivedShare("22")
        #expect(driver.selectedShare == "22")
        coordinator.selectReceivedShare("unknown")
        #expect(coordinator.selectedReceivedShare == second)
        driver.onEvent?(id, .receivedShares([first]))
        #expect(coordinator.selectedReceivedShare == first)
        coordinator.selectReceivedShare(nil)
        driver.onEvent?(id, .receivedShares([first, second]))
        #expect(coordinator.selectedReceivedShare == nil)
        #expect(driver.selectedShare == nil)
        driver.onEvent?(id, .receivedShares([]))
        driver.onEvent?(id, .receivedShares([second]))
        #expect(coordinator.selectedReceivedShare == second)
        await coordinator.leave()
        #expect(coordinator.receivedShares.isEmpty)
        #expect(driver.selectedShare == nil)
        driver.onEvent?(id, .receivedShares([second]))
        #expect(coordinator.receivedShares.isEmpty)
    }

    @Test func admissionRequiresConfirmedHostAndRemainsPendingUntilCallback() async {
        let driver = MeetingExtrasDriver()
        let coordinator = MeetingCoordinator(driver: driver)
        await coordinator.host(displayName: "Test")
        let id = coordinator.sessionID!
        let waiting = WaitingRoomParticipant(id: "7", name: "Guest")
        driver.onEvent?(id, .waitingRoomParticipants([waiting, waiting]))
        await coordinator.admitParticipant("7")
        #expect(driver.admittedIDs.isEmpty)
        driver.onEvent?(id, .hostChanged(true))
        await coordinator.admitParticipant("7")
        #expect(driver.admittedIDs == ["7"])
        #expect(coordinator.waitingRoomParticipants == [waiting])
        driver.onEvent?(id, .waitingRoomParticipants([]))
        await coordinator.admitParticipant("7")
        #expect(driver.admittedIDs == ["7"])
        #expect(coordinator.lastError == MeetingError.participantNoLongerWaiting.localizedDescription)
    }

    @Test func liveTargetEnumerationDoesNotReturnDemoOrEndedSessionResults() async {
        let driver = MeetingExtrasDriver()
        let coordinator = MeetingCoordinator(driver: driver)
        await coordinator.host(displayName: "Test")
        let targets = await coordinator.loadAvailableShareTargets()
        #expect(targets.map(\.id) == ["42"])
        driver.endDuringEnumeration = true
        #expect(await coordinator.loadAvailableShareTargets().isEmpty)
        #expect(coordinator.status == .idle)
        #expect(coordinator.lastError == nil)
    }
}

@MainActor
private final class MeetingExtrasDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: false, canShare: true,
                                          supportsNativeVideo: false, canAdmitParticipants: true,
                                          canReceiveShare: true, canEnumerateShareTargets: true)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var selectedShare: String?
    var admittedIDs: [String] = []
    var endDuringEnumeration = false
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws { onEvent?(sessionID, .status(.inMeeting)) }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { onEvent?(sessionID, .status(.idle)) }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func sendChat(text: String, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func stopShare(sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func setSelectedReceivedShare(_ sourceID: String?) { selectedShare = sourceID }
    func admitParticipant(_ participantID: String, sessionID: UUID) async throws { admittedIDs.append(participantID) }
    func availableShareTargets(sessionID: UUID) async throws -> [ShareTarget] {
        if endDuringEnumeration { onEvent?(sessionID, .status(.idle)) }
        let window = ShareTarget(id: "42", title: "A window", kind: .window)
        return [window, window, ShareTarget(id: "demo", title: "Demo", kind: .demo)]
    }
}

@MainActor
private final class RejectedControlsDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: true, canShare: true,
                                          supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws { onEvent?(sessionID, .status(.inMeeting)) }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { onEvent?(sessionID, .status(.idle)) }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws {
        throw MeetingError.unavailable("Microphone permission denied")
    }
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func sendChat(text: String, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func stopShare(sessionID: UUID) async throws { throw MeetingError.noMeeting }
}

@MainActor
private final class ControlledSessionDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: false, canShare: false,
                                          supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var connectRequests = 0
    var leaveRequests = 0
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws {
        connectRequests += 1
        onEvent?(sessionID, .status(.inMeeting))
    }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { leaveRequests += 1 }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func sendChat(text: String, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func stopShare(sessionID: UUID) async throws { throw MeetingError.noMeeting }
}

@MainActor
private final class SuspendedConnectDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: false, canShare: false,
                                          supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var connectGate: CheckedContinuation<Void, Never>?
    var connectStarted: CheckedContinuation<Void, Never>?
    var leaveStarted: CheckedContinuation<Void, Never>?
    var didLeave = false
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws {
        await withCheckedContinuation { continuation in
            connectGate = continuation
            connectStarted?.resume()
            connectStarted = nil
        }
    }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws {
        didLeave = true
        leaveStarted?.resume()
        leaveStarted = nil
    }
    func waitForConnect() async {
        if connectGate != nil { return }
        await withCheckedContinuation { connectStarted = $0 }
    }
    func waitForLeave() async {
        if didLeave { return }
        await withCheckedContinuation { leaveStarted = $0 }
    }
    func resumeConnect() { connectGate?.resume(); connectGate = nil }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func sendChat(text: String, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func stopShare(sessionID: UUID) async throws { throw MeetingError.noMeeting }
}
