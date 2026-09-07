import AVFoundation
import AVKit
import Foundation
import SwiftUI
import Testing
import YapMeetings
@testable import YapAppUI

@Suite("Recording playback switching", .serialized) @MainActor
struct RecordingPlaybackTests {
    @Test func transcriptTabsSearchAndViewSwitchesPreserveThePlayerAndTransferToItsWindow() async throws {
        let fixture = try await RecordingPlaybackFixture.make(duration: 60)
        defer { fixture.cleanUp() }
        let fetched = RecordingPlaybackTranscriptFetch()
        let model = fixture.makeModel(fetchTranscript: { _ in await fetched.load() })
        defer { model.clear() }
        let original = fixture.meeting()
        let file = ZoomRecordingFile(id: "speech", recordingType: "audio_transcript", fileType: "TRANSCRIPT", fileSize: 0,
                                    downloadURL: URL(string: "https://zoom.us/fixture/transcript"), playURL: nil, status: "completed")
        let meeting = ZoomRecordingMeeting(id: original.id, topic: original.topic, startTime: original.startTime,
                                          duration: original.duration, files: original.files + [file])
        model.select(meeting)
        try #require(await waitUntil { !model.isPreparing && model.transcript.hasLoaded })
        model.player.pause()
        #expect(model.detailTab == .transcript)
        #expect(model.chat.isPresented)
        let item = try #require(model.player.currentItem)
        let cue = try #require(model.transcript.cues.last)
        model.setPlaybackSpeed(1.75)
        model.transcript.query = "decision"
        model.seekToTranscriptCue(cue, followingPlayback: false)
        try #require(await waitUntil { abs(model.player.currentTime().seconds - 45) < 0.025 })

        for tab in [RecordingLibraryModel.DetailTab.chat, .transcript, .chat, .transcript] { model.setDetailTab(tab) }
        #expect(model.player.currentItem === item)
        #expect(abs(model.player.currentTime().seconds - 45) < 0.025)
        #expect(model.player.rate == 0)
        #expect(model.player.defaultRate == 1.75)
        #expect(model.transcript.query == "decision")
        #expect(!model.transcript.followsPlayback)
        #expect(await fetched.count == 1)
        model.play(meeting.playableVideoFiles[1])
        try #require(await waitUntil { !model.isPreparing })
        #expect(abs(model.player.currentTime().seconds - 45) < 0.025)
        #expect(model.transcript.activeCueIDs == [cue.id])
        #expect(await fetched.count == 1)

        model.setDetailPresented(false)
        model.openPlayerWindow(for: meeting)
        let child = try #require(model.playerWindows[meeting.id]?.playback)
        try #require(await waitUntil { !child.isPreparing })
        #expect(child.detailTab == .transcript)
        #expect(child.transcript.query == "decision")
        #expect(!child.transcript.followsPlayback)
        #expect(!child.chat.isPresented)
        #expect(abs(child.player.currentTime().seconds - 45) < 0.025)
        #expect(child.player.rate == 0)
        #expect(child.player.defaultRate == 1.75)
        #expect(child.transcript.cues.last == cue)
        #expect(model.transcript.cues.isEmpty)
        #expect(await fetched.count == 1)
    }

