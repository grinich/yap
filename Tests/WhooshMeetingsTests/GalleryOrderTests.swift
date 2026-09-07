import Foundation
import Testing
@testable import WhooshMeetings

@Suite("Gallery reordering") @MainActor
struct GalleryOrderTests {
    private func people(_ ids: [String]) -> [MeetingParticipant] {
        ids.map { MeetingParticipant(id: $0, name: $0) }
    }
    private func fixture() async throws -> (MeetingCoordinator, DemoMeetingDriver, UUID) {
        let driver = DemoMeetingDriver(participantCount: 1)
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Self")
        let session = try #require(meeting.sessionID)
        driver.onEvent?(session, .participants(people(["A", "B", "C", "D"])))
        return (meeting, driver, session)
    }

    @Test func draggingInBothDirectionsShiftsTheInterveningTiles() async throws {
        let (meeting, driver, session) = try await fixture()
        #expect(meeting.moveGalleryParticipant("A", to: "C", sessionID: session))
        #expect(meeting.visibleParticipants.map(\.id) == ["B", "C", "A", "D"])
        #expect(driver.visibleParticipantIDs == ["B", "C", "A", "D"])
        #expect(meeting.moveGalleryParticipant("D", to: "B", sessionID: session))
        #expect(meeting.visibleParticipants.map(\.id) == ["D", "B", "C", "A"])
        #expect(meeting.participants.map(\.id) == ["A", "B", "C", "D"])
    }

    @Test func rosterUpdatesKeepOrderAndFreshMediaState() async throws {
        let (meeting, driver, session) = try await fixture()
        meeting.moveGalleryParticipant("D", to: "A", sessionID: session)
        var refreshed = people(["B", "D", "A", "C"])
        refreshed[1].name = "Renamed"
        refreshed[1].isCameraEnabled = true
        refreshed[1].isSpeaking = true
        driver.onEvent?(session, .participants(refreshed))
        #expect(meeting.visibleParticipants.map(\.id) == ["D", "A", "B", "C"])
        #expect(meeting.visibleParticipants.first?.name == "Renamed")
        #expect(meeting.visibleParticipants.first?.isCameraEnabled == true)
        #expect(meeting.visibleParticipants.first?.isSpeaking == true)
    }

    @Test func arrivalsAppendAndDeparturesDoNotDisturbRemainingTiles() async throws {
        let (meeting, driver, session) = try await fixture()
        meeting.moveGalleryParticipant("D", to: "A", sessionID: session)
        driver.onEvent?(session, .participants(people(["E", "C", "A", "D", "E"])))
        #expect(meeting.galleryParticipants.map(\.id) == ["D", "A", "C", "E"])
        #expect(!meeting.moveGalleryParticipant("B", to: "A", sessionID: session))
        #expect(!meeting.moveGalleryParticipant("A", to: "B", sessionID: session))
        driver.onEvent?(session, .participants(people(["B", "D", "A", "C", "E"])))
        #expect(meeting.galleryParticipants.map(\.id) == ["D", "A", "C", "E", "B"])
    }

    @Test func customOrderSurvivesPagingPinsAndSpeakerMode() async throws {
        let (meeting, driver, session) = try await fixture()
        meeting.moveGalleryParticipant("D", to: "A", sessionID: session)
        meeting.setPageSize(2)
        meeting.setPage(1)
        #expect(meeting.visibleParticipants.map(\.id) == ["B", "C"])
        meeting.moveGalleryParticipant("C", to: "B", sessionID: session)
        #expect(driver.visibleParticipantIDs == ["C", "B"])
        meeting.setPinnedParticipant("A")
        #expect(!meeting.moveGalleryParticipant("D", to: "A", sessionID: session))
        meeting.setLayout(.activeSpeaker)
        #expect(!meeting.moveGalleryParticipant("D", to: "A", sessionID: session))
        meeting.setLayout(.gallery)
        meeting.showAllParticipants()
        #expect(meeting.visibleParticipants.map(\.id) == ["D", "A", "C", "B"])
    }

    @Test func staleDragsCannotReorderANewSessionAndOrderResets() async throws {
        let (meeting, driver, session) = try await fixture()
        meeting.moveGalleryParticipant("D", to: "A", sessionID: session)
        await meeting.leave()
        await meeting.host(displayName: "New")
        let currentSession = try #require(meeting.sessionID)
        driver.onEvent?(currentSession, .participants(people(["A", "B", "C", "D"])))
        #expect(!meeting.moveGalleryParticipant("D", to: "A", sessionID: session))
        #expect(!meeting.moveGalleryParticipant("A", to: "A", sessionID: currentSession))
        #expect(meeting.visibleParticipants.map(\.id) == ["A", "B", "C", "D"])
    }
}
