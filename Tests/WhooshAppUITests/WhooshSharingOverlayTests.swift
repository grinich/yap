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

    @Test func placementFitsSmallAndOffsetDisplaysWithoutCrossingMenuBar() {
        for screen in [CGRect(x: 0, y: 0, width: 640, height: 480),
                       CGRect(x: -1920, y: -200, width: 1920, height: 1055)] {
            for count in 1...6 {
                let strip = WhooshSharingOverlayLayout.stripFrame(in: screen, count: count)
                #expect(screen.contains(strip))
                #expect(strip.width <= screen.width * 0.6)
                #expect(abs(strip.midX - screen.midX) < 0.01)
                #expect(abs(strip.maxY - (screen.maxY - 12)) < 0.01)
                let width = (strip.width - 16 - CGFloat(count - 1) * 8) / CGFloat(count)
                #expect(abs((strip.height - 16) - width * 9 / 16) < 0.01)
            }
            #expect(screen.contains(WhooshSharingOverlayLayout.chatFrame(in: screen)))
        }
    }

    @Test func pointerFadeHasHysteresisAndWorksOnNegativeScreenCoordinates() {
        let frame = CGRect(x: -900, y: 600, width: 500, height: 79)
        #expect(WhooshSharingOverlayLayout.pointerHidesStrip(CGPoint(x: -910, y: 630), frame: frame, wasHidden: false))
        #expect(!WhooshSharingOverlayLayout.pointerHidesStrip(CGPoint(x: -923, y: 630), frame: frame, wasHidden: false))
        #expect(WhooshSharingOverlayLayout.pointerHidesStrip(CGPoint(x: -923, y: 630), frame: frame, wasHidden: true))
        #expect(!WhooshSharingOverlayLayout.pointerHidesStrip(CGPoint(x: -933, y: 630), frame: frame, wasHidden: true))
    }

    @Test func dragHandleTracksTheStripAndClampsBothWithinTheDisplay() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1055)
        let original = CGRect(x: -1200, y: 500, width: 500, height: 79)
        let handle = WhooshSharingOverlayLayout.handleFrame(for: original)
        #expect(WhooshSharingOverlayLayout.stripFrame(forHandle: handle, stripSize: original.size) == original)
        let movedHandle = handle.offsetBy(dx: 120, dy: -80)
        #expect(WhooshSharingOverlayLayout.stripFrame(forHandle: movedHandle, stripSize: original.size) == original.offsetBy(dx: 120, dy: -80))
        for candidate in [original.offsetBy(dx: -2000, dy: -2000), original.offsetBy(dx: 2000, dy: 2000)] {
            let clamped = WhooshSharingOverlayLayout.clampedStripFrame(candidate, in: screen)
            #expect(screen.contains(clamped))
            #expect(screen.contains(WhooshSharingOverlayLayout.handleFrame(for: clamped)))
            #expect(clamped.size == original.size)
        }
    }

    @Test func handleHoverAndDraggingKeepParticipantFeedbackVisible() {
        let strip = CGRect(x: 100, y: 500, width: 500, height: 79)
        let handle = WhooshSharingOverlayLayout.handleFrame(for: strip)
        let overHandle = CGPoint(x: handle.midX, y: handle.midY)
        #expect(!WhooshSharingOverlayLayout.pointerHidesStrip(overHandle, frame: strip, wasHidden: true, handleFrame: handle))
        #expect(!WhooshSharingOverlayLayout.pointerHidesStrip(CGPoint(x: strip.midX, y: strip.midY), frame: strip,
                                                             wasHidden: true, handleFrame: handle, isDragging: true))
        #expect(WhooshSharingOverlayLayout.pointerHidesStrip(CGPoint(x: strip.midX, y: strip.midY), frame: strip,
                                                            wasHidden: false, handleFrame: handle, isDragging: false))
    }

    @Test func dragUsesScreenCoordinatesAcrossEventsAndClearsAtMouseUp() {
        var drag = WhooshOverlayDrag()
        #expect(drag.translatedOrigin(pointer: .zero) == nil)
        drag.begin(pointer: CGPoint(x: -500, y: 720), windowOrigin: CGPoint(x: -522, y: 713))
        #expect(drag.translatedOrigin(pointer: CGPoint(x: -320, y: 580)) == CGPoint(x: -342, y: 573))
        #expect(drag.translatedOrigin(pointer: CGPoint(x: -500, y: 720)) == CGPoint(x: -522, y: 713))
        drag.end()
        #expect(drag.translatedOrigin(pointer: CGPoint(x: 500, y: 500)) == nil)
        drag.begin(pointer: CGPoint(x: 800, y: 400), windowOrigin: CGPoint(x: 778, y: 393))
        #expect(drag.translatedOrigin(pointer: CGPoint(x: 801, y: 401)) == CGPoint(x: 779, y: 394))
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
