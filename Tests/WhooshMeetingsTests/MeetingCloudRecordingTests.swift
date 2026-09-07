import Foundation
import Testing
@testable import WhooshMeetings

@Suite("Cloud recording authority and lifecycle") @MainActor
struct MeetingCloudRecordingTests {
    @Test func joiningNeverStartsRecordingAndUnavailableCannotDispatch() async {
        let driver = RecordingDriver()
        let model = MeetingCoordinator(driver: driver)
        await model.host(displayName: "Test")
        #expect(driver.commands.isEmpty)
        await model.startCloudRecording()
        #expect(driver.commands.isEmpty)
        #expect(model.lastError != nil)
        #expect(!model.cloudRecording.status.isActive)
    }

    @Test func commandAcceptanceDoesNotClaimRecordingAndDuplicateClicksCoalesce() async {
        let driver = RecordingDriver()
        let model = MeetingCoordinator(driver: driver)
        await model.host(displayName: "Test")
        driver.recording(.stopped)
        await model.startCloudRecording()
        await model.startCloudRecording()
        #expect(driver.commands == ["start"])
        #expect(model.isApplyingCloudRecordingControl)
        #expect(model.cloudRecording.status == .stopped)
        driver.recording(.connecting)
        #expect(model.isApplyingCloudRecordingControl)
        #expect(!model.cloudRecording.status.isActive)
        driver.recording(.recording)
        #expect(!model.isApplyingCloudRecordingControl)
        #expect(model.cloudRecording.status.isActive)
    }

    @Test func pauseResumeAndStopWaitForAuthoritativeCallbacks() async {
        let driver = RecordingDriver()
        let model = MeetingCoordinator(driver: driver)
        await model.host(displayName: "Test")
        driver.recording(.recording)
        await model.pauseCloudRecording()
        #expect(model.cloudRecording.status == .recording)
        driver.recording(.paused)
        await model.resumeCloudRecording()
        #expect(model.cloudRecording.status == .paused)
        driver.recording(.recording)
        await model.stopCloudRecording()
        #expect(model.cloudRecording.status == .recording)
        driver.recording(.stopped)
        #expect(!model.isApplyingCloudRecordingControl)
        #expect(driver.commands == ["pause", "resume", "stop"])
    }

    @Test func pausedRecordingCanBeStoppedWithoutResuming() async {
        let driver = RecordingDriver()
        let model = MeetingCoordinator(driver: driver)
        await model.host(displayName: "Test")
        driver.recording(.paused)
        await model.stopCloudRecording()
        #expect(driver.commands == ["stop"])
        driver.recording(.stopped)
        #expect(model.cloudRecording.status == .stopped)
    }

    @Test func roleLossPreservesGlobalRecordingIndicatorButRemovesControl() async {
        let driver = RecordingDriver()
        let model = MeetingCoordinator(driver: driver)
        await model.host(displayName: "Test")
        driver.recording(.recording)
        await model.pauseCloudRecording()
        driver.recording(.recording, canControl: false)
        #expect(!model.isApplyingCloudRecordingControl)
        #expect(model.cloudRecording.status.isActive)
        await model.stopCloudRecording()
        #expect(driver.commands == ["pause"])
        #expect(model.lastError == "Host controls recording.")
    }

