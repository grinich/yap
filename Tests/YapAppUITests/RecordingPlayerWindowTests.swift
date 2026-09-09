import AppKit
import AVFoundation
import Foundation
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Recording player windows", .serialized) @MainActor
struct RecordingPlayerWindowTests {
    @Test func openingTheSameMeetingReusesItsWindowWithoutRestartingItsView() throws {
        let fixture = RecordingPlayerWindowFixture()
        defer { fixture.cleanUp() }
        fixture.model.openPlayerWindow(for: fixture.first)
        let controller = try #require(fixture.model.playerWindows[fixture.first.id])
        let window = try #require(controller.window)
        #expect(window.isVisible)
        #expect(window.contentView?.superview?.subviews.contains { $0 is YapWindowPinButton } == false)
        #expect(controller.playback !== fixture.model)
        #expect(controller.playback.player !== fixture.model.player)
        #expect(controller.playback.selectedMeeting?.id == fixture.first.id)

        controller.playback.play(fixture.first.files[1])
        #expect(controller.playback.selectedFile?.id == fixture.first.files[1].id)
        fixture.model.openPlayerWindow(for: fixture.first)

        #expect(fixture.model.playerWindows.count == 1)
        #expect(fixture.model.playerWindows[fixture.first.id] === controller)
        #expect(fixture.model.playerWindows[fixture.first.id]?.window === window)
        #expect(controller.playback.selectedFile?.id == fixture.first.files[1].id)
        #expect(window.isVisible)
        #expect(fixture.createdMediaSources == 0)
    }

    @Test func differentMeetingsOwnIndependentWindowsAndPlayers() throws {
        let fixture = RecordingPlayerWindowFixture()
        defer { fixture.cleanUp() }
        fixture.model.openPlayerWindow(for: fixture.first)
        fixture.model.openPlayerWindow(for: fixture.second)
        let first = try #require(fixture.model.playerWindows[fixture.first.id])
        let second = try #require(fixture.model.playerWindows[fixture.second.id])

        #expect(fixture.model.playerWindows.count == 2)
        #expect(first !== second)
        #expect(first.window !== second.window)
        #expect(first.playback.player !== second.playback.player)
        #expect(first.playback.selectedMeeting?.id == fixture.first.id)
        #expect(second.playback.selectedMeeting?.id == fixture.second.id)
        let secondFile = second.playback.selectedFile

        first.playback.play(fixture.first.files[1])
        #expect(first.playback.selectedFile?.id == fixture.first.files[1].id)
        #expect(second.playback.selectedFile == secondFile)
        #expect(fixture.createdMediaSources == 0)
    }

    @Test func listActionAfterADoubleClickCannotRestartTheMainPlayer() throws {
        let fixture = RecordingPlayerWindowFixture()
        defer { fixture.cleanUp() }
        fixture.model.selectFromList(fixture.first)
        #expect(fixture.model.selectedFile?.id == fixture.first.files[0].id)
        fixture.model.openPlayerWindow(for: fixture.first)
        let child = try #require(fixture.model.playerWindows[fixture.first.id])
        #expect(fixture.model.selectedMeeting?.id == fixture.first.id)
        #expect(fixture.model.selectedFile == nil)

        // SwiftUI's Button action can follow the simultaneous double-click gesture.
        fixture.model.selectFromList(fixture.first)
        #expect(fixture.model.selectedFile == nil)
        #expect(fixture.model.player.currentItem == nil)
        #expect(fixture.model.player.rate == 0)
        #expect(child.playback.selectedFile?.id == fixture.first.files[0].id)

        fixture.model.selectFromList(fixture.second)
        #expect(fixture.model.selectedMeeting?.id == fixture.second.id)
        #expect(fixture.model.selectedFile?.id == fixture.second.files[0].id)
        #expect(child.playback.selectedMeeting?.id == fixture.first.id)
    }

