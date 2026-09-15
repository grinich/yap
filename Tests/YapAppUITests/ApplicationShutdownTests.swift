import AppKit
import Foundation
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Application SDK shutdown") @MainActor
struct ApplicationShutdownTests {
    @Test func sdkShutdownRefusalCancelsQuitAndKeepsSettingsUsableForRetry() async {
        let fixture = ShutdownFixture()
        defer { fixture.remove() }
        await fixture.model.cameraEffects.prepare()
        await fixture.model.cameraEffects.startPreview()
        await fixture.model.meeting.prepareMediaDevices()
        let delegate = YapApplicationDelegate()
        delegate.model = fixture.model
        fixture.driver.allowsShutdown = false

        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(fixture.driver.shutdownCalls == 1)
        #expect(fixture.model.error?.contains("still closing") == true)
        #expect(fixture.driver.onEvent != nil)
        #expect(fixture.driver.onMediaDevicesChanged != nil)
        #expect(fixture.model.cameraEffects.preview != nil)
        #expect(fixture.model.meeting.mediaDevices.isReady)
        await fixture.model.meeting.prepareMediaDevices()
        #expect(fixture.driver.mediaPrepareCalls == 2)

        fixture.driver.allowsShutdown = true
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(fixture.driver.shutdownCalls == 2)
        #expect(fixture.model.cameraEffects.preview == nil)
        #expect(!fixture.model.meeting.mediaDevices.isReady)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(fixture.driver.shutdownCalls == 2)
    }

    @Test func liveSDKRefusalLeavesDisplayedPreviewUsable() async {
        let fixture = ShutdownFixture()
        defer { fixture.remove() }
        fixture.model.enterPreview()
        fixture.driver.allowsShutdown = false

        #expect(!fixture.model.shutdownForTermination())
        await fixture.model.meeting.host(displayName: "Fixture")

        #expect(fixture.model.meeting.isConnected)
        await fixture.model.leaveMeeting()
        fixture.driver.allowsShutdown = true
        #expect(fixture.model.shutdownForTermination())
    }

    @Test func quittingWithoutJoiningClosesSettingsSDKExactlyOnce() async {
        let fixture = ShutdownFixture()
        defer { fixture.remove() }
        await fixture.model.cameraEffects.prepare()
        await fixture.model.cameraEffects.startPreview()
        await fixture.model.meeting.prepareMediaDevices()
        #expect(fixture.model.cameraEffects.preview != nil)
        #expect(fixture.model.meeting.mediaDevices.isReady)
        #expect(!fixture.model.activeCall)
        let delegate = YapApplicationDelegate()
        delegate.model = fixture.model

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        #expect(fixture.driver.shutdownCalls == 1)
        #expect(fixture.driver.stopTestCalls == 1)
        #expect(fixture.model.cameraEffects.preview == nil)
        #expect(fixture.model.cameraEffects.status == nil)
        #expect(!fixture.model.meeting.mediaDevices.isReady)
        #expect(fixture.driver.onEvent == nil)
        #expect(fixture.driver.onMediaDevicesChanged == nil)
    }

    @Test func delayedDevicePreparationCannotRestoreStateOrRestartAfterQuit() async throws {
        let fixture = ShutdownFixture()
        defer { fixture.remove() }
        fixture.driver.holdMediaPreparation = true
        let preparation = Task { await fixture.model.meeting.prepareMediaDevices() }
        await fixture.driver.waitForPreparation()
        #expect(fixture.model.meeting.isPreparingMediaDevices)
        let queuedDeviceCallback = fixture.driver.onMediaDevicesChanged

        #expect(fixture.model.shutdownForTermination())
        fixture.driver.finishPreparation()
        await preparation.value
        queuedDeviceCallback?(MeetingMediaState(isReady: true, speakerTestRunning: true))
        await fixture.model.meeting.prepareMediaDevices()
        await fixture.model.meeting.host(displayName: "Fixture")

        #expect(!fixture.model.meeting.isPreparingMediaDevices)
        #expect(!fixture.model.meeting.mediaDevices.isReady)
        #expect(fixture.model.meeting.mediaDevicesError == nil)
        #expect(fixture.driver.mediaPrepareCalls == 1)
        #expect(fixture.driver.connectCalls == 0)
        #expect(fixture.driver.shutdownCalls == 1)
    }

    @Test func activeMeetingAndPendingLeavePreventPrematureSDKShutdown() async throws {
        let fixture = ShutdownFixture()
        defer { fixture.remove() }
        await fixture.model.meeting.host(displayName: "Fixture")
        let session = try #require(fixture.model.meeting.sessionID)

        #expect(!fixture.model.shutdownForTermination())
        #expect(fixture.driver.shutdownCalls == 0)
        #expect(fixture.model.meeting.isConnected)
        await fixture.model.leaveMeeting()
        #expect(fixture.model.meeting.status == .leaving)
        #expect(!fixture.model.shutdownForTermination())
        #expect(!(await fixture.model.meeting.waitForMeetingEnd(timeout: .zero)))
        #expect(fixture.driver.shutdownCalls == 0)

        fixture.driver.onEvent?(session, .status(.idle))
        #expect(await fixture.model.meeting.waitForMeetingEnd(timeout: .zero))
        #expect(fixture.model.shutdownForTermination())
        #expect(fixture.driver.shutdownCalls == 1)
        #expect(fixture.driver.leaveRequests == [false])
    }