    @Test(arguments: [true, false])
    func refreshingChangedRecordingsPreservesPlaybackAndItsCachedViews(_ paused: Bool) async throws {
        let fixture = try await RecordingPlaybackFixture.make(duration: 60)
        defer { fixture.cleanUp() }
        let now = Date(timeIntervalSince1970: 1_788_739_200)
        let original = fixture.meeting()
        let chatFile = ZoomRecordingFile(id: "refresh-chat", recordingType: "chat_file", fileType: "CHAT", fileSize: 0,
                                        downloadURL: URL(string: "https://zoom.us/fixture/chat"), playURL: nil, status: "completed")
        let meeting = ZoomRecordingMeeting(id: original.id, topic: original.topic, startTime: now.addingTimeInterval(-3_600),
                                          duration: original.duration, files: original.files + [chatFile])
        let pages = RecordingPlaybackRefreshPages(meetings: [meeting])
        let model = fixture.makeModel(fetchChat: { _ in "00:00:00\tAda: Opening\n00:00:50\tSam: Later" },
                                      fetchPage: { _, _, _ in await pages.fetch() })
        defer { model.clear() }
        await model.loadInitial(now: now)
        model.select(meeting)
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay && model.chat.hasLoaded })
        model.player.pause()
        let firstItem = try #require(model.player.currentItem)
        model.play(meeting.files[1])
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        let selectedItem = try #require(model.player.currentItem)
        #expect(await model.player.seek(to: time(20), toleranceBefore: .zero, toleranceAfter: .zero))
        model.setPlaybackSpeed(1.5)
        model.chat.setPresented(true)
        model.chat.followsPlayback = false
        model.search = "Synthetic"
        if !paused { model.player.playImmediately(atRate: 1.5) }
        let selectedFile = model.selectedFile
        let messages = model.chat.messages
        let sourceIDs = fixture.createdIDs
        let before = model.player.currentTime().seconds
        let started = ContinuousClock.now
        let updated = ZoomRecordingMeeting(id: meeting.id, topic: "Updated title", startTime: meeting.startTime,
                                          duration: 2, files: [fixture.file("new-view")])
        await pages.replace(with: [updated])

        await model.refresh(now: now)

        #expect(model.meetings == [updated])
        #expect(model.selectedMeeting == meeting)
        #expect(model.selectedFile == selectedFile)
        #expect(model.player.currentItem === selectedItem)
        #expect(model.player.rate == (paused ? 0 : 1.5))
        #expect(model.player.defaultRate == 1.5)
        #expect(model.playbackSpeed == 1.5)
        let after = model.player.currentTime().seconds
        let elapsed = started.duration(to: .now)
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #expect(after >= before - 0.025)
        #expect(after <= before + (paused ? 0.025 : elapsedSeconds * 1.5 + 0.1))
        #expect(model.chat.messages == messages)
        #expect(model.chat.isPresented)
        #expect(model.chat.hasLoaded)
        #expect(!model.chat.followsPlayback)
        #expect(model.search == "Synthetic")
        #expect(!model.isPreparing)
        #expect(!model.isRefreshing)
        #expect(model.playbackError == nil)
        #expect(fixture.createdIDs == sourceIDs)

        model.player.pause()
        let pausedPosition = model.player.currentTime().seconds
        model.play(meeting.files[0])
        try #require(await waitUntil { !model.isPreparing && model.selectedFile?.id == meeting.files[0].id })
        #expect(model.player.currentItem === firstItem)
        #expect(fixture.createdIDs == sourceIDs)
        #expect(abs(model.player.currentTime().seconds - pausedPosition) < 0.025)
    }

    @Test(arguments: [Float(1.75), 2.25, 2.5, 2.75])
    func changingSpeedWhilePausedKeepsThePositionAndResumesAtThatSpeed(_ speed: Float) async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.stopPlayback() }
        model.select(fixture.meeting())
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        #expect(await model.player.seek(to: time(0.4), toleranceBefore: .zero, toleranceAfter: .zero))

        model.setPlaybackSpeed(speed)

        #expect(model.playbackSpeed == speed)
        #expect(model.player.defaultRate == speed)
        #expect(model.player.rate == 0)
        #expect(abs(model.player.currentTime().seconds - 0.4) < 0.025)
        model.player.play()
        #expect(model.player.rate == speed)
    }

    @Test func changingSpeedDuringPlaybackTakesEffectWithoutSeeking() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.stopPlayback() }
        model.select(fixture.meeting())
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        #expect(await model.player.seek(to: time(0.4), toleranceBefore: .zero, toleranceAfter: .zero))

        model.setPlaybackSpeed(1.5)

        #expect(model.player.rate == 1.5)
        #expect(model.player.defaultRate == 1.5)
        #expect(model.playbackSpeed == 1.5)
        #expect(model.player.currentTime().seconds >= 0.39)
        #expect(model.player.currentTime().seconds < 0.65)
        model.setPlaybackSpeed(.nan)
        model.setPlaybackSpeed(0)
        #expect(model.playbackSpeed == 1.5)
        #expect(model.player.rate == 1.5)
    }

    @Test(arguments: [true, false])
    func speedChangesDuringRapidViewPreparationPreservePlaybackIntent(_ paused: Bool) async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.stopPlayback() }
        let meeting = fixture.meeting()
        model.select(meeting)
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.setPlaybackSpeed(1.25)
        if paused { model.player.pause() }
        #expect(await model.player.seek(to: time(0.4), toleranceBefore: .zero, toleranceAfter: .zero))

        model.play(meeting.files[1])
        #expect(model.isPreparing)
        model.setPlaybackSpeed(2)
        model.play(meeting.files[2])
        try #require(await waitUntil { !model.isPreparing && model.selectedFile?.id == "view-c" })

        #expect(model.player.rate == (paused ? 0 : 2))
        #expect(model.player.defaultRate == 2)
        #expect(model.playbackSpeed == 2)
        #expect(model.player.currentTime().seconds >= 0.39)
        #expect(model.player.currentTime().seconds < 0.75)
    }

    @Test func nativeSpeedChangesSynchronizeWithoutStaleCallbacksOverwritingANewerPick() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.stopPlayback() }
        model.select(fixture.meeting())
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        model.player.defaultRate = 1.25
        try #require(await waitUntil { model.playbackSpeed == 1.25 })
        #expect(model.player.rate == 0)

        model.player.defaultRate = 0.5
        model.setPlaybackSpeed(2)
        try await Task.sleep(for: .milliseconds(40))

        #expect(model.playbackSpeed == 2)
        #expect(model.player.defaultRate == 2)
        #expect(model.player.rate == 0)
    }

    @Test(arguments: [true, false])
    func aSpeedChosenWhileDownloadingCarriesIntoTheFallback(_ paused: Bool) async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.stopPlayback() }
        model.select(fixture.meeting())
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.setPlaybackSpeed(1.25)
        if paused { model.player.pause() }

        model.downloadSelected()
        #expect(model.isDownloading)
        model.setPlaybackSpeed(2)
        try #require(await waitUntil { !model.isDownloading && !model.isPreparing })

        #expect(model.player.rate == (paused ? 0 : 2))
        #expect(model.player.defaultRate == 2)
        #expect(model.playbackSpeed == 2)
        #expect(model.playbackError == nil)
    }

    @Test func playerSurfaceTracksTheVideoShapeAcrossWindowAndChatResizing() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.clear() }
        model.select(fixture.meeting())
        try #require(await waitUntil { !model.isPreparing && model.videoAspectRatio == 1 })
        model.player.pause()
        let host = NSHostingView(rootView: RecordingPlayerView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        func findPlayer(in view: NSView) -> AVPlayerView? {
            if let player = view as? AVPlayerView { return player }
            return view.subviews.lazy.compactMap { findPlayer(in: $0) }.first
        }
        for size in [NSSize(width: 900, height: 620), NSSize(width: 650, height: 900), NSSize(width: 520, height: 360)] {
            for showsChat in [false, true] {
                window.setContentSize(size)
                model.chat.setPresented(showsChat)
                try #require(await waitUntil {
                    host.layoutSubtreeIfNeeded()
                    guard let view = findPlayer(in: host) else { return false }
                    let frame = view.convert(view.bounds, to: host)
                    return frame.width > 0 && abs(frame.width - frame.height) < 1 &&
                        host.bounds.insetBy(dx: -1, dy: -1).contains(frame)
                })
                let view = try #require(findPlayer(in: host))
                #expect(view.player === model.player)
                #expect(view.videoGravity == .resizeAspect)
            }
        }
    }

    @Test func nativeSeeksSynchronizeChatAndTheChatStateFollowsItsPlayerWindow() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(fetchChat: { _ in "00:00:00.400\tAlex:\tFirst\n00:00:01.200\tSam:\tSecond" })
        defer { model.clear() }
        let original = fixture.meeting()
        let chatFile = ZoomRecordingFile(id: "chat", recordingType: "chat_file", fileType: "CHAT", fileSize: 0,
                                        downloadURL: URL(string: "https://zoom.us/fixture/chat"), playURL: nil, status: "completed")
        let meeting = ZoomRecordingMeeting(id: original.id, topic: original.topic, startTime: original.startTime,
                                          duration: original.duration, files: original.files + [chatFile])
        model.select(meeting)
        model.chat.setPresented(true)
        try #require(await waitUntil { !model.isPreparing && model.chat.hasLoaded })
        model.player.pause()
        #expect(await model.player.seek(to: time(1.3), toleranceBefore: .zero, toleranceAfter: .zero))
        let second = try #require(model.chat.messages.last)
        try #require(await waitUntil { model.chat.activeMessageIDs == [second.id] })

        let first = try #require(model.chat.messages.first)
        model.seekToChatMessage(first)
        try #require(await waitUntil { model.chat.activeMessageIDs == [first.id] })
        #expect(abs(model.player.currentTime().seconds - 0.4) < 0.025)
        #expect(model.player.rate == 0)

        let messages = model.chat.messages
        model.openPlayerWindow(for: meeting)
        let child = try #require(model.playerWindows[meeting.id]?.playback)
        try #require(await waitUntil { !child.isPreparing && child.chat.activeMessageIDs == [first.id] })
        #expect(child.chat.isPresented)
        #expect(child.chat.messages == messages)
        #expect(!model.chat.isPresented)
        #expect(model.chat.activeMessageIDs.isEmpty)
    }

    @Test func clickingTheSelectedRowDoesNotRestartItsPlayer() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.stopPlayback() }
        let meeting = fixture.meeting()
        model.selectFromList(meeting)
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        #expect(await model.player.seek(to: time(1.2), toleranceBefore: .zero, toleranceAfter: .zero))
        let originalItem = try #require(model.player.currentItem)

        model.selectFromList(meeting)
        model.selectFromList(meeting)
        model.prepareForPresentation()
        model.prepareForPresentation()

        #expect(model.player.currentItem === originalItem)
        #expect(abs(model.player.currentTime().seconds - 1.2) < 0.025)
        #expect(model.player.rate == 0)
        #expect(!model.isPreparing)
        #expect(fixture.createdIDs == ["view-a"])
    }

    @Test func switchingViewsKeepsARealPausedSeekPosition() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.stopPlayback() }
        let meeting = fixture.meeting()
        model.select(meeting)
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        #expect(await model.player.seek(to: time(1.2), toleranceBefore: .zero, toleranceAfter: .zero))
        let originalItem = try #require(model.player.currentItem)

        model.play(meeting.files[1])
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem !== originalItem })
        #expect(model.selectedFile?.id == "view-b")
        #expect(abs(model.player.currentTime().seconds - 1.2) < 0.025)
        #expect(model.player.rate == 0)
        #expect(model.playbackError == nil)
    }

    @Test func openingAPlayerWindowCarriesTheCurrentViewTimeAndPauseState() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.clear() }
        let meeting = fixture.meeting()
        model.selectFromList(meeting)
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        model.setPlaybackSpeed(1.5)
        #expect(await model.player.seek(to: time(1.2), toleranceBefore: .zero, toleranceAfter: .zero))
        model.play(meeting.files[1])
        try #require(await waitUntil { !model.isPreparing })

        model.openPlayerWindow(for: meeting)
        let controller = try #require(model.playerWindows[meeting.id])
        let child = controller.playback
        try #require(await waitUntil { !child.isPreparing && child.player.currentItem?.status == .readyToPlay })

        #expect(child.selectedFile?.id == meeting.files[1].id)
        #expect(abs(child.player.currentTime().seconds - 1.2) < 0.025)
        #expect(child.player.rate == 0)
        #expect(child.playbackSpeed == 1.5)
        #expect(child.player.defaultRate == 1.5)
        #expect(model.player.currentItem == nil)
        #expect(model.player.rate == 0)
        let item = child.player.currentItem
        model.selectFromList(meeting)
        model.openPlayerWindow(for: meeting)
        model.prepareForPresentation()
        model.dismiss()
        model.toggle()
        #expect(child.player.currentItem === item)
        #expect(abs(child.player.currentTime().seconds - 1.2) < 0.025)
        #expect(model.player.currentItem == nil)
        #expect(model.selectedFile == nil)
    }

    @Test func aDownloadedFallbackMovesToItsWindowWithoutRestreamingOrDeletingTheFile() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.clear() }
        let meeting = fixture.meeting()
        model.selectFromList(meeting)
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        model.setPlaybackSpeed(1.75)
        model.downloadSelected()
        try #require(await waitUntil { !model.isDownloading && !model.isPreparing })
        let fallbackURL = try #require((model.player.currentItem?.asset as? AVURLAsset)?.url)
        model.player.pause()
        #expect(await model.player.seek(to: time(1.2), toleranceBefore: .zero, toleranceAfter: .zero))
        let fallbackItem = model.player.currentItem
        model.suspendPlayback()
        model.prepareForPresentation()
        #expect(model.player.currentItem === fallbackItem)
        #expect(abs(model.player.currentTime().seconds - 1.2) < 0.025)
        #expect(model.player.rate == 0)
        #expect(FileManager.default.fileExists(atPath: fallbackURL.path))

        model.openPlayerWindow(for: meeting)
        let child = try #require(model.playerWindows[meeting.id]?.playback)
        try #require(await waitUntil { !child.isPreparing && child.player.currentItem?.status == .readyToPlay })
        #expect((child.player.currentItem?.asset as? AVURLAsset)?.url == fallbackURL)
        #expect(FileManager.default.fileExists(atPath: fallbackURL.path))
        #expect(fixture.createdIDs == ["view-a"])
        #expect(abs(child.player.currentTime().seconds - 1.2) < 0.025)
        #expect(child.player.rate == 0)
        #expect(child.playbackSpeed == 1.75)
        #expect(child.player.defaultRate == 1.75)

        model.stopPlayback()
        #expect(FileManager.default.fileExists(atPath: fallbackURL.path))
        model.closePlayerWindows()
        #expect(!FileManager.default.fileExists(atPath: fallbackURL.path))
    }

    @Test func rapidSwitchesCarryTheOriginalPositionThroughPreparingViews() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.stopPlayback() }
        let meeting = fixture.meeting()
        model.select(meeting)
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        #expect(await model.player.seek(to: time(1.1), toleranceBefore: .zero, toleranceAfter: .zero))

        // Both changes run in the same main-actor turn, before B can install or seek.
        model.play(meeting.files[1])
        #expect(model.isPreparing)
        model.play(meeting.files[2])
        try #require(await waitUntil { !model.isPreparing && model.selectedFile?.id == "view-c" })
        #expect(abs(model.player.currentTime().seconds - 1.1) < 0.025)
        #expect(model.player.rate == 0)
        #expect(model.playbackError == nil)
    }

    @Test func aPlayingViewResumesAtItsChosenSpeed() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.stopPlayback() }
        let meeting = fixture.meeting()
        model.select(meeting)
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        #expect(await model.player.seek(to: time(0.4), toleranceBefore: .zero, toleranceAfter: .zero))
        model.player.playImmediately(atRate: 1.5)
        #expect(model.player.rate == 1.5)

        model.play(meeting.files[1])
        try #require(await waitUntil { !model.isPreparing && model.player.rate == 1.5 })
        let resumedTime = model.player.currentTime().seconds
        model.player.pause()
        #expect(resumedTime >= 0.39)
        #expect(resumedTime < 0.75)
        #expect(model.selectedFile?.id == "view-b")
        #expect(model.playbackError == nil)
    }

    @Test func switchingToAShorterViewClampsBeforeItsEnd() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.stopPlayback() }
        let meeting = fixture.meeting()
        model.select(meeting)
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        #expect(await model.player.seek(to: time(1.4), toleranceBefore: .zero, toleranceAfter: .zero))

        model.play(fixture.file("short-view"))
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        let item = try #require(model.player.currentItem)
        let duration = item.duration.seconds
        let position = model.player.currentTime().seconds
        #expect(abs(duration - 0.6) < 0.025)
        #expect(position >= 0)
        #expect(position < duration)
        #expect(abs(position - (duration - 1.0 / 600)) < 0.025)
        #expect(model.player.rate == 0)
        #expect(model.playbackError == nil)
    }

    @Test func recentViewsReuseTheirPlayerItemsAndEvictTheLeastRecentOfThree() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.stopPlayback() }
        let meeting = fixture.meeting()
        model.select(meeting)
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        let firstItem = try #require(model.player.currentItem)

        for id in ["view-b", "view-c", "view-a"] {
            model.play(fixture.file(id))
            try #require(await waitUntil { !model.isPreparing && model.selectedFile?.id == id })
        }
        #expect(model.player.currentItem === firstItem)
        #expect(fixture.createdIDs == ["view-a", "view-b", "view-c"])

        model.play(fixture.file("view-d"))
        try #require(await waitUntil { !model.isPreparing && model.selectedFile?.id == "view-d" })
        model.play(fixture.file("view-b"))
        try #require(await waitUntil { !model.isPreparing && model.selectedFile?.id == "view-b" })
        #expect(fixture.createdIDs == ["view-a", "view-b", "view-c", "view-d", "view-b"])
        #expect(model.player.rate == 0)
        #expect(model.playbackError == nil)
    }

    @Test func selectingAnotherMeetingStartsAtZeroAndDoesNotReuseItsNamesakes() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.stopPlayback() }
        model.select(fixture.meeting(id: "first-meeting"))
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        #expect(await model.player.seek(to: time(1.3), toleranceBefore: .zero, toleranceAfter: .zero))
        let previousItem = try #require(model.player.currentItem)

        model.select(fixture.meeting(id: "other-meeting"))
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem !== previousItem })
        model.player.pause()
        #expect(model.selectedMeeting?.id == "other-meeting")
        #expect(model.player.currentTime().seconds < 0.15)
        #expect(fixture.createdIDs == ["view-a", "view-a"])
        #expect(model.playbackError == nil)
    }

    @Test func dismissDuringASwitchKeepsItsPositionAndReopensWithUsablePausedControls() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.stopPlayback() }
        let meeting = fixture.meeting()
        model.isPresented = true
        model.select(meeting)
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        #expect(await model.player.seek(to: time(1.3), toleranceBefore: .zero, toleranceAfter: .zero))
        model.setPlaybackSpeed(1.75)
        model.player.play()

        model.play(meeting.files[1])
        model.dismiss()
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        #expect(!model.isPresented)
        #expect(model.selectedFile?.id == "view-b")
        #expect(abs(model.player.currentTime().seconds - 1.3) < 0.05)
        #expect(model.player.rate == 0)
        let pausedItem = model.player.currentItem

        model.toggle()
        model.prepareForPresentation()
        #expect(model.isPresented)
        #expect(model.player.currentItem === pausedItem)
        #expect(model.player.currentItem?.status == .readyToPlay)
        #expect(model.playbackSpeed == 1.75)
        #expect(model.player.defaultRate == 1.75)
        #expect(model.player.rate == 0)
        #expect(fixture.createdIDs == ["view-a", "view-b"])
        model.play(meeting.files[0])
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        #expect(abs(model.player.currentTime().seconds - 1.3) < 0.05)
        #expect(fixture.createdIDs == ["view-a", "view-b"])
        #expect(model.player.rate == 0)
        #expect(model.playbackError == nil)
    }

    @Test func disappearingAndReappearingRetainsTheReadyItemAndPausesAudio() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.clear() }
        model.select(fixture.meeting())
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        #expect(await model.player.seek(to: time(0.4), toleranceBefore: .zero, toleranceAfter: .zero))
        model.setPlaybackSpeed(1.5)
        model.player.play()
        let original = model.player.currentItem
        model.suspendPlayback()
        let pausedAt = model.player.currentTime().seconds
        model.prepareForPresentation()
        model.prepareForPresentation()
        #expect(model.player.currentItem === original)
        #expect(model.player.currentItem?.status == .readyToPlay)
        #expect(model.player.rate == 0)
        #expect(abs(model.player.currentTime().seconds - pausedAt) < 0.025)
        #expect(model.playbackSpeed == 1.5)
        #expect(fixture.createdIDs == ["view-a"])
        model.player.play()
        #expect(model.player.rate == 1.5)
    }

    @Test func presentationRepairsATornDownSelectionOnlyOnceAndKeepsItPaused() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.clear() }
        model.select(fixture.meeting())
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.setPlaybackSpeed(2)
        model.stopPlayback()
        #expect(model.selectedMeeting != nil)
        #expect(model.selectedFile == nil)
        model.prepareForPresentation()
        model.prepareForPresentation()
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        #expect(model.selectedFile?.id == "view-a")
        #expect(model.player.rate == 0)
        #expect(model.player.defaultRate == 2)
        #expect(fixture.createdIDs == ["view-a", "view-a"])
    }

    @Test func hidingDuringADownloadInstallsTheFallbackPausedAndRetainsItForReappearance() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.clear() }
        model.select(fixture.meeting())
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        #expect(await model.player.seek(to: time(0.4), toleranceBefore: .zero, toleranceAfter: .zero))
        model.setPlaybackSpeed(1.5)
        model.player.play()
        model.downloadSelected()
        #expect(model.isDownloading)
        model.suspendPlayback()
        try #require(await waitUntil { !model.isDownloading && !model.isPreparing })
        let fallback = try #require(model.player.currentItem)
        let url = try #require((fallback.asset as? AVURLAsset)?.url)
        #expect(fallback.status == .readyToPlay)
        #expect(model.player.rate == 0)
        #expect(abs(model.player.currentTime().seconds - 0.4) < 0.05)
        #expect(FileManager.default.fileExists(atPath: url.path))
        model.prepareForPresentation()
        #expect(model.player.currentItem === fallback)
        #expect(model.player.rate == 0)
        #expect(model.playbackSpeed == 1.5)
        #expect(fixture.createdIDs == ["view-a"])
    }

    @Test func hidingRevokesAnInFlightDownloadsResumeEvenWhenTransportStillReportsPlaying() async throws {
        let fixture = try await RecordingPlaybackFixture.make(duration: 60)
        defer { fixture.cleanUp() }
        let (started, startSignal) = AsyncStream<Void>.makeStream()
        let (released, releaseSignal) = AsyncStream<Void>.makeStream()
        defer { startSignal.finish(); releaseSignal.finish() }
        let model = fixture.makeModel(beforeDownload: {
            startSignal.yield(())
            for await _ in released { break }
        })
        defer { model.clear() }
        model.select(fixture.meeting())
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        #expect(await model.player.seek(to: time(0.4), toleranceBefore: .zero, toleranceAfter: .zero))
        model.setPlaybackSpeed(1.5)
        model.player.play()
        model.downloadSelected()
        for await _ in started { break }
        model.suspendPlayback()
        // Simulate the stale nonzero transport state observed when a pause and
        // download completion race. The model's recorded hide request must win.
        model.player.rate = 1.5
        model.prepareForPresentation()
        try #require(model.player.rate == 1.5)
        releaseSignal.yield(())
        releaseSignal.finish()
        try #require(await waitUntil { !model.isDownloading && !model.isPreparing })
        #expect(model.player.currentItem?.status == .readyToPlay)
        #expect(model.player.rate == 0)
        #expect(abs(model.player.currentTime().seconds - 0.4) < 0.05)
        #expect(model.playbackSpeed == 1.5)
        model.prepareForPresentation()
        #expect(model.player.rate == 0)
    }

    @Test(arguments: [false, true])
    func closingADedicatedPlayerClearsOrphanedSelectionWithoutRevivingEitherPlayer(closeAll: Bool) async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.clear() }
        let meeting = fixture.meeting()
        model.openPlayerWindow(for: meeting)
        let controller = try #require(model.playerWindows[meeting.id])
        let child = controller.playback
        try #require(await waitUntil { !child.isPreparing && child.player.currentItem?.status == .readyToPlay })
        if closeAll { model.closePlayerWindows() } else { controller.close() }
        model.prepareForPresentation()
        child.prepareForPresentation()
        #expect(model.playerWindows.isEmpty)
        #expect(model.selectedMeeting == nil)
        #expect(model.selectedFile == nil)
        #expect(model.player.currentItem == nil)
        #expect(child.selectedMeeting == nil)
        #expect(child.selectedFile == nil)
        #expect(child.player.currentItem == nil)
        #expect(child.player.rate == 0)
        #expect(fixture.createdIDs == ["view-a"])
    }

    @Test func closingAnotherPlayerWindowLeavesCurrentInlinePlaybackAlone() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.clear() }
        let first = fixture.meeting(id: "first")
        model.openPlayerWindow(for: first)
        let controller = try #require(model.playerWindows[first.id])
        try #require(await waitUntil { !controller.playback.isPreparing })
        model.selectFromList(fixture.meeting(id: "second"))
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        let currentItem = model.player.currentItem
        controller.close()
        model.prepareForPresentation()
        #expect(model.selectedMeeting?.id == "second")
        #expect(model.player.currentItem === currentItem)
        #expect(model.player.currentItem?.status == .readyToPlay)
        #expect(model.playerWindows.isEmpty)
        #expect(fixture.createdIDs == ["view-a", "view-a"])
    }

    @Test func clearingWhilePreparingCannotBeReactivatedByPresentationHooks() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.clear() }
        model.select(fixture.meeting())
        model.play(fixture.file("view-b"))
        #expect(model.isPreparing)
        model.clear()
        model.prepareForPresentation()
        model.toggle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.selectedMeeting == nil)
        #expect(model.selectedFile == nil)
        #expect(model.player.currentItem == nil)
        #expect(model.player.rate == 0)
        #expect(!model.isPreparing)
        #expect(model.playerWindows.isEmpty)
        #expect(fixture.createdIDs == ["view-a", "view-b"])
    }

    @Test func speedCyclingUsesAscendingChoicesAndWrapsWithoutResumingAPausedVideo() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.clear() }
        model.select(fixture.meeting())
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        #expect(await model.player.seek(to: time(0.4), toleranceBefore: .zero, toleranceAfter: .zero))
        let item = model.player.currentItem
        for expected in [Float(1.25), 1.5, 1.75, 2, 2.25, 2.5, 2.75, 1] {
            model.cyclePlaybackSpeed()
            #expect(model.playbackSpeed == expected)
            #expect(model.player.defaultRate == expected)
            #expect(model.player.rate == 0)
        }
        model.player.defaultRate = 1.1
        model.cyclePlaybackSpeed()
        #expect(model.playbackSpeed == 1.25)
        #expect(model.player.currentItem === item)
        #expect(abs(model.player.currentTime().seconds - 0.4) < 0.025)
    }

    @Test func viewCyclingWrapsAndReusesTheOriginalItemAfterRapidChanges() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.clear() }
        let original = fixture.meeting()
        let meeting = ZoomRecordingMeeting(id: original.id, topic: original.topic, startTime: original.startTime,
                                          duration: original.duration, files: Array(original.files.prefix(3)))
        model.select(meeting)
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        #expect(await model.player.seek(to: time(1.1), toleranceBefore: .zero, toleranceAfter: .zero))
        model.setPlaybackSpeed(1.5)
        let firstItem = model.player.currentItem
        model.cyclePlaybackView()
        #expect(model.selectedFile?.id == "view-b")
        model.cyclePlaybackView()
        try #require(await waitUntil { !model.isPreparing && model.selectedFile?.id == "view-c" })
        model.cyclePlaybackView()
        try #require(await waitUntil { !model.isPreparing && model.selectedFile?.id == "view-a" })
        #expect(model.player.currentItem === firstItem)
        #expect(abs(model.player.currentTime().seconds - 1.1) < 0.025)
        #expect(model.player.rate == 0)
        #expect(model.playbackSpeed == 1.5)
        #expect(fixture.createdIDs == ["view-a", "view-b", "view-c"])
    }

    @Test func repeatedTenSecondJogsAccumulateClampAndSynchronizeChat() async throws {
        let fixture = try await RecordingPlaybackFixture.make(duration: 60)
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(fetchChat: { _ in "00:00:10\tAda: Early\n00:00:30\tLin: Middle\n00:00:50\tSam: Late" })
        defer { model.clear() }
        let original = fixture.meeting()
        let chatFile = ZoomRecordingFile(id: "chat", recordingType: "chat_file", fileType: "CHAT", fileSize: 0,
            downloadURL: URL(string: "https://zoom.us/fixture/chat"), playURL: nil, status: "completed")
        model.select(.init(id: original.id, topic: original.topic, startTime: original.startTime, duration: 1,
                           files: original.files + [chatFile]))
        try #require(await waitUntil { !model.isPreparing && model.chat.hasLoaded })
        model.player.pause()
        #expect(await model.player.seek(to: time(5), toleranceBefore: .zero, toleranceAfter: .zero))
        let early = try #require(model.chat.messages.first)
        model.jogPlayback(by: 10)
        model.jogPlayback(by: 10)
        model.jogPlayback(by: 10)
        model.jogPlayback(by: -10)
        try #require(await waitUntil { abs(model.player.currentTime().seconds - 25) < 0.025 && model.chat.activeMessageIDs == [early.id] })
        #expect(model.player.rate == 0)
        model.jogPlayback(by: -100)
        try #require(await waitUntil { model.player.currentTime().seconds < 0.025 && model.chat.activeMessageIDs.isEmpty })
        model.jogPlayback(by: 100)
        let end = try #require(model.player.currentItem?.duration.seconds) - 1.0 / 600
        try #require(await waitUntil { abs(model.player.currentTime().seconds - end) < 0.025 })
        #expect(model.player.currentTime().seconds < 60)
        #expect(model.player.rate == 0)
        model.jogPlayback(by: -.infinity)
        model.jogPlayback(by: .nan)
        #expect(abs(model.player.currentTime().seconds - end) < 0.025)
    }

    @Test(arguments: [false, true])
    func jogsPreservePlayingOrPausedStateAndDoNotUndoAHide(hideDuringSeek: Bool) async throws {
        let fixture = try await RecordingPlaybackFixture.make(duration: 60)
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.clear() }
        model.select(fixture.meeting())
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        #expect(await model.player.seek(to: time(5), toleranceBefore: .zero, toleranceAfter: .zero))
        model.setPlaybackSpeed(1.5)
        model.player.play()
        model.jogPlayback(by: 10)
        model.jogPlayback(by: 10)
        if hideDuringSeek { model.suspendPlayback() }
        try #require(await waitUntil { model.player.currentTime().seconds >= 24.99 })
        #expect(model.player.currentTime().seconds < 26)
        #expect(model.player.rate == (hideDuringSeek ? 0 : 1.5))
        #expect(model.playbackSpeed == 1.5)
    }

    @Test func pendingJogsCarryIntoAnotherViewAndClearCancelsQueuedSeeks() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.clear() }
        model.select(fixture.meeting())
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        model.player.pause()
        #expect(await model.player.seek(to: time(0.2), toleranceBefore: .zero, toleranceAfter: .zero))
        model.jogPlayback(by: 0.7)
        model.jogPlayback(by: 0.3)
        model.cyclePlaybackView()
        try #require(await waitUntil { !model.isPreparing && model.selectedFile?.id == "view-b" })
        #expect(abs(model.player.currentTime().seconds - 1.2) < 0.025)
        #expect(model.player.rate == 0)
        model.jogPlayback(by: -0.5)
        model.clear()
        await Task.yield()
        #expect(model.player.currentItem == nil)
        #expect(model.selectedMeeting == nil)
        #expect(model.chat.activeMessageIDs.isEmpty)
    }

    @Test func shortcutsIgnorePreviewAndMissingVideoButAllowSpeedAndViewDuringPreparation() async throws {
        let fixture = try await RecordingPlaybackFixture.make()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        defer { model.clear() }
        model.cyclePlaybackSpeed()
        model.cyclePlaybackView()
        model.jogPlayback(by: 10)
        #expect(model.playbackSpeed == 1)
        #expect(fixture.createdIDs.isEmpty)
        model.enterPreview()
        model.select(try #require(model.meetings.first))
        let previewFile = model.selectedFile
        model.cyclePlaybackSpeed()
        model.cyclePlaybackView()
        model.jogPlayback(by: 10)
        #expect(model.playbackSpeed == 1)
        #expect(model.selectedFile == previewFile)
        #expect(fixture.createdIDs.isEmpty)
        model.clear()
        model.select(fixture.meeting())
        #expect(model.isPreparing)
        model.jogPlayback(by: 10)
        model.cyclePlaybackSpeed()
        model.cyclePlaybackView()
        model.suspendPlayback()
        try #require(await waitUntil { !model.isPreparing && model.player.currentItem?.status == .readyToPlay })
        #expect(model.playbackSpeed == 1.25)
        #expect(model.selectedFile?.id == "view-b")
        #expect(model.player.currentTime().seconds < 0.025)
        #expect(model.player.rate == 0)
    }

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor private final class RecordingPlaybackFixture {
    private let url: URL
    private let fullAsset: AVAsset
    private let shortAsset: AVMutableComposition
    private(set) var createdIDs: [String] = []

    private init(url: URL, fullAsset: AVAsset, shortAsset: AVMutableComposition) {
        self.url = url
        self.fullAsset = fullAsset
        self.shortAsset = shortAsset
    }

    static func make(duration: Int = 2) async throws -> RecordingPlaybackFixture {
        let video = try #require(Data(base64Encoded: recordingPlaybackMP4Fixture))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-playback-fixture-\(UUID().uuidString).mp4")
        try video.write(to: url)
        do {
            let asset = AVURLAsset(url: url)
            let sourceTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let shortAsset = AVMutableComposition()
            let shortTrack = try #require(shortAsset.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
            try shortTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 0.6, preferredTimescale: 600)),
                                           of: sourceTrack, at: .zero)
            var fullAsset: AVAsset = asset
            if duration > 2 {
                let repeated = AVMutableComposition()
                let track = try #require(repeated.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
                for seconds in stride(from: 0, to: duration, by: 2) {
                    try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)),
                                              of: sourceTrack, at: CMTime(seconds: Double(seconds), preferredTimescale: 600))
                }
                fullAsset = repeated
            }
            return RecordingPlaybackFixture(url: url, fullAsset: fullAsset, shortAsset: shortAsset)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func makeModel(fetchChat: (@Sendable (ZoomRecordingFile) async throws -> String)? = nil,
                   fetchTranscript: (@Sendable (ZoomRecordingFile) async throws -> String)? = nil,
                   beforeDownload: (@Sendable () async -> Void)? = nil,
                   fetchPage: (@Sendable (Date, Date, String) async throws -> ZoomRecordingPage)? = nil) -> RecordingLibraryModel {
        // Every source is local synthetic media. Neither live HTTP nor Keychain is reachable.
        let client = ZoomAccountClient(store: RecordingPlaybackUnusedStore(), transport: ZoomHTTPTransport { _ in
            throw URLError(.unsupportedURL)
        })
        return RecordingLibraryModel(client: client, fetchPage: fetchPage ?? { _, _, _ in .init(meetings: []) },
                                     makePlaybackSource: { [self] file in
            createdIDs.append(file.id)
            let asset: AVAsset = file.id == "short-view" ? shortAsset : fullAsset
            return RecordingPlaybackSource(item: AVPlayerItem(asset: asset))
        }, downloadVideo: { [url] _, destination in
            await beforeDownload?()
            try FileManager.default.copyItem(at: url, to: destination)
        }, fetchChat: fetchChat, fetchTranscript: fetchTranscript)
    }

    func meeting(id: String = "fixture-meeting") -> ZoomRecordingMeeting {
        .init(id: id, topic: "Synthetic playback fixture", startTime: Date(timeIntervalSince1970: 0), duration: 1,
              files: [file("view-a"), file("view-b"), file("view-c"), file("view-d"), file("short-view")])
    }

    func file(_ id: String) -> ZoomRecordingFile {
        .init(id: id, recordingType: "gallery_view", fileType: "MP4", fileSize: 0,
              downloadURL: URL(string: "https://zoom.us/fixture/\(id)"), playURL: nil, status: "completed")
    }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }
}