    @Test func selectingAnAlreadyOpenMeetingFocusesItsWindowBeforeTheDoubleClick() throws {
        let fixture = RecordingPlayerWindowFixture()
        defer { fixture.cleanUp() }
        fixture.model.openPlayerWindow(for: fixture.first)
        let existing = try #require(fixture.model.playerWindows[fixture.first.id])
        existing.playback.play(fixture.first.files[1])
        let childFile = existing.playback.selectedFile

        fixture.model.selectFromList(fixture.second)
        #expect(fixture.model.selectedFile?.id == fixture.second.files[0].id)
        fixture.model.selectFromList(fixture.first)
        // The first click of a double-click must not start a second copy inline.
        #expect(fixture.model.selectedMeeting?.id == fixture.first.id)
        #expect(fixture.model.selectedFile == nil)
        #expect(fixture.model.player.currentItem == nil)
        #expect(existing.playback.selectedFile == childFile)

        fixture.model.openPlayerWindow(for: fixture.first)
        #expect(fixture.model.playerWindows.count == 1)
        #expect(fixture.model.playerWindows[fixture.first.id] === existing)
        #expect(fixture.model.selectedFile == nil)
        #expect(fixture.model.player.currentItem == nil)
        #expect(existing.playback.selectedFile == childFile)
        #expect(existing.window?.isVisible == true)
        #expect(fixture.createdMediaSources == 0)
    }