    @Test func staleEventsAndPendingDeadlineCannotAffectNextCall() async throws {
        let driver = RecordingDriver()
        let model = MeetingCoordinator(driver: driver, cloudRecordingConfirmationTimeout: .milliseconds(40))
        await model.host(displayName: "Test")
        let oldID = model.sessionID!
        driver.recording(.stopped)
        await model.startCloudRecording()
        await model.leave()
        #expect(!model.isApplyingCloudRecordingControl)
        await model.host(displayName: "Test")
        driver.onEvent?(oldID, .cloudRecording(.init(status: .recording, canControl: true)))
        driver.onEvent?(oldID, .cloudRecordingControlError("Old error"))
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.cloudRecording.status == .unavailable)
        #expect(model.lastError == nil)
    }

    @Test func roleLossDuringConnectionCancelsPendingWithoutFalseTimeout() async throws {
        let driver = RecordingDriver()
        let model = MeetingCoordinator(driver: driver, cloudRecordingConfirmationTimeout: .milliseconds(20))
        await model.host(displayName: "Test")
        driver.recording(.stopped)
        await model.startCloudRecording()
        driver.recording(.connecting)
        #expect(model.isApplyingCloudRecordingControl)
        driver.recording(.connecting, canControl: false)
        #expect(!model.isApplyingCloudRecordingControl)
        try await Task.sleep(for: .milliseconds(70))
        #expect(model.lastError == nil)
        #expect(model.cloudRecording.status == .connecting)
    }

    @Test func missingConfirmationTimesOutWithoutInventingState() async throws {
        let driver = RecordingDriver()
        let model = MeetingCoordinator(driver: driver, cloudRecordingConfirmationTimeout: .milliseconds(20))
        await model.host(displayName: "Test")
        driver.recording(.stopped)
        await model.startCloudRecording()
        #expect(model.isApplyingCloudRecordingControl)
        // Concurrent main-actor tests can delay both the deadline task and this test.
        // Wait for the observed transition, while keeping a hard bound on failure.
        let deadline = ContinuousClock.now + .seconds(1)
        while model.isApplyingCloudRecordingControl, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!model.isApplyingCloudRecordingControl)
        #expect(model.cloudRecording.status == .stopped)
        #expect(model.lastError?.contains("hasn’t confirmed") == true)
        await model.startCloudRecording()
        #expect(driver.commands == ["start", "start"])
        driver.recording(.recording)
    }

    @Test func syncFailureAndAsyncFailureReleaseControlsWithoutEndingCall() async {
        let driver = RecordingDriver()
        let model = MeetingCoordinator(driver: driver)
        await model.host(displayName: "Test")
        driver.recording(.stopped)
        driver.shouldFail = true
        await model.startCloudRecording()
        #expect(!model.isApplyingCloudRecordingControl)
        #expect(model.cloudRecording.status == .stopped)
        #expect(model.lastError == "Storage is full.")
        driver.shouldFail = false
        await model.startCloudRecording()
        driver.onEvent?(model.sessionID!, .cloudRecordingControlError("Storage is full."))
        #expect(!model.isApplyingCloudRecordingControl)
        #expect(model.isConnected)
        #expect(model.cloudRecording.status == .stopped)
    }

    @Test func recordingControlsDoNotBlockMicOrSharing() async {
        let driver = RecordingDriver()
        let model = MeetingCoordinator(driver: driver)
        await model.host(displayName: "Test")
        driver.recording(.stopped)
        await model.startCloudRecording()
        await model.setMicrophoneMuted(false)
        #expect(driver.microphoneChanged)
        #expect(model.isApplyingCloudRecordingControl)
        driver.recording(.recording)
    }

    @Test func stateFromAnotherHostIsVisibleWithoutControl() async {
        let driver = RecordingDriver()
        let model = MeetingCoordinator(driver: driver)
        await model.host(displayName: "Test")
        driver.recording(.recording, canControl: false)
        #expect(model.cloudRecording.status.isActive)
        #expect(!model.cloudRecording.canControl)
        driver.recording(.paused, canControl: false)
        #expect(model.cloudRecording.status == .paused)
    }

    @Test func previewRecordingIsClearlySyntheticAndResets() async {
        let model = MeetingCoordinator(driver: DemoMeetingDriver())
        await model.host(displayName: "Test")
        #expect(model.isDemo)
        #expect(model.cloudRecording.status == .stopped)
        await model.startCloudRecording()
        #expect(model.cloudRecording.status == .recording)
        await model.leave()
        #expect(model.cloudRecording.status == .unavailable)
    }
}

@MainActor private final class RecordingDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: true, canShare: true, supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var sessionID: UUID?
    var commands: [String] = []
    var shouldFail = false
    var microphoneChanged = false
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws {
        self.sessionID = sessionID
        onEvent?(sessionID, .status(.inMeeting))
    }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws {
        self.sessionID = nil
        onEvent?(sessionID, .status(.idle))
    }
    func recording(_ status: MeetingCloudRecordingStatus, canControl: Bool = true) {
        onEvent?(sessionID!, .cloudRecording(.init(status: status, canControl: canControl,
            unavailableReason: canControl ? nil : "Host controls recording.")))
    }
    private func command(_ name: String) throws {
        commands.append(name)
        if shouldFail { throw MeetingError.unavailable("Storage is full.") }
    }
    func startCloudRecording(sessionID: UUID) async throws { try command("start") }
    func pauseCloudRecording(sessionID: UUID) async throws { try command("pause") }
    func resumeCloudRecording(sessionID: UUID) async throws { try command("resume") }
    func stopCloudRecording(sessionID: UUID) async throws { try command("stop") }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws { microphoneChanged = true }
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws {}
    func sendChat(text: String, sessionID: UUID) async throws {}
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {}
    func stopShare(sessionID: UUID) async throws {}
}