private actor RecordingPlaybackRefreshPages {
    private var meetings: [ZoomRecordingMeeting]
    init(meetings: [ZoomRecordingMeeting]) { self.meetings = meetings }
    func replace(with meetings: [ZoomRecordingMeeting]) { self.meetings = meetings }
    func fetch() -> ZoomRecordingPage { .init(meetings: meetings) }
}

private actor RecordingPlaybackTranscriptFetch {
    private(set) var count = 0
    func load() -> String {
        count += 1
        return "WEBVTT\n\n00:00:00.000 --> 00:00:10.000\nAda: Opening\n\n00:00:45.000 --> 00:00:50.000\nSam: The decision is ready.\n"
    }
}

private actor RecordingPlaybackUnusedStore: ZoomCredentialStore {
    func loadConfiguration() -> ZoomPersonalConfiguration? { nil }
    func saveConfiguration(_ value: ZoomPersonalConfiguration) {}
    func loadTokens() -> ZoomOAuthTokens? { nil }
    func saveTokens(_ value: ZoomOAuthTokens) {}
    func deleteTokens() {}
    func deleteAll() {}
}

// Two seconds of 32×32 black H.264 video generated locally; no external recording data.
let recordingPlaybackMP4Fixture = "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMxbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAB9AAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAlx0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAB9AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAACAAAAAgAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAfQAAAAAAABAAAAAAHUbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAAAgABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABf21pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAT9zdGJsAAAAv3N0c2QAAAAAAAAAAQAAAK9hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAACAAIABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMSBsaWJ4MjY0AAAAAAAAAAAAAAAAGP//AAAANWF2Y0MBZAAK/+EAGGdkAAqs2UlsBEAAAAMAQAAAAwCDxIllgAEABmjr48siwP34+AAAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAAAAmAAAAAAAAAAYc3R0cwAAAAAAAAABAAAAAgAAQAAAAAAUc3RzcwAAAAAAAAABAAAAAQAAABxzdHNjAAAAAAAAAAEAAAABAAAAAgAAAAEAAAAcc3RzegAAAAAAAAAAAAAAAgAAABkAAAANAAAAFHN0Y28AAAAAAAAAAQAAA2EAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAxAAAACGZyZWUAAAAubWRhdAAAABVliIQAFv/+99M/zLLsmiS144e/t/8AAAAJQZohbEFf/tbg"
