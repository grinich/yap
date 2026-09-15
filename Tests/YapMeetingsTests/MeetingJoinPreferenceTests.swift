import Foundation
import Testing
@testable import YapMeetings

@Suite("Meeting join media preference") @MainActor
struct MeetingJoinPreferenceTests {
    private let url = URL(string: "https://zoom.us/j/12345678901")!

    @Test(arguments: [false, true])
    func defaultEntryKeepsMicrophoneMutedAndCameraOff(host: Bool) async throws {
        let driver = JoinPreferenceDriver()
        let meeting = MeetingCoordinator(driver: driver)
        if host { await meeting.host(displayName: " Me ") }
        else { await meeting.join(url: url, displayName: " Me ") }
        let request = try #require(driver.requests.first)
        #expect(request.displayName == "Me")
        #expect(request.isHost == host)
        #expect(request.microphoneMuted)
        #expect(!request.cameraEnabled)
        #expect(driver.mediaCommands == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func explicitPreferenceIsCapturedByEachFutureEntry(host: Bool, quietly: Bool) async throws {
        let driver = JoinPreferenceDriver()
        let meeting = MeetingCoordinator(driver: driver)
        if host { await meeting.host(displayName: "Me", joinQuietly: quietly) }
        else { await meeting.join(url: url, displayName: "Me", joinQuietly: quietly) }
        let request = try #require(driver.requests.first)
        #expect(request.microphoneMuted == quietly)
        #expect(request.cameraEnabled == !quietly)
        // Request intent must not impersonate confirmed device state.
        #expect(meeting.isMicrophoneMuted)
        #expect(!meeting.isCameraEnabled)
        #expect(driver.mediaCommands == 0)
    }

    @Test func entryPreferenceCannotChangeActiveMediaOrReplayOnReconnect() async throws {
        let driver = JoinPreferenceDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.join(url: url, displayName: "Me", joinQuietly: false)
        let session = try #require(meeting.sessionID)
        driver.onEvent?(session, .status(.inMeeting))
        driver.onEvent?(session, .microphoneMuted(true))
        driver.onEvent?(session, .cameraEnabled(false))
        await meeting.host(displayName: "Me", joinQuietly: false)
        driver.onEvent?(session, .status(.reconnecting))
        driver.onEvent?(session, .status(.inMeeting))
        #expect(driver.requests.count == 1)
        #expect(driver.mediaCommands == 0)
        #expect(meeting.isMicrophoneMuted)
        #expect(!meeting.isCameraEnabled)
        await meeting.leave()
        await meeting.join(url: url, displayName: "Me")
        #expect(driver.requests.last?.microphoneMuted == true)
        #expect(driver.requests.last?.cameraEnabled == false)
    }

    @Test func roomSharingDoesNotInheritAnEarlierMediaOptIn() async throws {
        let driver = JoinPreferenceDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Me", joinQuietly: false)
        await meeting.leave()
        await meeting.shareToRoom(displayName: "Me")
        let request = try #require(driver.requests.last)
        #expect(request.isRoomShare)
        #expect(request.microphoneMuted)
        #expect(!request.cameraEnabled)
        #expect(driver.mediaCommands == 0)
    }
}

@MainActor private final class JoinPreferenceDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: false, canShare: false,
                                          supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var requests: [MeetingRequest] = []
    var mediaCommands = 0
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws { requests.append(request) }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { onEvent?(sessionID, .status(.idle)) }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws { mediaCommands += 1 }
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws { mediaCommands += 1 }
    func sendChat(text: String, sessionID: UUID) async throws {}
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {}
    func stopShare(sessionID: UUID) async throws {}
}
