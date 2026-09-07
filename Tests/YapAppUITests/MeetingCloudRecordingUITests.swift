import Foundation
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Cloud recording interface", .serialized) @MainActor
struct MeetingCloudRecordingUITests {
    @Test func unavailableActionsKeepTheSDKReasonAccessible() {
        let state = MeetingCloudRecordingControlsState(
            recording: MeetingCloudRecording(status: .unavailable, unavailableReason: "Cloud recording is disabled for this account."),
            isConnected: true, isBusy: false)
        #expect(state.actions == [.start])
        #expect(!state.canPerform(.start))
        #expect(state.disabledReason == "Cloud recording is disabled for this account.")
        #expect(state.statusLabel == nil)
    }

    @Test func startingRecordingIsNeutralAndCannotIssueAnotherCommand() {
        let state = MeetingCloudRecordingControlsState(
            recording: MeetingCloudRecording(status: .connecting, canControl: true), isConnected: true, isBusy: false)
        #expect(!state.recording.status.isActive)
        #expect(state.statusLabel == "Starting cloud recording…")
        #expect(state.controlSymbol == "record.circle")
        #expect(state.actions.isEmpty)
        #expect(MeetingCloudRecordingAction.allCases.allSatisfy { !state.canPerform($0) })
    }

    @Test func pendingFeedbackPrecedesSDKConfirmationAndClearsOnFailure() async {
        let driver = RecordingUIDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Fixture")
        let session = meeting.sessionID
        #expect(MeetingCloudRecordingControlsState(meeting: meeting).progressDescription == nil)

        await MeetingCloudRecordingRouting.perform(.start, sessionID: session, in: meeting)
        let requested = MeetingCloudRecordingControlsState(meeting: meeting)
        #expect(requested.progressDescription == "Requesting cloud recording…")
        #expect(requested.statusLabel == nil)
        #expect(!requested.recording.status.isActive)
        #expect(requested.controlSymbol == "record.circle")
        #expect(MeetingCloudRecordingAction.allCases.allSatisfy { !requested.canPerform($0) })

        driver.confirm(.connecting)
        #expect(MeetingCloudRecordingControlsState(meeting: meeting).progressDescription == "Starting cloud recording…")
        driver.confirm(.recording)
        #expect(MeetingCloudRecordingControlsState(meeting: meeting).progressDescription == nil)

        await MeetingCloudRecordingRouting.perform(.pause, sessionID: session, in: meeting)
        let updating = MeetingCloudRecordingControlsState(meeting: meeting)
        #expect(updating.progressDescription == "Updating cloud recording…")
        #expect(updating.statusLabel == "Recording to Cloud")
        #expect(updating.controlSymbol == "record.circle.fill")
        #expect(!updating.canPerform(.pause))
        #expect(!updating.canPerform(.stop))
        driver.onEvent?(session!, .cloudRecordingControlError("Fixture recording failure"))
        let recovered = MeetingCloudRecordingControlsState(meeting: meeting)
        #expect(recovered.progressDescription == nil)
        #expect(recovered.statusLabel == "Recording to Cloud")
        #expect(recovered.canPerform(.pause))

        await MeetingCloudRecordingRouting.perform(.pause, sessionID: session, in: meeting)
        driver.confirm(.paused)
        #expect(MeetingCloudRecordingControlsState(meeting: meeting).progressDescription == nil)
        #expect(MeetingCloudRecordingControlsState(meeting: meeting).statusLabel == "Cloud Recording Paused")
        await meeting.leave()
        #expect(MeetingCloudRecordingControlsState(meeting: meeting).progressDescription == nil)
    }

    @Test func activeStatusesExposeSpecificPauseResumeAndStopRecordingActions() {
        let recording = MeetingCloudRecordingControlsState(
            recording: MeetingCloudRecording(status: .recording, canControl: true), isConnected: true, isBusy: false)
        let paused = MeetingCloudRecordingControlsState(
            recording: MeetingCloudRecording(status: .paused, canControl: true), isConnected: true, isBusy: false)
        #expect(recording.actions == [.pause, .stop])
        #expect(paused.actions == [.resume, .stop])
        #expect(recording.statusLabel == "Recording to Cloud")
        #expect(paused.statusLabel == "Cloud Recording Paused")
        #expect(recording.controlSymbol == "record.circle.fill")
        #expect(paused.controlSymbol == "pause.circle.fill")
        #expect(MeetingCloudRecordingAction.stop.title == "Stop Cloud Recording")
        #expect(!recording.canPerform(.resume))
        #expect(!paused.canPerform(.pause))
        let denied = MeetingCloudRecordingControlsState(
            recording: MeetingCloudRecording(status: .recording, canControl: false, unavailableReason: "Only the host can control recording."),
            isConnected: true, isBusy: false)
        #expect(denied.statusLabel == recording.statusLabel)
        #expect(!denied.canPerform(.stop))
        #expect(denied.disabledReason == "Only the host can control recording.")
    }

