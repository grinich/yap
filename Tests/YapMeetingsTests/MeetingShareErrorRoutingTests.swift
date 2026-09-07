import Foundation
import ScreenCaptureKit
import Testing
@testable import YapMeetings

@Suite("Share chooser error ownership") @MainActor
struct MeetingShareErrorRoutingTests {
    @Test func permissionFailureStaysLocalToChooser() async throws {
        let driver = ShareErrorDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Fixture")
        driver.enumerationError = .screenCapturePermissionRequired
        do {
            _ = try await meeting.availableShareTargetsForChooser()
            Issue.record("Permission failure should be returned to the chooser")
        } catch { #expect(error as? MeetingError == .screenCapturePermissionRequired) }
        #expect(meeting.lastError == nil)
        #expect(meeting.isConnected)
    }

    @Test func unrelatedSdkErrorIsNotConsumedByChooserEnumeration() async throws {
        let driver = ShareErrorDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Fixture")
        driver.eventDuringEnumeration = "Video subscription interrupted"
        let targets = try await meeting.availableShareTargetsForChooser()
        #expect(targets == [driver.target])
        #expect(meeting.lastError == "Video subscription interrupted")
    }

    @Test func shareFailureDoesNotOverwriteOtherSdkError() async throws {
        let driver = ShareErrorDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Fixture")
        driver.onEvent?(meeting.sessionID!, .controlError("Audio device disconnected"))
        driver.shareError = .screenCapturePermissionRequired
        do {
            try await meeting.startShareFromChooser(driver.target)
            Issue.record("Rejected sharing should be returned to the chooser")
        } catch { #expect(error as? MeetingError == .screenCapturePermissionRequired) }
        #expect(meeting.lastError == "Audio device disconnected")
        #expect(!meeting.isApplyingControl)
        #expect(!meeting.sharing.isSharing)
    }

    @Test func successfulShareStillWaitsForDriverConfirmation() async throws {
        let driver = ShareErrorDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Fixture")
        try await meeting.startShareFromChooser(driver.target)
        #expect(driver.startedShares == 1)
        #expect(!meeting.sharing.isSharing)
        #expect(meeting.lastError == nil)
        driver.onEvent?(meeting.sessionID!, .sharing(.sharing(driver.target)))
        #expect(meeting.sharing.target == driver.target)
    }

    @Test func oldEnumerationCannotPublishInEndedMeeting() async throws {
        let driver = ShareErrorDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Fixture")
        driver.endDuringEnumeration = true
        do {
            _ = try await meeting.availableShareTargetsForChooser()
            Issue.record("Ended-session sources must be discarded")
        } catch { #expect(error is CancellationError) }
        #expect(meeting.status == .idle)
        #expect(meeting.lastError == nil)
    }

    @Test func cancellationBeforeEnumerationDoesNotReachDriver() async throws {
        let driver = ShareErrorDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Fixture")
        let task = Task { try await meeting.availableShareTargetsForChooser() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled source request must stop")
        } catch { #expect(error is CancellationError) }
        #expect(driver.enumerationRequests == 0)
        #expect(meeting.lastError == nil)
    }

    @Test func onlyScreenCaptureUserDenialOffersPermissionRecovery() {
        let denied = NSError(domain: SCStreamErrorDomain, code: SCStreamError.userDeclined.rawValue)
        #expect(MeetingScreenCaptureErrors.permissionWasDenied(denied))
        #expect(!MeetingScreenCaptureErrors.permissionWasDenied(NSError(domain: "UnrelatedError", code: denied.code)))
        #expect(!MeetingScreenCaptureErrors.permissionWasDenied(NSError(domain: SCStreamErrorDomain, code: -9999)))
        #expect(!MeetingScreenCaptureErrors.permissionWasDenied(CancellationError()))
    }
}

@MainActor private final class ShareErrorDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: false, canShare: true,
        supportsNativeVideo: false, canEnumerateShareTargets: true)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    let target = ShareTarget(id: "44", title: "Fixture window", kind: .window)
    var enumerationError: MeetingError?
    var shareError: MeetingError?
    var eventDuringEnumeration: String?
    var endDuringEnumeration = false
    var enumerationRequests = 0
    var startedShares = 0

    func connect(_ request: MeetingRequest, sessionID: UUID) async throws { onEvent?(sessionID, .status(.inMeeting)) }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { onEvent?(sessionID, .status(.idle)) }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func sendChat(text: String, sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func stopShare(sessionID: UUID) async throws { throw MeetingError.noMeeting }
    func availableShareTargets(sessionID: UUID) async throws -> [ShareTarget] {
        enumerationRequests += 1
        if let eventDuringEnumeration { onEvent?(sessionID, .controlError(eventDuringEnumeration)) }
        if endDuringEnumeration { onEvent?(sessionID, .status(.idle)) }
        if let enumerationError { throw enumerationError }
        return [target, target, ShareTarget(id: "preview", title: "Sample", kind: .demo)]
    }
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {
        if let shareError { throw shareError }
        startedShares += 1
    }
}
