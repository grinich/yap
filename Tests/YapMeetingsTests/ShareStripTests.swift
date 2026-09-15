import Foundation
import Testing
@testable import YapMeetings

@Suite("Screen share people") @MainActor
struct ShareStripTests {
    @Test func shareTransitionsRefreshNativeVideoSubscriptionsImmediately() async throws {
        let driver = StripDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Me")
        let session = try #require(meeting.sessionID)
        driver.onEvent?(session, .participants([
            MeetingParticipant(id: "me", name: "Me", isSelf: true),
            MeetingParticipant(id: "quiet", name: "Quiet", isCameraEnabled: true),
            MeetingParticipant(id: "room", name: "Room", isCameraEnabled: true, isConferenceRoom: true),
            MeetingParticipant(id: "speaker", name: "Speaker", isMuted: false, isCameraEnabled: true, isSpeaking: true)
        ]))
        meeting.setPageSize(2)
        meeting.setPage(1)
        meeting.setShareStripCapacity(2)
        #expect(driver.visibleIDs == ["room", "speaker"])
        let share = ReceivedMeetingShare(id: "share", ownerID: "room", ownerName: "Room")
        driver.onEvent?(session, .receivedShares([share]))
        #expect(driver.visibleIDs == ["me", "speaker"])

        meeting.selectReceivedShare(nil)
        #expect(driver.visibleIDs == ["room", "speaker"])
        meeting.toggleSharedContent()
        #expect(driver.visibleIDs == ["me", "speaker"])
        meeting.setShareStripCapacity(3)
        #expect(driver.visibleIDs == ["me", "room", "speaker"])
        driver.onEvent?(session, .receivedShares([]))
        #expect(driver.visibleIDs == ["room", "speaker"])
    }

    @Test func largeShareStripKeepsOnlyRenderedPeopleAndFollowsNewSpeaker() async throws {
        let driver = StripDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Me")
        let session = try #require(meeting.sessionID)
        var people = (0..<96).map {
            MeetingParticipant(id: "person-\($0)", name: "Person \($0)", isSelf: $0 == 0,
                               isMuted: false, isCameraEnabled: true, isSpeaking: $0 == 95,
                               isConferenceRoom: (1...8).contains($0))
        }
        driver.onEvent?(session, .participants(people))
        meeting.setShareStripCapacity(7)
        driver.onEvent?(session, .receivedShares([
            ReceivedMeetingShare(id: "share", ownerID: "person-1", ownerName: "Room")
        ]))
        #expect(driver.visibleIDs == ["person-0", "person-1", "person-2", "person-3", "person-4", "person-5", "person-95"])
        people[95].isSpeaking = false
        people[94].isSpeaking = true
        driver.onEvent?(session, .participants(people))
        #expect(driver.visibleIDs.count == 7)
        #expect(driver.visibleIDs.last == "person-94")
        #expect(!driver.visibleIDs.contains("person-95"))
        #expect(driver.visibleIDs == meeting.visibleShareStripParticipants.map(\.id))

        meeting.setShareStripCapacity(2)
        #expect(driver.visibleIDs == ["person-0", "person-94"])
        meeting.hideSelfView = true
        #expect(driver.visibleIDs == ["person-1", "person-94"])
    }

    @Test func prioritizesSelfRoomsAndSpeakers() async throws {
        let driver = StripDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Me")
        let session = try #require(meeting.sessionID)
        var people = [MeetingParticipant(id: "me", name: "Me", isSelf: true),
                      MeetingParticipant(id: "quiet", name: "Quiet", isCameraEnabled: true),
                      MeetingParticipant(id: "room", name: "Room", isCameraEnabled: true, isConferenceRoom: true),
                      MeetingParticipant(id: "speaker", name: "Speaker", isMuted: false, isCameraEnabled: true, isSpeaking: true),
                      MeetingParticipant(id: "off", name: "Off")]
        driver.onEvent?(session, .participants(people))
        #expect(meeting.shareStripParticipants.map(\.id) == ["me", "room", "speaker", "quiet"])
        #expect(meeting.shareStripParticipants(limit: 2).map(\.id) == ["me", "speaker"])
        people[3].isSpeaking = false
        people[1].isSpeaking = true
        people[1].isMuted = false
        driver.onEvent?(session, .participants(people))
        #expect(meeting.shareStripParticipants(limit: 3).map(\.id) == ["me", "room", "quiet"])
        meeting.hideSelfView = true
        #expect(!meeting.shareStripParticipants.contains { $0.isSelf })
        meeting.showNonVideoParticipants = true
        #expect(meeting.galleryParticipants.contains { $0.id == "off" })
        meeting.showNonVideoParticipants = false
        people[1].isCameraEnabled = false
        driver.onEvent?(session, .participants(people))
        #expect(meeting.shareStripParticipants.contains { $0.id == "quiet" })
        #expect(!meeting.galleryParticipants.contains { $0.id == "quiet" })
        meeting.setConferenceRoom("speaker", enabled: true)
        #expect(meeting.isConferenceRoom(people[3]))
        await meeting.leave()
        #expect(meeting.shareStripParticipants.isEmpty)
    }
}
@MainActor private final class StripDriver: MeetingDriver {
    let isDemo = true
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: true, canShare: false, supportsNativeVideo: false, canReceiveShare: true)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var replyID: String?
    var broadcasts = 0
    var visibleIDs: [String] = []
    func setVisibleParticipants(_ participantIDs: [String]) { visibleIDs = participantIDs }
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws { onEvent?(sessionID, .status(.inMeeting)) }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { onEvent?(sessionID, .status(.idle)) }
    func sendChat(text: String, sessionID: UUID) async throws { broadcasts += 1 }
    func sendChatReply(text: String, messageID: String, sessionID: UUID) async throws { replyID = messageID }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws {}
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws {}
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {}
    func stopShare(sessionID: UUID) async throws {}
}