    @Test func explicitActionsWaitForConfirmationAndNeverStopScreenSharing() async {
        let driver = RecordingUIDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Fixture")
        let session = meeting.sessionID
        _ = MeetingCloudRecordingControlsState(meeting: meeting)
        #expect(driver.commands.isEmpty)
        await MeetingCloudRecordingRouting.perform(.start, sessionID: session, in: meeting)
        #expect(driver.commands == [.start])
        #expect(meeting.cloudRecording.status == .stopped)
        #expect(MeetingCloudRecordingControlsState(meeting: meeting).statusLabel == nil)
        await MeetingCloudRecordingRouting.perform(.start, sessionID: session, in: meeting)
        #expect(driver.commands == [.start])
        driver.confirm(.recording)
        await MeetingCloudRecordingRouting.perform(.pause, sessionID: session, in: meeting)
        #expect(meeting.cloudRecording.status == .recording)
        driver.confirm(.paused)
        await MeetingCloudRecordingRouting.perform(.resume, sessionID: session, in: meeting)
        driver.confirm(.recording)
        await MeetingCloudRecordingRouting.perform(.stop, sessionID: session, in: meeting)
        #expect(driver.commands == [.start, .pause, .resume, .stop])
        #expect(driver.shareStops == 0)
        driver.confirm(.stopped)
        await meeting.leave()
    }

    @Test func menuSnapshotCannotRecordAfterPermissionLossOrInTheNextSession() async {
        let driver = RecordingUIDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Fixture")
        let previousSession = meeting.sessionID
        driver.confirm(.stopped, canControl: false)
        await MeetingCloudRecordingRouting.perform(.start, sessionID: previousSession, in: meeting)
        #expect(driver.commands.isEmpty)
        await meeting.leave()
        await meeting.host(displayName: "Fixture")
        await MeetingCloudRecordingRouting.perform(.start, sessionID: previousSession, in: meeting)
        #expect(driver.commands.isEmpty)
        driver.confirm(.recording)
        await MeetingCloudRecordingRouting.perform(.start, sessionID: meeting.sessionID, in: meeting)
        #expect(driver.commands.isEmpty)
        await MeetingCloudRecordingRouting.perform(.stop, sessionID: meeting.sessionID, in: meeting)
        #expect(driver.commands == [.stop])
        await meeting.leave()
    }

    @Test func disconnectedAndBusyActionsStayDisabled() {
        let recording = MeetingCloudRecording(status: .recording, canControl: true)
        let disconnected = MeetingCloudRecordingControlsState(recording: recording, isConnected: false, isBusy: false)
        let busy = MeetingCloudRecordingControlsState(recording: recording, isConnected: true, isBusy: true)
        #expect(!disconnected.canPerform(.stop))
        #expect(!busy.canPerform(.pause))
        #expect(!busy.canPerform(.stop))
        #expect(busy.statusLabel == "Recording to Cloud")
    }
}

@MainActor private final class RecordingUIDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: false, canShare: true, supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    private var sessionID: UUID?
    var commands: [MeetingCloudRecordingAction] = []
    var shareStops = 0
    func connect(_ request: MeetingRequest, sessionID: UUID) async throws {
        self.sessionID = sessionID
        onEvent?(sessionID, .status(.inMeeting))
        confirm(.stopped)
    }
    func confirm(_ status: MeetingCloudRecordingStatus, canControl: Bool = true) {
        guard let sessionID else { return }
        onEvent?(sessionID, .cloudRecording(MeetingCloudRecording(status: status, canControl: canControl)))
    }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { onEvent?(sessionID, .status(.idle)) }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws {}
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws {}
    func sendChat(text: String, sessionID: UUID) async throws {}
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {}
    func stopShare(sessionID: UUID) async throws { shareStops += 1 }
    func startCloudRecording(sessionID: UUID) async throws { commands.append(.start) }
    func pauseCloudRecording(sessionID: UUID) async throws { commands.append(.pause) }
    func resumeCloudRecording(sessionID: UUID) async throws { commands.append(.resume) }
    func stopCloudRecording(sessionID: UUID) async throws { commands.append(.stop) }
}
