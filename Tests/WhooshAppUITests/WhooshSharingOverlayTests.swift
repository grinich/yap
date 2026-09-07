import Foundation
import Testing
import WhooshMeetings
@testable import WhooshAppUI

@Suite("Sharing overlay state", .serialized) @MainActor
struct WhooshSharingOverlayTests {
    @Test func presentsOnlyForConnectedLiveMeetingAwayFromMainWindow() {
        #expect(WhooshSharingOverlayLayout.shouldPresent(isConnected: true, isPreview: false, hasMainWindow: true, applicationIsActive: true, mainWindowIsKey: false, mainWindowIsVisible: true, mainWindowIsMiniaturized: false))
        #expect(!WhooshSharingOverlayLayout.shouldPresent(isConnected: false, isPreview: false, hasMainWindow: true, applicationIsActive: true, mainWindowIsKey: false, mainWindowIsVisible: true, mainWindowIsMiniaturized: false))
        #expect(!WhooshSharingOverlayLayout.shouldPresent(isConnected: true, isPreview: true, hasMainWindow: true, applicationIsActive: true, mainWindowIsKey: false, mainWindowIsVisible: true, mainWindowIsMiniaturized: false))
        #expect(!WhooshSharingOverlayLayout.shouldPresent(isConnected: true, isPreview: false, hasMainWindow: false, applicationIsActive: true, mainWindowIsKey: false, mainWindowIsVisible: false, mainWindowIsMiniaturized: false))
        #expect(!WhooshSharingOverlayLayout.shouldPresent(isConnected: true, isPreview: false, hasMainWindow: true, applicationIsActive: true, mainWindowIsKey: true, mainWindowIsVisible: true, mainWindowIsMiniaturized: false))
    }

