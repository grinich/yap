import AppKit
import Foundation
import Testing
@testable import YapMeetings

@Suite("Meeting device controls and raised hands") @MainActor
struct MeetingMediaControlTests {
    @Test func handControlFollowsConnectedRosterAndSDKReadback() async {
        let driver = MediaControlFixtureDriver()
        let active = MeetingCoordinator(driver: driver)
        #expect(!active.canRaiseHand)
        await active.join(url: URL(string: "https://zoom.us/j/123456789")!, displayName: "You")
        driver.publishPeople(count: 1)
        #expect(!active.canRaiseHand)
        await active.setHandRaised(true)
        #expect(driver.handRequests.isEmpty)
        driver.publishPeople(count: 2)
        #expect(active.canRaiseHand)
        await active.setHandRaised(true)
        #expect(driver.handRequests == [true])
        #expect(!active.isHandRaised)
        driver.publishPeople(count: 2, raised: true)
        #expect(active.isHandRaised)
        driver.handError = MeetingError.unavailable("The host has disabled raising hands.")
        await active.setHandRaised(false)
        #expect(active.isHandRaised)
        #expect(active.lastError == "The host has disabled raising hands.")
        driver.publishPeople(count: 2, raised: false)
        #expect(!active.isHandRaised)
        driver.onEvent?(driver.session!, .status(.reconnecting))
        #expect(!active.canRaiseHand)
    }

    @Test func deviceSelectionUsesObservedHardwareAndPreservesReadbackOnFailure() async {
        let driver = MediaControlFixtureDriver()
        let active = MeetingCoordinator(driver: driver)
        await active.prepareMediaDevices()
        #expect(active.mediaDevices.microphones.first?.selected == true)
        await active.selectMediaDevice("disconnected", kind: .microphone)
        #expect(driver.selectionRequests.isEmpty)
        driver.selectionError = MeetingError.unavailable("The microphone was disconnected.")
        await active.selectMediaDevice("mic", kind: .microphone)
        #expect(active.mediaDevicesError == "The microphone was disconnected.")
        #expect(active.mediaDevices.microphones.first?.selected == true)
        var unplugged = driver.state
        unplugged.microphones = []
        driver.onMediaDevicesChanged?(unplugged)
        #expect(active.mediaDevices.microphones.isEmpty)
    }

    @Test func systemAudioChoiceUsesObservedReadbackAndKeepsChannelsIndependent() async {
        let driver = MediaControlFixtureDriver()
        driver.state.microphones.insert(.init(id: "yap.system-default", name: "Same as System (Fixture microphone)"), at: 0)
        driver.state.speakers.insert(.init(id: "yap.system-default", name: "Same as System (Fixture speaker)"), at: 0)
        let active = MeetingCoordinator(driver: driver)
        await active.prepareMediaDevices()
        let originalSpeakers = active.mediaDevices.speakers

        // Selecting the observed system entry is allowed, but the UI waits for
        // confirmed readback instead of claiming the physical route already changed.
        await active.selectMediaDevice("yap.system-default", kind: .microphone)
        #expect(driver.selectionRequests == ["yap.system-default"])
        #expect(active.mediaDevices.microphones.first?.selected == false)
        var changed = driver.state
        changed.microphones = [.init(id: "yap.system-default", name: "Same as System (USB microphone)", selected: true),
                               .init(id: "mic", name: "Fixture microphone"), .init(id: "usb", name: "USB microphone")]
        driver.onMediaDevicesChanged?(changed)
        #expect(active.mediaDevices.microphones.first?.name == "Same as System (USB microphone)")
        #expect(active.mediaDevices.microphones.filter(\.selected).map(\.id) == ["yap.system-default"])
        #expect(active.mediaDevices.speakers == originalSpeakers)
    }

    @Test func previewCanPinMicrophoneThenRestoreSystemWithoutChangingSpeakerOrCamera() async {
        let driver = DemoMeetingDriver()
        let active = MeetingCoordinator(driver: driver)
        await active.prepareMediaDevices()
        #expect(active.mediaDevices.microphones.filter(\.selected).map(\.id) == ["yap.system-default"])
        #expect(active.mediaDevices.speakers.filter(\.selected).map(\.id) == ["yap.system-default"])
        let originalSpeakers = active.mediaDevices.speakers
        let originalCameras = active.mediaDevices.cameras

        await active.selectMediaDevice("demo-usb-mic", kind: .microphone)
        #expect(active.mediaDevices.microphones.filter(\.selected).map(\.id) == ["demo-usb-mic"])
        #expect(active.mediaDevices.speakers == originalSpeakers)
        await active.selectMediaDevice("yap.system-default", kind: .microphone)
        #expect(active.mediaDevices.microphones.filter(\.selected).map(\.id) == ["yap.system-default"])
        #expect(active.mediaDevices.microphones.first?.name == "Same as System (Built-in Microphone)")
        #expect(active.mediaDevices.speakers == originalSpeakers)
        #expect(active.mediaDevices.cameras == originalCameras)
        #expect(active.mediaDevicesError == nil)
    }

