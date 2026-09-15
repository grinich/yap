import Foundation
import Testing
@testable import YapMeetings

@Suite("Bounded group photo cameras") @MainActor
struct GroupPhotoBatchTests {
    private func people(_ count: Int) -> [MeetingParticipant] {
        (0..<count).map {
            MeetingParticipant(id: "p\($0)", name: "Person \($0)", isSelf: $0 == 0, isCameraEnabled: true)
        }
    }

    private func fixture(_ count: Int = 200) async throws -> (MeetingCoordinator, PhotoBatchDriver, UUID) {
        let driver = PhotoBatchDriver()
        let meeting = MeetingCoordinator(driver: driver)
        await meeting.host(displayName: "Me")
        let session = try #require(meeting.sessionID)
        driver.onEvent?(session, .participants(people(count)))
        return (meeting, driver, session)
    }

    @Test func all200CamerasAreVisitedOnceInBatchesOf49WithReleaseBetweenBatches() async throws {
        let (meeting, driver, session) = try await fixture()
        meeting.setPageSize(25)
        meeting.setPage(3)
        let originalIDs = meeting.visibleParticipants.map(\.id)
        let originalPage = meeting.pageIndex
        driver.subscriptions = []

        let snapshot = try meeting.beginGroupPhoto(sessionID: session)
        #expect(snapshot.map(\.id) == people(200).map(\.id))
        #expect(meeting.visibleParticipants.isEmpty)
        #expect(driver.subscriptions == [[]])
        var capturedIDs: [String] = []
        var batchSizes: [Int] = []
        for start in stride(from: 0, to: snapshot.count, by: MeetingCoordinator.groupPhotoBatchSize) {
            let batchIDs = snapshot[start..<min(start + MeetingCoordinator.groupPhotoBatchSize, snapshot.count)].map(\.id)
            let oldCalls = driver.subscriptions.count
            try meeting.selectGroupPhotoBatch(participantIDs: batchIDs, sessionID: session)
            try meeting.validateGroupPhotoBatch(sessionID: session)
            #expect(Array(driver.subscriptions.dropFirst(oldCalls)) == [[], batchIDs])
            #expect(meeting.photoBatchParticipants.map(\.id) == batchIDs)
            #expect(meeting.visibleParticipants.map(\.id) == batchIDs)
            capturedIDs += batchIDs
            batchSizes.append(batchIDs.count)
        }
        #expect(batchSizes == [49, 49, 49, 49, 4])
        #expect(capturedIDs == snapshot.map(\.id))
        #expect(Set(capturedIDs).count == 200)
        #expect(driver.subscriptions.allSatisfy { $0.count <= 49 })

        meeting.endGroupPhoto(sessionID: session)
        #expect(!meeting.isTakingGroupPhoto)
        #expect(meeting.photoBatchParticipants.isEmpty)
        #expect(meeting.pageIndex == originalPage)
        #expect(meeting.visibleParticipants.map(\.id) == originalIDs)
        #expect(driver.subscriptions.last == originalIDs)
    }

    @Test func snapshotKeepsOrderAndHideSelfAndDoesNotAddNewCamerasOrArrivals() async throws {
        let (meeting, driver, session) = try await fixture(5)
        var roster = meeting.participants
        roster[3].isCameraEnabled = false
        driver.onEvent?(session, .participants(roster))
        meeting.hideSelfView = true
        #expect(meeting.moveGalleryParticipant("p4", to: "p1", sessionID: session))
        let snapshot = try meeting.beginGroupPhoto(sessionID: session)
        #expect(snapshot.map(\.id) == ["p4", "p1", "p2"])

        roster[1].name = "A new name"
        roster[3].isCameraEnabled = true
        roster.append(MeetingParticipant(id: "new", name: "Arriving", isCameraEnabled: true))
        driver.onEvent?(session, .participants(Array(roster.reversed())))
        meeting.hideSelfView = false
        #expect(meeting.photoParticipants == snapshot)
        try meeting.selectGroupPhotoBatch(participantIDs: snapshot.map(\.id), sessionID: session)
        #expect(meeting.visibleParticipants == snapshot)
        meeting.endGroupPhoto(sessionID: session)
        #expect(meeting.photoParticipants.count == 6)
        #expect(meeting.photoParticipants.contains { $0.id == "p1" && $0.name == "A new name" })
    }