    @Test func refreshingTheLibraryPreservesDedicatedPlayersAndTheirSelectedViews() async throws {
        let video = try #require(Data(base64Encoded: recordingPlaybackMP4Fixture))
        let videoURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording-window-\(UUID().uuidString).mp4")
        try video.write(to: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let fixture = RecordingPlayerWindowFixture(isPreview: false, playbackAsset: AVURLAsset(url: videoURL))
        defer { fixture.cleanUp() }
        let now = Date(timeIntervalSince1970: 1_788_739_200)
        await fixture.setMeetings([fixture.first, fixture.second])
        await fixture.model.loadInitial(now: now)
        fixture.model.openPlayerWindow(for: fixture.first)
        fixture.model.openPlayerWindow(for: fixture.second)
        let first = try #require(fixture.model.playerWindows[fixture.first.id])
        let second = try #require(fixture.model.playerWindows[fixture.second.id])
        first.playback.play(fixture.first.files[1])
        // Use real local video: an empty composition never finishes player readiness.
        // Snapshot the items installed by the model once both players have settled.
        for _ in 0..<500 {
            if !first.playback.isPreparing && !second.playback.isPreparing,
               first.playback.player.currentItem?.status == .readyToPlay,
               second.playback.player.currentItem?.status == .readyToPlay { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!first.playback.isPreparing && !second.playback.isPreparing)
        try #require(first.playback.player.currentItem?.status == .readyToPlay)
        try #require(second.playback.player.currentItem?.status == .readyToPlay)
        first.playback.player.pause()
        second.playback.player.pause()
        let selectedFile = first.playback.selectedFile
        let secondFile = second.playback.selectedFile
        let selectedMeeting = fixture.model.selectedMeeting
        let firstPlayer = first.playback.player
        let secondPlayer = second.playback.player
        let firstWindow = first.window
        let secondWindow = second.window
        let firstItem = try #require(firstPlayer.currentItem)
        let secondItem = try #require(secondPlayer.currentItem)
        let sourceCount = fixture.createdMediaSources
        fixture.model.search = "window search"
        let updated = ZoomRecordingMeeting(id: fixture.first.id, topic: "Changed meeting title",
                                          startTime: fixture.first.startTime, duration: fixture.first.duration + 10,
                                          files: [fixture.first.files[0]])
        await fixture.setMeetings([updated])

        await fixture.model.refresh(now: now)

        #expect(await fixture.fetchedPages == 6)
        #expect(fixture.model.hasLoadedInitial)
        #expect(fixture.model.meetings.first(where: { $0.id == fixture.first.id }) == updated)
        #expect(fixture.model.meetings.contains(fixture.second))
        #expect(fixture.model.selectedMeeting == selectedMeeting)
        #expect(fixture.model.selectedFile == nil)
        #expect(fixture.model.search == "window search")
        #expect(fixture.model.error == nil)
        #expect(fixture.model.playerWindows.count == 2)
        #expect(fixture.model.playerWindows[fixture.first.id] === first)
        #expect(fixture.model.playerWindows[fixture.second.id] === second)
        #expect(first.window === firstWindow)
        #expect(second.window === secondWindow)
        #expect(first.window?.isVisible == true)
        #expect(second.window?.isVisible == true)
        #expect(first.playback.player === firstPlayer)
        #expect(second.playback.player === secondPlayer)
        #expect(firstPlayer.currentItem === firstItem)
        #expect(secondPlayer.currentItem === secondItem)
        #expect(firstItem.status == .readyToPlay)
        #expect(secondItem.status == .readyToPlay)
        #expect(firstPlayer.rate == 0)
        #expect(secondPlayer.rate == 0)
        #expect(!first.playback.isPreparing && !second.playback.isPreparing)
        #expect(first.playback.playbackError == nil)
        #expect(second.playback.playbackError == nil)
        #expect(first.playback.selectedFile == selectedFile)
        #expect(second.playback.selectedFile == secondFile)
        #expect(first.playback.selectedMeeting == fixture.first)
        #expect(second.playback.selectedMeeting == fixture.second)
        #expect(fixture.createdMediaSources == sourceCount)
    }

    @Test(arguments: [false, true])
    func stoppingOrDismissingMainPlaybackLeavesDedicatedWindowsOpen(dismiss: Bool) throws {
        let fixture = RecordingPlayerWindowFixture()
        defer { fixture.cleanUp() }
        fixture.model.isPresented = true
        fixture.model.openPlayerWindow(for: fixture.first)
        fixture.model.openPlayerWindow(for: fixture.second)
        let first = try #require(fixture.model.playerWindows[fixture.first.id])
        let second = try #require(fixture.model.playerWindows[fixture.second.id])
        let firstFile = first.playback.selectedFile
        let secondFile = second.playback.selectedFile

        if dismiss { fixture.model.dismiss() }
        else { fixture.model.stopPlayback() }

        #expect(fixture.model.playerWindows.count == 2)
        #expect(first.window?.isVisible == true)
        #expect(second.window?.isVisible == true)
        #expect(first.playback.selectedFile == firstFile)
        #expect(second.playback.selectedFile == secondFile)
        #expect(fixture.model.player.currentItem == nil)
        if dismiss { #expect(!fixture.model.isPresented) }
    }

    @Test func nativeWindowCloseStopsItsChildRemovesItsEntryAndAllowsReopening() throws {
        let fixture = RecordingPlayerWindowFixture()
        defer { fixture.cleanUp() }
        fixture.model.openPlayerWindow(for: fixture.first)
        fixture.model.openPlayerWindow(for: fixture.second)
        let closing = try #require(fixture.model.playerWindows[fixture.first.id])
        let remaining = try #require(fixture.model.playerWindows[fixture.second.id])
        let window = try #require(closing.window)
        window.close()

        #expect(!window.isVisible)
        #expect(fixture.model.playerWindows[fixture.first.id] == nil)
        #expect(fixture.model.playerWindows.count == 1)
        #expect(closing.playback.selectedFile == nil)
        #expect(closing.playback.player.currentItem == nil)
        #expect(closing.playback.player.rate == 0)
        #expect(remaining.window?.isVisible == true)
        #expect(remaining.playback.selectedFile != nil)

        fixture.model.openPlayerWindow(for: fixture.first)
        let reopened = try #require(fixture.model.playerWindows[fixture.first.id])
        #expect(reopened !== closing)
        #expect(reopened.window !== window)
        #expect(reopened.window?.isVisible == true)
        #expect(reopened.playback.selectedFile?.id == fixture.first.files[0].id)
    }

    @Test func accountClearClosesEveryPlayerAndDiscardsTheirSelection() throws {
        let fixture = RecordingPlayerWindowFixture()
        defer { fixture.cleanUp() }
        fixture.model.openPlayerWindow(for: fixture.first)
        fixture.model.openPlayerWindow(for: fixture.second)
        let controllers = Array(fixture.model.playerWindows.values)
        #expect(controllers.count == 2)

        fixture.model.clear()

        #expect(fixture.model.playerWindows.isEmpty)
        #expect(fixture.model.selectedMeeting == nil)
        #expect(fixture.model.selectedFile == nil)
        #expect(fixture.model.meetings.isEmpty)
        for controller in controllers {
            #expect(controller.window?.isVisible == false)
            #expect(controller.playback.selectedFile == nil)
            #expect(controller.playback.player.currentItem == nil)
            #expect(controller.playback.player.rate == 0)
        }
        #expect(fixture.createdMediaSources == 0)
    }
}

@MainActor private final class RecordingPlayerWindowFixture {
    let model: RecordingLibraryModel
    let first: ZoomRecordingMeeting
    let second: ZoomRecordingMeeting
    private let sourceCount: RecordingWindowSourceCounter
    private let pageCount: RecordingWindowPageCounter
    var createdMediaSources: Int { sourceCount.value }
    var fetchedPages: Int { get async { await pageCount.value } }

    init(isPreview: Bool = true, playbackAsset: AVAsset? = nil) {
        _ = NSApplication.shared
        let count = RecordingWindowSourceCounter()
        sourceCount = count
        let pages = RecordingWindowPageCounter()
        pageCount = pages
        let client = ZoomAccountClient(store: RecordingWindowUnusedStore(), transport: ZoomHTTPTransport { _ in
            throw URLError(.unsupportedURL)
        })
        model = RecordingLibraryModel(client: client, fetchPage: { _, _, _ in await pages.fetch() },
                                      makePlaybackSource: { _ in
            count.value += 1
            return RecordingPlaybackSource(item: AVPlayerItem(asset: playbackAsset ?? AVMutableComposition()))
        })
        // Seed deterministic meetings, and keep most window tests in preview.
        // Source construction is counted; live HTTP and Keychain are never reachable.
        model.enterPreview(now: Date(timeIntervalSince1970: 1_788_739_200))
        let sample = model.meetings[0]
        let alternate = ZoomRecordingFile(id: "window-fixture-alternate", recordingType: "gallery_view",
            fileType: "MP4", fileSize: 0, downloadURL: URL(string: "https://zoom.us/preview-alternate"),
            playURL: nil, status: "completed")
        first = ZoomRecordingMeeting(id: sample.id, topic: sample.topic, startTime: sample.startTime,
                                     duration: sample.duration, files: sample.files + [alternate])
        second = model.meetings[1]
        if !isPreview { model.clear() }
    }

    func setMeetings(_ meetings: [ZoomRecordingMeeting]) async { await pageCount.setMeetings(meetings) }

    func cleanUp() { model.clear() }
}

@MainActor private final class RecordingWindowSourceCounter {
    var value = 0
}

private actor RecordingWindowPageCounter {
    private(set) var value = 0
    private var meetings: [ZoomRecordingMeeting] = []
    func setMeetings(_ meetings: [ZoomRecordingMeeting]) { self.meetings = meetings }
    func fetch() -> ZoomRecordingPage {
        value += 1
        return .init(meetings: meetings)
    }
}

private actor RecordingWindowUnusedStore: ZoomCredentialStore {
    func loadConfiguration() -> ZoomPersonalConfiguration? { nil }
    func saveConfiguration(_ value: ZoomPersonalConfiguration) {}
    func loadTokens() -> ZoomOAuthTokens? { nil }
    func saveTokens(_ value: ZoomOAuthTokens) {}
    func deleteTokens() {}
    func deleteAll() {}
}
