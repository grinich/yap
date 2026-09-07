import Foundation
import Testing
import WhooshMeetings
@testable import WhooshAppUI

@Suite("Confirmed sharing return integration", .serialized) @MainActor
struct WhooshShareStopReturnTests {
    @Test func acceptedStopKeepsBackgroundSurfacesUntilTheSDKConfirms() async {
        let driver = ShareReturnDriver()
        let meeting = MeetingCoordinator(driver: driver)
        var transition = WhooshSharingStopTransition()
        await meeting.host(displayName: "Fixture")
        #expect(!consume(&transition, meeting))
        driver.emit(.sharing(.sharing(Self.target)))
        #expect(!consume(&transition, meeting))
        #expect(backgroundPiP(meeting))
        #expect(WhooshSharingOverlayLayout.shouldPresentChat(isPresenting: true, isSharing: meeting.sharing.isSharing, chatVisible: true))

        await meeting.stopShare()
        #expect(driver.stopRequests == 1)
        #expect(meeting.sharing.isSharing)
        #expect(!consume(&transition, meeting))
        #expect(backgroundPiP(meeting))
        driver.emit(.sharing(.idle))
        #expect(consume(&transition, meeting))
        // The native controller applies its foreground callback after this
        // transition. Its resulting main-window state must hide both panels.
        let foregroundPiP = WhooshSharingOverlayLayout.shouldPresent(
            isConnected: meeting.isConnected, isPreview: false, hasMainWindow: true,
            applicationIsActive: true, mainWindowIsKey: true,
            mainWindowIsVisible: true, mainWindowIsMiniaturized: false)
        #expect(!foregroundPiP)
        #expect(!WhooshSharingOverlayLayout.shouldPresentChat(isPresenting: foregroundPiP, isSharing: meeting.sharing.isSharing, chatVisible: true))
        #expect(!consume(&transition, meeting))
    }

    @Test func anOldPendingStopCannotReturnFromOrStopTheReplacementMeeting() async {
        let driver = ShareReturnDriver()
        let meeting = MeetingCoordinator(driver: driver)
        var transition = WhooshSharingStopTransition()
        await meeting.host(displayName: "Fixture")
        driver.emit(.sharing(.sharing(Self.target)))
        #expect(!consume(&transition, meeting))
        driver.pauseStop = true
        let stop = Task { await meeting.stopShare() }
        await driver.waitForPendingStop()
        #expect(!consume(&transition, meeting))
        let firstSession = meeting.sessionID
        await meeting.leave()
        #expect(!consume(&transition, meeting))
        #expect(!backgroundPiP(meeting))
        await meeting.host(displayName: "Next fixture")
        #expect(meeting.sessionID != firstSession)
        driver.emit(.sharing(.sharing(Self.target)))
        #expect(!consume(&transition, meeting))
        // A delayed completion/callback belongs to the first SDK session.
        driver.finishPendingStop()
        await stop.value
        #expect(meeting.isConnected)
        #expect(meeting.sharing.isSharing)
        #expect(!consume(&transition, meeting))
        driver.emit(.sharing(.idle))
        #expect(consume(&transition, meeting))
    }

    @Test func stopDuringConnectionLossDoesNotForegroundTheAppOnLaterReconnect() async {
        let driver = ShareReturnDriver()
        let meeting = MeetingCoordinator(driver: driver)
        var transition = WhooshSharingStopTransition()
        await meeting.host(displayName: "Fixture")
        driver.emit(.sharing(.sharing(Self.target)))
        #expect(!consume(&transition, meeting))
        driver.emit(.status(.reconnecting))
        driver.emit(.sharing(.idle))
        #expect(!consume(&transition, meeting))
        driver.emit(.status(.inMeeting))
        #expect(!consume(&transition, meeting))
        #expect(backgroundPiP(meeting))
        #expect(!WhooshSharingOverlayLayout.shouldPresentChat(isPresenting: true, isSharing: meeting.sharing.isSharing, chatVisible: true))
    }

    @Test func anOrdinaryBackgroundCallShowsFacesWithoutOpeningFloatingChat() async {
        let driver = ShareReturnDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Fixture")
        #expect(backgroundPiP(meeting))
        #expect(!WhooshSharingOverlayLayout.shouldPresentChat(isPresenting: true, isSharing: meeting.sharing.isSharing, chatVisible: true))
        let minimizedPiP = WhooshSharingOverlayLayout.shouldPresent(
            isConnected: meeting.isConnected, isPreview: false, hasMainWindow: true,
            applicationIsActive: true, mainWindowIsKey: true,
            mainWindowIsVisible: false, mainWindowIsMiniaturized: true)
        #expect(minimizedPiP)
        driver.emit(.sharing(.sharing(Self.target)))
        #expect(WhooshSharingOverlayLayout.shouldPresentChat(isPresenting: minimizedPiP, isSharing: meeting.sharing.isSharing, chatVisible: true))
        #expect(!WhooshSharingOverlayLayout.shouldPresentChat(isPresenting: minimizedPiP, isSharing: meeting.sharing.isSharing, chatVisible: false))
        #expect(backgroundPiP(meeting))
        await meeting.leave()
        #expect(!backgroundPiP(meeting))
        #expect(!WhooshSharingOverlayLayout.shouldPresentChat(isPresenting: false, isSharing: meeting.sharing.isSharing, chatVisible: true))
    }

    private static let target = ShareTarget(id: "fixture-window", title: "Fixture window", kind: .window)
    private func consume(_ transition: inout WhooshSharingStopTransition, _ meeting: MeetingCoordinator) -> Bool {
        transition.consume(sessionID: meeting.sessionID, isSharing: meeting.sharing.isSharing, isConnected: meeting.isConnected)
    }
    private func backgroundPiP(_ meeting: MeetingCoordinator) -> Bool {
        WhooshSharingOverlayLayout.shouldPresent(
            isConnected: meeting.isConnected, isPreview: false, hasMainWindow: true,
            applicationIsActive: false, mainWindowIsKey: true,
            mainWindowIsVisible: true, mainWindowIsMiniaturized: false)
    }
}

@MainActor
private final class ShareReturnDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: true, canShare: true, supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    private var sessionID: UUID?
    private(set) var stopRequests = 0
    var pauseStop = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stopWaiter: CheckedContinuation<Void, Never>?
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws {
        self.sessionID = sessionID
        emit(.status(.inMeeting))
    }
    func emit(_ event: MeetingDriverEvent) { if let sessionID { onEvent?(sessionID, event) } }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { onEvent?(sessionID, .status(.idle)) }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws {}
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws {}
    func sendChat(text: String, sessionID: UUID) async throws {}
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {}
    func stopShare(sessionID: UUID) async throws {
        stopRequests += 1
        if pauseStop {
            pauseStop = false
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
                stopWaiter?.resume(); stopWaiter = nil
            }
            onEvent?(sessionID, .sharing(.idle))
        }
    }
    func waitForPendingStop() async {
        if stopContinuation == nil { await withCheckedContinuation { stopWaiter = $0 } }
    }
    func finishPendingStop() { stopContinuation?.resume(); stopContinuation = nil }
}