    @Test func clearingAndCancelingRestoresPinnedSpeakerAndSharingLayouts() async throws {
        let (meeting, driver, session) = try await fixture(60)
        meeting.setLayout(.activeSpeaker)
        meeting.setPinnedParticipant("p30")
        let originalIDs = meeting.visibleParticipants.map(\.id)
        try meeting.beginGroupPhoto(sessionID: session)
        try meeting.selectGroupPhotoBatch(participantIDs: ["p59"], sessionID: session)
        meeting.clearGroupPhotoBatch(sessionID: session)
        #expect(meeting.isTakingGroupPhoto)
        #expect(meeting.photoParticipants.count == 60)
        #expect(driver.subscriptions.last == [])
        #expect(meeting.visibleParticipants.isEmpty)
        meeting.endGroupPhoto(sessionID: session)
        #expect(meeting.layout == .activeSpeaker)
        #expect(meeting.pinnedParticipantID == "p30")
        #expect(driver.subscriptions.last == originalIDs)

        driver.onEvent?(session, .receivedShares([ReceivedMeetingShare(id: "share", ownerID: "p3", ownerName: "Presenter")]))
        let sharingIDs = meeting.visibleParticipants.map(\.id)
        try meeting.beginGroupPhoto(sessionID: session)
        try meeting.selectGroupPhotoBatch(participantIDs: ["p59"], sessionID: session)
        meeting.endGroupPhoto(sessionID: session)
        #expect(meeting.selectedReceivedShareID == "share")
        #expect(driver.subscriptions.last == sharingIDs)
    }

    @Test(arguments: [true, false])
    func departureOrCameraOffFailsTheWholeFrozenPhotoAndReleasesItsBatch(departs: Bool) async throws {
        let (meeting, driver, session) = try await fixture(100)
        let snapshot = try meeting.beginGroupPhoto(sessionID: session)
        try meeting.selectGroupPhotoBatch(participantIDs: Array(snapshot.prefix(49)).map(\.id), sessionID: session)
        var changed = snapshot
        // Even someone in a later batch must not silently be omitted.
        if departs { changed.removeLast() }
        else { changed[99].isCameraEnabled = false }
        driver.onEvent?(session, .participants(changed))
        #expect(meeting.photoParticipants == snapshot)
        #expect(meeting.photoBatchParticipants.isEmpty)
        #expect(driver.subscriptions.last == [])
        #expect(throws: MeetingError.self) { try meeting.validateGroupPhotoBatch(sessionID: session) }
        #expect(throws: MeetingError.self) { try meeting.selectGroupPhotoBatch(participantIDs: ["p99"], sessionID: session) }

        // A returning feed cannot revive a failed snapshot with potentially stale frames.
        driver.onEvent?(session, .participants(snapshot))
        #expect(throws: MeetingError.self) { try meeting.selectGroupPhotoBatch(participantIDs: ["p99"], sessionID: session) }
        meeting.endGroupPhoto(sessionID: session)
        #expect(driver.subscriptions.last == meeting.visibleParticipants.map(\.id))
        #expect(throws: Never.self) { try meeting.beginGroupPhoto(sessionID: session) }
    }

    @Test func localCameraEventInvalidatesPhotoBeforeTheRosterArrives() async throws {
        let (meeting, driver, session) = try await fixture(10)
        try meeting.beginGroupPhoto(sessionID: session)
        try meeting.selectGroupPhotoBatch(participantIDs: ["p0"], sessionID: session)
        driver.onEvent?(session, .cameraEnabled(false))
        #expect(driver.subscriptions.last == [])
        #expect(throws: MeetingError.self) { try meeting.validateGroupPhotoBatch(sessionID: session) }
    }

    @Test func interruptionReleasesThePhotoAndRestoresTheGalleryWhenReconnected() async throws {
        let (meeting, driver, session) = try await fixture(60)
        meeting.setPageSize(25)
        meeting.setPage(1)
        let originalIDs = meeting.visibleParticipants.map(\.id)
        try meeting.beginGroupPhoto(sessionID: session)
        try meeting.selectGroupPhotoBatch(participantIDs: ["p0"], sessionID: session)
        driver.onEvent?(session, .status(.reconnecting))
        #expect(!meeting.isTakingGroupPhoto)
        #expect(meeting.photoBatchParticipants.isEmpty)
        #expect(driver.subscriptions.last == [])
        #expect(throws: MeetingError.noMeeting) { try meeting.validateGroupPhotoBatch(sessionID: session) }
        driver.onEvent?(session, .status(.inMeeting))
        #expect(driver.subscriptions.last == originalIDs)
    }

    @Test func rejectsInvalidBatchesAndRepeatedBeginWithoutLosingTheActiveBatch() async throws {
        let (meeting, driver, session) = try await fixture(100)
        try meeting.beginGroupPhoto(sessionID: session)
        try meeting.selectGroupPhotoBatch(participantIDs: ["p0", "p1"], sessionID: session)
        let subscriptionCount = driver.subscriptions.count
        #expect(throws: MeetingError.operationInProgress) { try meeting.beginGroupPhoto(sessionID: session) }
        for invalid in [[], ["p0", "p0"], ["missing"], (0..<50).map { "p\($0)" }] {
            #expect(throws: MeetingError.self) { try meeting.selectGroupPhotoBatch(participantIDs: invalid, sessionID: session) }
        }
        #expect(meeting.photoBatchParticipants.map(\.id) == ["p0", "p1"])
        #expect(driver.subscriptions.count == subscriptionCount)
    }