    @Test func previewQuitAlsoClosesTheSavedLiveSDK() async {
        let fixture = ShutdownFixture()
        defer { fixture.remove() }
        let live = fixture.model.meeting
        fixture.model.enterPreview()
        #expect(fixture.model.meeting !== live)
        // Native device menus can still prepare the live settings driver while
        // the main window displays a demo rather than a real meeting.
        await live.prepareMediaDevices()
        #expect(live.mediaDevices.isReady)

        #expect(fixture.model.shutdownForTermination())

        #expect(fixture.driver.shutdownCalls == 1)
        #expect(!live.mediaDevices.isReady)
        await live.prepareMediaDevices()
        #expect(fixture.driver.mediaPrepareCalls == 1)
    }
}

@MainActor private final class ShutdownFixture {
    let suite = "ApplicationShutdownTests.\(UUID())"
    let preferences: UserDefaults
    let driver = ShutdownDriver()
    let model: YapModel
    init() {
        preferences = UserDefaults(suiteName: suite)!
        model = YapModel(preview: false, preferences: preferences,
            meeting: MeetingCoordinator(driver: driver),
            reminders: YapReminderActions(requestAuthorization: { false }, synchronize: { _, _ in }, disable: {}),
            loadGoogleConfiguration: { nil })
    }
    func remove() { preferences.removePersistentDomain(forName: suite) }
}

@MainActor private final class ShutdownDriver: MeetingDriver, MeetingMediaDriver, CameraEffectsDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: false,
        canShare: false, supportsNativeVideo: false)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var onMediaDevicesChanged: (@MainActor (MeetingMediaState) -> Void)?
    var onCameraEffectsChanged: (@MainActor (CameraEffectsStatus) -> Void)?
    var shutdownCalls = 0
    var allowsShutdown = true
    var stopTestCalls = 0
    var mediaPrepareCalls = 0
    var connectCalls = 0
    var leaveRequests: [Bool] = []
    var holdMediaPreparation = false
    private var mediaPreparation: CheckedContinuation<MeetingMediaState, Never>?
    private var preparationWaiter: CheckedContinuation<Void, Never>?

    func connect(_ request: MeetingRequest, sessionID: UUID) async throws {
        connectCalls += 1
        onEvent?(sessionID, .status(.inMeeting))
    }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { leaveRequests.append(endForEveryone) }
    func shutdown() -> Bool { shutdownCalls += 1; return allowsShutdown }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws {}
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws {}
    func sendChat(text: String, sessionID: UUID) async throws {}
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {}
    func stopShare(sessionID: UUID) async throws {}

    func prepareMediaDevices() async throws -> MeetingMediaState {
        mediaPrepareCalls += 1
        guard holdMediaPreparation else { return MeetingMediaState(isReady: true) }
        return await withCheckedContinuation {
            mediaPreparation = $0
            preparationWaiter?.resume(); preparationWaiter = nil
        }
    }
    func waitForPreparation() async {
        if mediaPreparation != nil { return }
        await withCheckedContinuation { preparationWaiter = $0 }
    }
    func finishPreparation() {
        mediaPreparation?.resume(returning: MeetingMediaState(isReady: true, speakerTestRunning: true))
        mediaPreparation = nil
    }
    func selectMediaDevice(_ deviceID: String, kind: MeetingMediaKind) async throws -> MeetingMediaState { MeetingMediaState() }
    func setMediaVolume(_ volume: Int, kind: MeetingMediaKind) async throws -> MeetingMediaState { MeetingMediaState() }
    func setAutomaticMicrophoneVolume(_ enabled: Bool) async throws -> MeetingMediaState { MeetingMediaState() }
    func setMediaTest(_ kind: MeetingMediaKind, running: Bool) async throws -> MeetingMediaState { MeetingMediaState() }
    func stopMediaTests() { stopTestCalls += 1 }

    func setPreferredCameraEffects(_ preferences: CameraEffectsPreferences) {}
    func prepareCameraEffects() async throws -> CameraEffectsStatus { CameraEffectsStatus(supportsBlur: true) }
    func applyCameraEffects(_ preferences: CameraEffectsPreferences) async throws -> CameraEffectsStatus { CameraEffectsStatus(appliedPreferences: preferences) }
    func startCameraEffectsPreview() async throws -> NSView { NSView() }
    func stopCameraEffectsPreview() {}
    func closeCameraEffects() {}
}
