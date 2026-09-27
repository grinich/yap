import Foundation
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Empty meeting canvas") @MainActor
struct MeetingEmptyCanvasTests {
    private func fixture(_ people: [MeetingParticipant]) async throws -> (MeetingCoordinator, DemoMeetingDriver, UUID) {
        let driver = DemoMeetingDriver(participantCount: 1)
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Self")
        let session = try #require(meeting.sessionID)
        driver.onEvent?(session, .participants(people))
        return (meeting, driver, session)
    }

    @Test func soloCameraOffShowsAloneStateWithoutRestoringFilteredSelfTile() async throws {
        let (meeting, driver, session) = try await fixture([
            MeetingParticipant(id: "self", name: "Self", isSelf: true)
        ])
        defer { meeting.shutdown() }
        for hidden in [false, true] {
            meeting.hideSelfView = hidden
            #expect(meeting.participants.count == 1)
            #expect(meeting.visibleParticipants.isEmpty)
            #expect(MeetingPresentationRules.emptyCanvasMessage(for: meeting)?.title == "You’re the only one here.")
        }
        driver.onEvent?(session, .participants([
            MeetingParticipant(id: "self", name: "Self", isSelf: true, isCameraEnabled: true)
        ]))
        #expect(MeetingPresentationRules.emptyCanvasMessage(for: meeting)?.title == "You’re the only one here.")
        meeting.hideSelfView = false
        #expect(meeting.visibleParticipants.map(\.id) == ["self"])
        #expect(MeetingPresentationRules.emptyCanvasMessage(for: meeting) == nil)
    }

    @Test func hiddenRemoteCamerasDoNotIncorrectlySayTheUserIsAlone() async throws {
        let (meeting, _, _) = try await fixture([
            MeetingParticipant(id: "self", name: "Self", isSelf: true),
            MeetingParticipant(id: "a", name: "A"),
            MeetingParticipant(id: "b", name: "B")
        ])
        defer { meeting.shutdown() }
        #expect(meeting.visibleParticipants.isEmpty)
        #expect(MeetingPresentationRules.emptyCanvasMessage(for: meeting)?.title == "No cameras to show.")
        meeting.showNonVideoParticipants = true
        #expect(meeting.visibleParticipants.map(\.id) == ["a", "b"])
        #expect(MeetingPresentationRules.emptyCanvasMessage(for: meeting) == nil)
    }

    @Test func cameraOffOneToOneAndPinnedPresentationsKeepTheirExistingTiles() async throws {
        let (meeting, driver, session) = try await fixture([
            MeetingParticipant(id: "self", name: "Self", isSelf: true),
            MeetingParticipant(id: "a", name: "A")
        ])
        defer { meeting.shutdown() }
        #expect(meeting.oneToOneParticipants != nil)
        #expect(MeetingPresentationRules.emptyCanvasMessage(for: meeting) == nil)
        driver.onEvent?(session, .participants(meeting.participants + [MeetingParticipant(id: "b", name: "B")]))
        #expect(MeetingPresentationRules.emptyCanvasMessage(for: meeting) != nil)
        meeting.setPinnedParticipant("a")
        #expect(meeting.presentationParticipant?.id == "a")
        #expect(MeetingPresentationRules.emptyCanvasMessage(for: meeting) == nil)
    }

    @Test func receivedShareRemainsVisibleWithNoCameraTilesInEitherLayout() async throws {
        let (meeting, driver, session) = try await fixture([
            MeetingParticipant(id: "self", name: "Self", isSelf: true)
        ])
        defer { meeting.shutdown() }
        driver.onEvent?(session, .receivedShares([
            ReceivedMeetingShare(id: "share", ownerID: "remote", ownerName: "Remote")
        ]))
        #expect(meeting.selectedReceivedShare != nil)
        #expect(meeting.visibleParticipants.isEmpty)
        #expect(MeetingPresentationRules.emptyCanvasMessage(for: meeting) == nil)
        meeting.selectReceivedShare(nil)
        #expect(meeting.galleryReceivedShare != nil)
        #expect(meeting.visibleParticipants.isEmpty)
        #expect(MeetingPresentationRules.emptyCanvasMessage(for: meeting) == nil)
    }

    @Test func groupPhotoBatchGapsDoNotGainAnEmptyStateOverlay() async throws {
        let (meeting, _, session) = try await fixture([
            MeetingParticipant(id: "self", name: "Self", isSelf: true, isCameraEnabled: true)
        ])
        defer { meeting.shutdown() }
        try meeting.beginGroupPhoto(sessionID: session)
        #expect(meeting.isTakingGroupPhoto)
        #expect(meeting.visibleParticipants.isEmpty)
        #expect(MeetingPresentationRules.emptyCanvasMessage(for: meeting) == nil)
        try meeting.selectGroupPhotoBatch(participantIDs: ["self"], sessionID: session)
        meeting.clearGroupPhotoBatch(sessionID: session)
        #expect(meeting.visibleParticipants.isEmpty)
        #expect(MeetingPresentationRules.emptyCanvasMessage(for: meeting) == nil)
        meeting.endGroupPhoto(sessionID: session)
        #expect(MeetingPresentationRules.emptyCanvasMessage(for: meeting) == nil)
    }

    @Test func emptyRosterKeepsTheWaitingMessage() async throws {
        let (meeting, _, _) = try await fixture([])
        defer { meeting.shutdown() }
        #expect(MeetingPresentationRules.emptyCanvasMessage(for: meeting)?.title == "Waiting for participants.")
    }
}