    @Test func retainedKeyFlagInInactiveApplicationStillPresentsOverlays() {
        #expect(WhooshSharingOverlayLayout.shouldPresent(
            isConnected: true, isPreview: false, hasMainWindow: true,
            applicationIsActive: false, mainWindowIsKey: true,
            mainWindowIsVisible: true, mainWindowIsMiniaturized: false))
    }

    @Test func attachedKeySheetKeepsVideoInTheForegroundMeeting() {
        #expect(!WhooshSharingOverlayLayout.shouldPresent(
            isConnected: true, isPreview: false, hasMainWindow: true,
            applicationIsActive: true, mainWindowIsKey: false,
            mainWindowIsVisible: true, mainWindowIsMiniaturized: false,
            mainWindowHasKeySheet: true))
        // A retained sheet key flag does not suppress PiP after app deactivation.
        #expect(WhooshSharingOverlayLayout.shouldPresent(
            isConnected: true, isPreview: false, hasMainWindow: true,
            applicationIsActive: false, mainWindowIsKey: false,
            mainWindowIsVisible: true, mainWindowIsMiniaturized: false,
            mainWindowHasKeySheet: true))
    }

    @Test func hiddenChatReopensOnItsNewDisplayInsteadOfStaleCoordinates() {
        let external = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        let builtIn = CGRect(x: 0, y: 0, width: 1440, height: 875)
        var placement = WhooshSharingChatPlacement()
        let original = placement.frameForPresentation(currentFrame: nil, on: external)
        let userPositioned = original.offsetBy(dx: -240, dy: 160)
        let sameDisplay = placement.frameForPresentation(currentFrame: userPositioned, on: external)
        #expect(sameDisplay == userPositioned)
        // Chat is hidden while the strip moves and the external display vanishes.
        // Only reopening Chat advances its own screen checkpoint.
        let reopened = placement.frameForPresentation(currentFrame: userPositioned, on: builtIn)
        #expect(builtIn.contains(reopened))
        #expect(reopened != userPositioned)
        let adjusted = reopened.offsetBy(dx: -120, dy: 90)
        let subsequent = placement.frameForPresentation(currentFrame: adjusted, on: builtIn)
        #expect(subsequent == adjusted)
    }

    @Test func hiddenOrMinimizedMainWindowDoesNotSuppressOverlays() {
        #expect(WhooshSharingOverlayLayout.shouldPresent(
            isConnected: true, isPreview: false, hasMainWindow: true,
            applicationIsActive: true, mainWindowIsKey: true,
            mainWindowIsVisible: false, mainWindowIsMiniaturized: false))
        #expect(WhooshSharingOverlayLayout.shouldPresent(
            isConnected: true, isPreview: false, hasMainWindow: true,
            applicationIsActive: true, mainWindowIsKey: true,
            mainWindowIsVisible: true, mainWindowIsMiniaturized: true))
    }

    @Test func confirmedStopReturnsToSameConnectedMeetingExactlyOnce() {
        var transition = WhooshSharingStopTransition()
        let session = UUID()
        #expect(transition.consume(sessionID: session, isSharing: false, isConnected: true) == false)
        #expect(transition.consume(sessionID: session, isSharing: true, isConnected: true) == false)
        // Acceptance or failure of a Stop request does not change sharing state.
        #expect(transition.consume(sessionID: session, isSharing: true, isConnected: true) == false)
        #expect(transition.consume(sessionID: session, isSharing: false, isConnected: true) == true)
        #expect(transition.consume(sessionID: session, isSharing: false, isConnected: true) == false)
        #expect(transition.consume(sessionID: session, isSharing: true, isConnected: true) == false)
        #expect(transition.consume(sessionID: session, isSharing: false, isConnected: true) == true)
    }

    @Test func endedOrReplacedSessionsNeverActivateTheMainWindow() {
        var transition = WhooshSharingStopTransition()
        let session = UUID()
        #expect(transition.consume(sessionID: session, isSharing: true, isConnected: true) == false)
        #expect(transition.consume(sessionID: session, isSharing: false, isConnected: false) == false)
        #expect(transition.consume(sessionID: session, isSharing: false, isConnected: true) == false)
        #expect(transition.consume(sessionID: session, isSharing: true, isConnected: true) == false)
        #expect(transition.consume(sessionID: UUID(), isSharing: false, isConnected: true) == false)
        #expect(transition.consume(sessionID: session, isSharing: true, isConnected: true) == false)
        #expect(transition.consume(sessionID: nil, isSharing: false, isConnected: false) == false)
    }

    @Test func closesChatForCurrentShareButResetsOnNextShare() {
        let state = WhooshSharingPresentation()
        let session = UUID()
        state.synchronize(sessionID: session, isSharing: false)
        state.chatDraft = "Unsent note"
        state.synchronize(sessionID: session, isSharing: true)
        state.chatVisible = false
        state.setPresenting(true)
        state.synchronize(sessionID: session, isSharing: true)
        #expect(!state.chatVisible)
        #expect(state.chatDraft == "Unsent note")
        state.setPresenting(false)
        #expect(state.chatDraft == "Unsent note")
        state.synchronize(sessionID: session, isSharing: false)
        state.synchronize(sessionID: session, isSharing: true)
        #expect(state.chatVisible)
        #expect(state.chatDraft == "Unsent note")
        state.synchronize(sessionID: UUID(), isSharing: true)
        #expect(state.chatVisible)
        #expect(state.chatDraft.isEmpty)
    }

    @Test func stripUsesOnlySixUniqueVisibleRemoteParticipants() {
        let participants = [MeetingParticipant(id: "me", name: "Me", isSelf: true)] +
            (0..<8).map { MeetingParticipant(id: "remote-\($0)", name: "Person \($0)") }
        let duplicated = [participants[0], participants[1], participants[1]] + Array(participants.dropFirst(2))
        #expect(WhooshSharingOverlayLayout.participants(from: duplicated).map(\.id) == (0..<6).map { "remote-\($0)" })
    }

    @Test func soloCallKeepsSelfInPictureInPictureWithCameraOffOrOn() {
        for cameraEnabled in [false, true] {
            let local = MeetingParticipant(id: "me", name: "Me", isSelf: true, isCameraEnabled: cameraEnabled)
            let selected = WhooshSharingOverlayLayout.participants(from: [local, local])
            #expect(selected.map(\.id) == ["me"])
            #expect(selected.first?.isCameraEnabled == cameraEnabled)
        }
        #expect(WhooshSharingOverlayLayout.participants(from: []).isEmpty)
    }

    @Test func pictureInPictureSwitchesToOthersAndBackToSelfAsPeopleComeAndGo() {
        let local = MeetingParticipant(id: "me", name: "Me", isSelf: true)
        let guest = MeetingParticipant(id: "guest", name: "Guest", isCameraEnabled: true)
        #expect(WhooshSharingOverlayLayout.participants(from: [local]).map(\.id) == ["me"])
        #expect(WhooshSharingOverlayLayout.participants(from: [local, guest]).map(\.id) == ["guest"])
        #expect(WhooshSharingOverlayLayout.participants(from: [local]).map(\.id) == ["me"])
    }

    @Test func largerPictureInPictureFitsPortraitAndLandscapeDisplays() {
        for screen in [CGRect(x: 0, y: 0, width: 640, height: 480),
                       CGRect(x: -1920, y: -200, width: 1920, height: 1055)] {
            for ratios in [[16.0 / 9.0], [9.0 / 16.0], Array(repeating: 16.0 / 9.0, count: 6)] {
                let pip = WhooshSharingOverlayLayout.stripFrame(in: screen, aspectRatios: ratios)
                #expect(screen.contains(pip))
                #expect(pip.width >= 200 && pip.height >= 140)
                #expect(pip.maxY <= screen.maxY)
                let resized = CGRect(x: screen.maxX + 100, y: screen.minY - 200, width: 400, height: 300)
                let clamped = WhooshSharingOverlayLayout.clampedStripFrame(resized, in: screen)
                #expect(screen.contains(clamped))
                #expect(clamped.size == resized.size)
            }
            #expect(screen.contains(WhooshSharingOverlayLayout.chatFrame(in: screen)))
        }
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let normal = WhooshSharingOverlayLayout.stripFrame(in: screen, aspectRatios: [16 / 9])
        #expect(normal.width >= 384 && normal.height >= 216)
        let portrait = WhooshSharingOverlayLayout.stripFrame(in: screen, aspectRatios: [9 / 16])
        #expect(portrait.height > portrait.width)
    }

    @Test func resizingKeepsTheTopLeftAnchorAndEnforcesUsableBounds() {
        let original = CGRect(x: -800, y: 300, width: 400, height: 250)
        let minimum = CGSize(width: 200, height: 140)
        let maximum = CGSize(width: 1000, height: 700)
        let enlarged = PictureInPictureResize.frame(from: original, translation: CGSize(width: 120, height: -80), minimum: minimum, maximum: maximum)
        #expect(enlarged == CGRect(x: -800, y: 220, width: 520, height: 330))
        let small = PictureInPictureResize.frame(from: original, translation: CGSize(width: -900, height: 900), minimum: minimum, maximum: maximum)
        #expect(small.size == minimum && small.maxY == original.maxY && small.minX == original.minX)
        let huge = PictureInPictureResize.frame(from: original, translation: CGSize(width: 9000, height: -9000), minimum: minimum, maximum: maximum)
        #expect(huge.size == maximum && huge.maxY == original.maxY)
    }

    @Test func pendingSendSurvivesPresentationChangesAndKeepsNewDraft() async {
        let driver = OverlayChatDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Fixture")
        let state = WhooshSharingPresentation()
        state.synchronize(sessionID: meeting.sessionID, isSharing: false)
        state.chatDraft = "First message"
        state.sendMessage(in: meeting)
        await waitUntil { driver.pendingSend != nil }
        #expect(driver.sentMessages == ["First message"])
        #expect(state.isSending)
        state.setPresenting(true)
        state.chatDraft = "Next message"
        driver.finishSend()
        await waitUntil { !state.isSending }
        #expect(!state.isSending)
        #expect(state.chatDraft == "Next message")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition())
    }

    @Test func oldSendCompletionCannotClearNextMeetingDraft() async {
        let driver = OverlayChatDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Fixture")
        let state = WhooshSharingPresentation()
        state.synchronize(sessionID: meeting.sessionID, isSharing: false)
        state.chatDraft = "First room"
        state.sendMessage(in: meeting)
        await waitUntil { driver.pendingSend != nil }
        state.synchronize(sessionID: UUID(), isSharing: false)
        state.chatDraft = "New room draft"
        driver.finishSend()
        await Task.yield()
        #expect(!state.isSending)
        #expect(state.chatDraft == "New room draft")
    }
}

@MainActor private final class OverlayChatDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: true,
                                           canShare: true, supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var pendingSend: CheckedContinuation<Void, Never>?
    var sentMessages: [String] = []
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws { onEvent?(sessionID, .status(.inMeeting)) }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { onEvent?(sessionID, .status(.idle)) }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws {}
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws {}
    func sendChat(text: String, sessionID: UUID) async throws {
        sentMessages.append(text)
        await withCheckedContinuation { pendingSend = $0 }
    }
    func finishSend() { pendingSend?.resume(); pendingSend = nil }
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {}
    func stopShare(sessionID: UUID) async throws {}
}