    @Test func previewRetainsSystemChoiceAfterUsbDevicesDisconnect() async {
        let driver = DemoMeetingDriver()
        let active = MeetingCoordinator(driver: driver)
        await active.prepareMediaDevices()
        driver.simulateFixtureDeviceDisconnect()
        #expect(active.mediaDevices.microphones.filter(\.selected).map(\.id) == ["yap.system-default"])
        #expect(active.mediaDevices.speakers.filter(\.selected).map(\.id) == ["yap.system-default"])
        #expect(!active.mediaDevices.microphones.contains { $0.id == "demo-usb-mic" })
        #expect(!active.mediaDevices.speakers.contains { $0.id == "demo-headphones" })
        await active.selectMediaDevice("demo-mic", kind: .microphone)
        #expect(active.mediaDevices.microphones.filter(\.selected).map(\.id) == ["demo-mic"])
        #expect(active.mediaDevices.speakers.filter(\.selected).map(\.id) == ["yap.system-default"])
    }

    @Test func stoppingTestsRejectsLateCompletion() async throws {
        let driver = MediaControlFixtureDriver()
        let active = MeetingCoordinator(driver: driver)
        await active.prepareMediaDevices()
        driver.holdTest = true
        let task = Task { await active.setMediaTest(.microphone, running: true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while driver.pendingTest == nil && ContinuousClock.now < deadline { await Task.yield() }
        let pendingTest = try #require(driver.pendingTest)
        active.stopMediaTests()
        var late = driver.state; late.microphoneTest = "recording"
        pendingTest.resume(returning: late); driver.pendingTest = nil
        await task.value
        #expect(active.mediaDevices.microphoneTest == "idle")
        #expect(!active.isApplyingMediaControl)
        #expect(driver.stopRequests == 1)
    }

    @Test func invalidVolumesAndCameraVolumeNeverReachSDK() async {
        let driver = MediaControlFixtureDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.prepareMediaDevices()
        await meeting.setMediaVolume(-1, kind: .microphone)
        await meeting.setMediaVolume(101, kind: .speaker)
        await meeting.setMediaVolume(50, kind: .camera)
        #expect(driver.volumeRequests.isEmpty)
        await meeting.setMediaVolume(25, kind: .speaker)
        #expect(driver.volumeRequests == [25])
        #expect(meeting.mediaDevices.speakerVolume == 25)
    }
}

@MainActor private final class MediaControlFixtureDriver: MeetingDriver, MeetingMediaDriver {
    let isDemo = true
    let capabilities = MeetingCapabilities(canJoin: true, canHost: false, canChat: false, canShare: false, supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var onMediaDevicesChanged: (@MainActor (MeetingMediaState) -> Void)?
    var session: UUID?
    var handRequests: [Bool] = []
    var handError: Error?
    var selectionError: Error?
    var selectionRequests: [String] = []
    var volumeRequests: [Int] = []
    var stopRequests = 0
    var holdTest = false
    var pendingTest: CheckedContinuation<MeetingMediaState, Never>?
    var state = MeetingMediaState(isReady: true,
        microphones: [.init(id: "mic", name: "Fixture microphone", selected: true)],
        speakers: [.init(id: "speaker", name: "Fixture speaker", selected: true)],
        speakerVolume: 50, canSetSpeakerVolume: true)
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws {
        session = sessionID; onEvent?(sessionID, .status(.inMeeting)); publishPeople(count: 2)
    }
    func publishPeople(count: Int, raised: Bool = false) {
        guard let session else { return }
        var people = [MeetingParticipant(id: "self", name: "You", isSelf: true, isHandRaised: raised)]
        if count > 1 { people.append(.init(id: "other", name: "Teammate")) }
        onEvent?(session, .participants(people))
    }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { onEvent?(sessionID, .status(.idle)) }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws {}
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws {}
    func setHandRaised(_ raised: Bool, sessionID: UUID) async throws { handRequests.append(raised); if let handError { throw handError } }
    func sendChat(text: String, sessionID: UUID) async throws {}
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {}
    func stopShare(sessionID: UUID) async throws {}
    func prepareMediaDevices() async throws -> MeetingMediaState { state }
    func selectMediaDevice(_ deviceID: String, kind: MeetingMediaKind) async throws -> MeetingMediaState {
        selectionRequests.append(deviceID); if let selectionError { throw selectionError }; return state
    }
    func setMediaVolume(_ volume: Int, kind: MeetingMediaKind) async throws -> MeetingMediaState {
        volumeRequests.append(volume); if kind == .speaker { state.speakerVolume = volume }; return state
    }
    func setAutomaticMicrophoneVolume(_ enabled: Bool) async throws -> MeetingMediaState { state.automaticMicrophoneVolume = enabled; return state }
    func setMediaTest(_ kind: MeetingMediaKind, running: Bool) async throws -> MeetingMediaState {
        if holdTest { return await withCheckedContinuation { pendingTest = $0 } }; return state
    }
    func stopMediaTests() { stopRequests += 1; state.microphoneTest = "idle"; onMediaDevicesChanged?(state) }
}
