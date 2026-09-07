import Foundation
import Testing
@testable import WhooshMeetings

@Suite("One-to-one presentation") @MainActor
struct OneToOneMeetingTests {
    private let local = MeetingParticipant(id: "self", name: "Self", isSelf: true)
    private let remote = MeetingParticipant(id: "other", name: "Other", isCameraEnabled: true)
    private func fixture() async throws -> (MeetingCoordinator, DemoMeetingDriver, UUID) {
        let driver = DemoMeetingDriver(participantCount: 1)
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Self")
        return (meeting, driver, try #require(meeting.sessionID))
    }

    @Test func pairUsesTheOtherPersonAsMainAndSubscribesToBothStreams() async throws {
        let (meeting, driver, session) = try await fixture()
        driver.onEvent?(session, .participants([remote, local]))
        meeting.setPageSize(1)
        meeting.setPage(8)
        #expect(meeting.oneToOneParticipants?.local.id == "self")
        #expect(meeting.oneToOneParticipants?.remote.id == "other")
        #expect(driver.visibleParticipantIDs == ["other", "self"])
        #expect(meeting.pageCount == 1 && meeting.pageIndex == 0)
        meeting.setLayout(.activeSpeaker)
        #expect(meeting.oneToOneParticipants?.remote.id == "other")
        #expect(driver.visibleParticipantIDs == ["other", "self"])
    }

    @Test func pinningSelfIsAnExplicitOverrideAndUnpinRestoresTheOverlay() async throws {
        let (meeting, driver, session) = try await fixture()
        driver.onEvent?(session, .participants([local, remote]))
        meeting.setPinnedParticipant(local.id)
        #expect(meeting.oneToOneParticipants == nil)
        #expect(meeting.presentationParticipant?.id == local.id)
        meeting.setPinnedParticipant(nil)
        #expect(meeting.oneToOneParticipants?.remote.id == remote.id)
        meeting.setPinnedParticipant(remote.id)
        #expect(meeting.oneToOneParticipants?.remote.id == remote.id)
    }

    @Test func thirdPersonRestoresCustomGalleryAndTheirDepartureRestoresThePair() async throws {
        let (meeting, driver, session) = try await fixture()
        let third = MeetingParticipant(id: "third", name: "Third")
        driver.onEvent?(session, .participants([local, remote, third]))
        meeting.moveGalleryParticipant(remote.id, to: local.id, sessionID: session)
        #expect(meeting.oneToOneParticipants == nil)
        driver.onEvent?(session, .participants([local, remote]))
        #expect(meeting.oneToOneParticipants?.remote.id == remote.id)
        driver.onEvent?(session, .participants([local, third, remote]))
        #expect(meeting.oneToOneParticipants == nil)
        #expect(meeting.visibleParticipants.map(\.id) == [remote.id, local.id, third.id])
        driver.onEvent?(session, .participants([local]))
        #expect(meeting.oneToOneParticipants == nil)
        #expect(meeting.visibleParticipants.map(\.id) == [local.id])
        await meeting.leave()
        #expect(meeting.oneToOneParticipants == nil)
    }

    @Test func sharingAndIncompleteRostersDoNotCreateAFalsePair() async throws {
        let (meeting, driver, session) = try await fixture()
        driver.onEvent?(session, .participants([remote, MeetingParticipant(id: "third", name: "Third")]))
        #expect(meeting.oneToOneParticipants == nil)
        driver.onEvent?(session, .participants([local, remote]))
        driver.onEvent?(session, .receivedShares([ReceivedMeetingShare(id: "share", ownerID: remote.id, ownerName: remote.name)]))
        #expect(meeting.oneToOneParticipants == nil)
        meeting.selectReceivedShare(nil)
        #expect(meeting.oneToOneParticipants?.remote.id == remote.id)
    }
}
