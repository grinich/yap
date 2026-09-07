import Foundation
import Testing
@testable import YapMeetings

@Suite("Gallery and active speaker") @MainActor
struct MeetingLayoutTests {
    private func person(_ id: String, speaking: Bool = false, muted: Bool = false, isSelf: Bool = false) -> MeetingParticipant {
        MeetingParticipant(id: id, name: id, isSelf: isSelf, isMuted: muted,
                           isCameraEnabled: true, isSpeaking: speaking)
    }

    private func fixture() async throws -> (MeetingCoordinator, DemoMeetingDriver, UUID) {
        let driver = DemoMeetingDriver(participantCount: 1)
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Self")
        return (meeting, driver, try #require(meeting.sessionID))
    }

    @Test func activeSpeakerCanComeFromOutsideTheGalleryPage() async throws {
        let (meeting, driver, session) = try await fixture()
        let people = (0..<150).map { person("person-\($0)", speaking: $0 == 149, isSelf: $0 == 0) }
        driver.onEvent?(session, .participants(people))
        meeting.setPageSize(25)
        #expect(meeting.layout == .gallery)
        #expect(meeting.visibleParticipants.count == 25)
        #expect(meeting.presentationParticipant == nil)
        meeting.setLayout(.activeSpeaker)
        #expect(meeting.presentationParticipant?.id == "person-149")
        #expect(meeting.visibleParticipants.count == 7)
        #expect(driver.visibleParticipantIDs.first == "person-149")
        #expect(Set(driver.visibleParticipantIDs).count == 7)
        #expect(meeting.pageCount == 1)
        meeting.setLayout(.gallery)
        #expect(meeting.pageSize == 25)
        #expect(meeting.pageCount == 6)
        #expect(driver.visibleParticipantIDs == Array(people.prefix(25)).map(\.id))
    }

    @Test func silenceAndOverlappingSpeechDoNotBounceBetweenPeople() async throws {
        let (meeting, driver, session) = try await fixture()
        meeting.setLayout(.activeSpeaker)
        driver.onEvent?(session, .participants([person("self", isSelf: true), person("A", speaking: true), person("B")]))
        #expect(meeting.presentationParticipant?.id == "A")
        driver.onEvent?(session, .participants([person("self", isSelf: true), person("A"), person("B", speaking: true)]))
        #expect(meeting.presentationParticipant?.id == "B")
        driver.onEvent?(session, .participants([person("self", isSelf: true), person("A"), person("B")]))
        #expect(meeting.presentationParticipant?.id == "B")
        driver.onEvent?(session, .participants([person("self", isSelf: true), person("A", speaking: true), person("B", speaking: true)]))
        #expect(meeting.presentationParticipant?.id == "B")
        driver.onEvent?(session, .participants([person("self", isSelf: true), person("A", speaking: true), person("B")]))
        #expect(meeting.presentationParticipant?.id == "A")
    }

    @Test func pinOverridesFollowingAndUnpinResumesTheLatestSpeaker() async throws {
        let (meeting, driver, session) = try await fixture()
        meeting.setLayout(.activeSpeaker)
        driver.onEvent?(session, .participants([person("A", speaking: true), person("B"), person("C")]))
        meeting.setPinnedParticipant("C")
        driver.onEvent?(session, .participants([person("A"), person("B", speaking: true), person("C")]))
        #expect(meeting.presentationParticipant?.id == "C")
        #expect(driver.visibleParticipantIDs.first == "C")
        meeting.setPinnedParticipant(nil)
        #expect(meeting.presentationParticipant?.id == "B")
        meeting.setPinnedParticipant("A")
        meeting.setLayout(.activeSpeaker)
        #expect(meeting.pinnedParticipantID == nil)
        #expect(meeting.presentationParticipant?.id == "B")
    }

    @Test func departureClearsPinsAndSelectsAUsableFallback() async throws {
        let (meeting, driver, session) = try await fixture()
        meeting.setLayout(.activeSpeaker)
        driver.onEvent?(session, .participants([person("self", isSelf: true), person("A", speaking: true), person("B")]))
        meeting.setPinnedParticipant("A")
        driver.onEvent?(session, .participants([person("self", isSelf: true), person("B")]))
        #expect(meeting.pinnedParticipantID == nil)
        #expect(meeting.presentationParticipant?.id == "B")
        driver.onEvent?(session, .participants([person("self", isSelf: true)]))
        #expect(meeting.presentationParticipant?.id == "self")
        driver.onEvent?(session, .participants([]))
        #expect(meeting.presentationParticipant == nil)
        #expect(driver.visibleParticipantIDs.isEmpty)
    }

    @Test func mutedOrLocalSpeechDoesNotReplaceAnotherParticipant() async throws {
        let (meeting, driver, session) = try await fixture()
        meeting.setLayout(.activeSpeaker)
        driver.onEvent?(session, .participants([person("self", speaking: true, isSelf: true), person("A"), person("B", speaking: true, muted: true)]))
        #expect(meeting.presentationParticipant?.id == "A")
        driver.onEvent?(session, .participants([person("self", speaking: true, isSelf: true), person("A"), person("B", speaking: true)]))
        #expect(meeting.presentationParticipant?.id == "B")
    }

    @Test func modeSurvivesMeetingsButPinsAndSpeakerIdentityDoNot() async throws {
        let (meeting, driver, oldSession) = try await fixture()
        meeting.setLayout(.activeSpeaker)
        driver.onEvent?(oldSession, .participants([person("old")]))
        meeting.setPinnedParticipant("old")
        await meeting.leave()
        #expect(meeting.layout == .activeSpeaker)
        #expect(meeting.pinnedParticipantID == nil && meeting.activeSpeakerID == nil)
        await meeting.host(displayName: "New session")
        let current = meeting.activeSpeakerID
        driver.onEvent?(oldSession, .participants([person("stale", speaking: true)]))
        #expect(meeting.activeSpeakerID == current)
        #expect(!driver.visibleParticipantIDs.contains("stale"))
    }

    @Test func gallerySelectionRemovesPinAndKeepsShowAllPreference() async throws {
        let (meeting, driver, session) = try await fixture()
        driver.onEvent?(session, .participants((0..<150).map { person("\($0)") }))
        meeting.showAllParticipants()
        meeting.setPinnedParticipant("149")
        #expect(meeting.visibleParticipants.count == 7)
        meeting.setLayout(.gallery)
        #expect(meeting.pinnedParticipantID == nil)
        #expect(meeting.visibleParticipants.count == 150 && meeting.showsAllParticipants)
        meeting.setLayout(.activeSpeaker)
        meeting.setLayout(.gallery)
        #expect(driver.visibleParticipantIDs.count == 150)
    }
}