    @Test func oldSessionCannotSelectClearOrEndTheNewSessionsPhoto() async throws {
        let (meeting, driver, oldSession) = try await fixture(60)
        try meeting.beginGroupPhoto(sessionID: oldSession)
        try meeting.selectGroupPhotoBatch(participantIDs: ["p0"], sessionID: oldSession)
        await meeting.leave()
        #expect(!meeting.isTakingGroupPhoto)
        #expect(meeting.photoBatchParticipants.isEmpty)
        #expect(driver.subscriptions.last == [])

        await meeting.host(displayName: "Me")
        let session = try #require(meeting.sessionID)
        driver.onEvent?(session, .participants(people(10)))
        try meeting.beginGroupPhoto(sessionID: session)
        try meeting.selectGroupPhotoBatch(participantIDs: ["p1"], sessionID: session)
        let subscriptionCount = driver.subscriptions.count
        #expect(throws: MeetingError.noMeeting) { try meeting.selectGroupPhotoBatch(participantIDs: ["p0"], sessionID: oldSession) }
        #expect(throws: MeetingError.noMeeting) { try meeting.validateGroupPhotoBatch(sessionID: oldSession) }
        meeting.clearGroupPhotoBatch(sessionID: oldSession)
        meeting.endGroupPhoto(sessionID: oldSession)
        #expect(meeting.isTakingGroupPhoto)
        #expect(meeting.photoBatchParticipants.map(\.id) == ["p1"])
        #expect(driver.subscriptions.count == subscriptionCount)
    }

    @Test func cancellationStillAllowsCleanupAndRestoringNormalSubscriptions() async throws {
        let (meeting, driver, session) = try await fixture(60)
        meeting.setPageSize(25)
        let originalIDs = meeting.visibleParticipants.map(\.id)
        try meeting.beginGroupPhoto(sessionID: session)
        try meeting.selectGroupPhotoBatch(participantIDs: ["p0"], sessionID: session)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try meeting.validateGroupPhotoBatch(sessionID: session) }
            #expect(throws: CancellationError.self) { try meeting.selectGroupPhotoBatch(participantIDs: ["p1"], sessionID: session) }
            meeting.clearGroupPhotoBatch(sessionID: session)
            meeting.endGroupPhoto(sessionID: session)
        }
        await task.value
        #expect(!meeting.isTakingGroupPhoto)
        #expect(driver.subscriptions.last == originalIDs)
    }

    @Test func readinessOnlyConsultsTheDriverForAnActiveSubscribedCamera() async throws {
        let (meeting, driver, session) = try await fixture(60)
        try meeting.beginGroupPhoto(sessionID: session)
        try meeting.selectGroupPhotoBatch(participantIDs: ["p0", "p1"], sessionID: session)
        driver.readyIDs = ["p0", "p59"]
        #expect(meeting.isVideoReadyForCapture(for: "p0"))
        #expect(!meeting.isVideoReadyForCapture(for: "p1"))
        #expect(!meeting.isVideoReadyForCapture(for: "p59"))
        #expect(driver.readinessQueries == ["p0", "p1"])
        meeting.clearGroupPhotoBatch(sessionID: session)
        #expect(!meeting.isVideoReadyForCapture(for: "p0"))
        #expect(driver.readinessQueries == ["p0", "p1"])
    }
}

@MainActor private final class PhotoBatchDriver: MeetingDriver {
    let isDemo = false
    let capabilities = MeetingCapabilities(canJoin: true, canHost: true, canChat: false, canShare: false,
                                          supportsNativeVideo: true, canReceiveShare: true)
    var onEvent: (@MainActor (UUID, MeetingDriverEvent) -> Void)?
    var subscriptions: [[String]] = []
    var readyIDs: Set<String> = []
    var readinessQueries: [String] = []

    func connect(_ request: MeetingRequest, sessionID: UUID) async throws { onEvent?(sessionID, .status(.inMeeting)) }
    func leave(sessionID: UUID, endForEveryone: Bool) async throws { onEvent?(sessionID, .status(.idle)) }
    func setVisibleParticipants(_ participantIDs: [String]) { subscriptions.append(participantIDs) }
    func isVideoReadyForCapture(for participantID: String) -> Bool {
        readinessQueries.append(participantID)
        return readyIDs.contains(participantID)
    }
    func setMicrophoneMuted(_ muted: Bool, sessionID: UUID) async throws {}
    func setCameraEnabled(_ enabled: Bool, sessionID: UUID) async throws {}
    func sendChat(text: String, sessionID: UUID) async throws {}
    func startShare(_ target: ShareTarget, sessionID: UUID) async throws {}
    func stopShare(sessionID: UUID) async throws {}
}
