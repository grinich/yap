import AppKit
import AVFoundation
import Observation
import WhooshMeetings

@MainActor
final class RecordingPlaybackSource {
    let item: AVPlayerItem
    let loader: RecordingMediaLoader?

    init(item: AVPlayerItem, loader: RecordingMediaLoader? = nil) {
        self.item = item
        self.loader = loader
        item.preferredForwardBufferDuration = 2
    }

    func invalidate() {
        item.cancelPendingSeeks()
        loader?.invalidate()
    }
}

private struct RecordingPlaybackPosition {
    let time: CMTime
    let rate: Float

    func clamped(to duration: CMTime) -> CMTime {
        let seconds = time.seconds.isFinite ? max(0, time.seconds) : 0
        let end = duration.seconds
        return CMTime(seconds: end.isFinite && end > 0 ? min(seconds, max(0, end - 1.0 / 600)) : seconds,
                      preferredTimescale: 600)
    }
}

/// Calendar-month windows match Zoom's one-month recording query limit.
struct RecordingMonthWindow: Equatable, Sendable {
    let from: Date
    let to: Date

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func containing(_ date: Date) -> Self {
        Self(from: calendar.dateInterval(of: .month, for: date)!.start, to: date)
    }

    var previous: Self {
        Self.containing(Self.calendar.date(byAdding: .day, value: -1, to: from)!)
    }
}

@MainActor @Observable
public final class RecordingLibraryModel {
    static let playbackSpeeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.25, 2.5]

    public var isPresented = false
    private(set) var isPreview = false
    var search = ""
    private(set) var meetings: [ZoomRecordingMeeting] = []
    private(set) var selectedMeeting: ZoomRecordingMeeting? {
        didSet { chat.select(selectedMeeting, isPreview: isPreview) }
    }
    private(set) var selectedFile: ZoomRecordingFile? {
        didSet { chat.setPlaybackActive(selectedFile != nil) }
    }
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var hasLoadedInitial = false
    private(set) var oldestLoadedDate: Date?
    private(set) var error: String?
    private(set) var playbackError: String?
    private(set) var isPreparing = false
    private(set) var videoAspectRatio: CGFloat = 16.0 / 9.0
    private(set) var playbackSpeed: Float = 1
    private(set) var isDownloading = false
    private(set) var downloadedFile: URL?
    private(set) var downloadError: String?
    private(set) var playerWindows: [String: RecordingPlayerWindowController] = [:]
    let player = AVPlayer()
    let chat: RecordingChatModel

    @ObservationIgnored private let client: ZoomAccountClient
    @ObservationIgnored private let fetchPage: @Sendable (Date, Date, String) async throws -> ZoomRecordingPage
    @ObservationIgnored private let makePlaybackSource: @MainActor (ZoomRecordingFile) -> RecordingPlaybackSource
    @ObservationIgnored private let downloadVideo: @Sendable (ZoomRecordingFile, URL) async throws -> Void
    @ObservationIgnored private let fetchChat: @Sendable (ZoomRecordingFile) async throws -> String
    @ObservationIgnored private var nextWindow: RecordingMonthWindow?
    @ObservationIgnored private var pendingLibraryLoad: LibraryLoad?
    @ObservationIgnored private var activeLibraryLoad: LibraryLoad.Kind?
    @ObservationIgnored private var libraryLoadWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var mediaLoader: RecordingMediaLoader?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var videoSizeObservation: NSKeyValueObservation?
    @ObservationIgnored private var playbackSpeedObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemRevision = UUID()
    @ObservationIgnored private var resumedItemRevision: UUID?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var playbackGeneration = UUID()
    @ObservationIgnored private var pauseRevision = UUID()
    @ObservationIgnored private var temporaryVideo: URL?
    @ObservationIgnored private var temporaryVideoFileID: String?
    @ObservationIgnored private var playbackSources: [String: RecordingPlaybackSource] = [:]
    @ObservationIgnored private var recentSourceIDs: [String] = []
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPosition: RecordingPlaybackPosition?
    @ObservationIgnored private var playbackTimeObserver: Any?
    @ObservationIgnored private var manualSeekTask: Task<Void, Never>?
    @ObservationIgnored private var manualSeekRevision = UUID()
    @ObservationIgnored private var pendingSeekTime: CMTime?

    init(client: ZoomAccountClient,
         fetchPage: (@Sendable (Date, Date, String) async throws -> ZoomRecordingPage)? = nil,
         makePlaybackSource: (@MainActor (ZoomRecordingFile) -> RecordingPlaybackSource)? = nil,
         downloadVideo: (@Sendable (ZoomRecordingFile, URL) async throws -> Void)? = nil,
         fetchChat: (@Sendable (ZoomRecordingFile) async throws -> String)? = nil) {
        self.client = client
        let fetchChat = fetchChat ?? { file in try await RecordingChatLoader.load(client: client, file: file) }
        self.fetchChat = fetchChat
        chat = RecordingChatModel(fetch: fetchChat)
        self.fetchPage = fetchPage ?? { from, to, token in
            try await client.recordings(from: from, to: to, nextPageToken: token)
        }
        self.makePlaybackSource = makePlaybackSource ?? { file in
            let loader = RecordingMediaLoader(client: client, file: file)
            return RecordingPlaybackSource(item: loader.makePlayerItem(), loader: loader)
        }
        self.downloadVideo = downloadVideo ?? { file, destination in
            try await RecordingDownloadService.download(client: client, file: file, to: destination)
        }
        playbackSpeedObservation = player.observe(\.defaultRate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                // A native menu change may arrive off-main. Read the latest
                // value on delivery so an older callback cannot undo a newer pick.
                self?.synchronizeDefaultPlaybackSpeed()
            }
        }
    }

    func setPlaybackSpeed(_ speed: Float) {
        guard Self.playbackSpeeds.contains(speed) else { return }
        applyPlaybackSpeed(speed)
    }

    func cyclePlaybackSpeed() {
        guard !isPreview, selectedFile != nil else { return }
        synchronizeDefaultPlaybackSpeed()
        setPlaybackSpeed(Self.playbackSpeeds.first(where: { $0 > playbackSpeed }) ?? Self.playbackSpeeds[0])
    }

    func cyclePlaybackView() {
        guard !isPreview, let meeting = selectedMeeting, let selectedFile else { return }
        let files = meeting.playableVideoFiles
        guard files.count > 1, let index = files.firstIndex(where: { $0.id == selectedFile.id }) else { return }
        play(files[(index + 1) % files.count])
    }

    func jogPlayback(by seconds: Double) {
        guard !isPreview, !isPreparing, playbackError == nil, selectedFile != nil,
              seconds.isFinite, seconds != 0, let item = player.currentItem, item.status == .readyToPlay else { return }
        let current = (pendingSeekTime ?? player.currentTime()).seconds
        let duration = item.duration.seconds
        guard current.isFinite, duration.isFinite, duration > 0 else { return }
        let target = min(max(0, current + seconds), max(0, duration - 1.0 / 600))
        seekManually(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private func synchronizeDefaultPlaybackSpeed() {
        let speed = player.defaultRate
        if speed != playbackSpeed { applyPlaybackSpeed(speed) }
    }

    private func applyPlaybackSpeed(_ speed: Float) {
        guard speed.isFinite, speed > 0 else { return }
        playbackSpeed = speed
        if player.defaultRate != speed { player.defaultRate = speed }
        if let position = pendingPosition, position.rate != 0 {
            pendingPosition = RecordingPlaybackPosition(time: position.time, rate: speed)
        }
        // Preparation pauses the old item temporarily; its saved intent owns
        // whether the replacement resumes. A genuinely paused video stays paused.
        if !isPreparing, player.rate != 0 { player.rate = speed }
    }

    var filteredMeetings: [ZoomRecordingMeeting] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return meetings }
        let matcher = RecordingSearch(query: query)
        return meetings.filter { matcher.matches($0) }
    }

    public func toggle() {
        if isPresented { dismiss() }
        else {
            isPresented = true
            prepareForPresentation()
        }
    }

    public func dismiss() {
        isPresented = false
        suspendPlayback()
    }

    /// Hiding a view pauses it without discarding the item, seek position, or downloaded fallback.
    public func suspendPlayback() {
        pausePlayback()
        chat.setPlaybackActive(false)
    }

    /// A selected recording should already have usable native controls when its view appears.
    /// Recovery stays paused and never competes with a dedicated player for the same meeting.
    func prepareForPresentation() {
        guard !isPreview, let meeting = selectedMeeting, playerWindows[meeting.id] == nil else { return }
        if selectedFile != nil {
            chat.setPlaybackActive(true)
            return
        }
        guard !isPreparing, playbackError == nil, let file = meeting.playableVideoFiles.first else { return }
        play(file, resuming: RecordingPlaybackPosition(time: .zero, rate: 0))
    }

    private struct LibraryLoad {
        enum Kind { case initial, older, refresh }
        let kind: Kind
        var windows: [RecordingMonthWindow]
    }

    func loadInitial(now: Date = .now) async {
        guard !isPreview, !hasLoadedInitial, activeLibraryLoad == nil else { return }
        if let pendingLibraryLoad, pendingLibraryLoad.kind == .initial {
            await load(pendingLibraryLoad)
        } else {
            let current = RecordingMonthWindow.containing(now)
            await load(.init(kind: .initial, windows: [current, current.previous, current.previous.previous]))
        }
    }

    func loadOlder() async {
        guard !isPreview, activeLibraryLoad == nil else { return }
        guard hasLoadedInitial, let nextWindow else { await loadInitial(); return }
        await load(.init(kind: .older, windows: [nextWindow]))
    }

    /// Reopening refreshes metadata without changing any playback or selection state.
    func refreshForPresentation(now: Date = .now) async { await refresh(now: now) }

    func refresh(now: Date = .now) async {
        guard !isPreview, !Task.isCancelled else { return }
        let expected = generation
        if let activeLibraryLoad {
            // Presentation tasks can overlap when a view is quickly hidden and
            // reopened. Share a successful fetch, but retry a cancelled fetch.
            let cancelled = await withCheckedContinuation { libraryLoadWaiters.append($0) }
            guard expected == generation, !Task.isCancelled, !isPreview else { return }
            if !cancelled, activeLibraryLoad != .older { return }
            await refresh(now: now)
            return
        }
        guard hasLoadedInitial else { await loadInitial(now: now); return }
        var window = RecordingMonthWindow.containing(now)
        let oldest = oldestLoadedDate ?? window.previous.previous.from
        var windows = [window]
        while window.from > oldest {
            window = window.previous
            windows.append(window)
        }
        await load(.init(kind: .refresh, windows: windows))
    }

    func retryLoading() async {
        guard !isPreview, activeLibraryLoad == nil else { return }
        if let pendingLibraryLoad { await load(pendingLibraryLoad) }
        else if !hasLoadedInitial { await loadInitial() }
        else { await refresh() }
    }

    private func load(_ request: LibraryLoad) async {
        guard !isPreview, activeLibraryLoad == nil, !Task.isCancelled else { return }
        let expected = generation
        activeLibraryLoad = request.kind
        isRefreshing = request.kind == .refresh
        isLoading = !isRefreshing
        error = nil
        pendingLibraryLoad = request
        var wasCancelled = false
        defer {
            if expected == generation {
                isLoading = false
                isRefreshing = false
                activeLibraryLoad = nil
                let waiters = libraryLoadWaiters
                libraryLoadWaiters = []
                for waiter in waiters { waiter.resume(returning: Task.isCancelled || wasCancelled) }
            }
        }
        do {
            for (index, window) in request.windows.enumerated() {
                try Task.checkCancellation()
                guard generation == expected else { return }
                pendingLibraryLoad = .init(kind: request.kind, windows: Array(request.windows[index...]))
                var token = ""
                var seenTokens: Set<String> = []
                var batch: [ZoomRecordingMeeting] = []
                repeat {
                    let page = try await fetchPage(window.from, window.to, token)
                    try Task.checkCancellation()
                    guard generation == expected else { return }
                    batch.append(contentsOf: page.meetings)
                    token = page.nextPageToken
                    if !token.isEmpty, !seenTokens.insert(token).inserted {
                        throw ZoomAccountError.invalidResponse
                    }
                } while !token.isEmpty
                merge(batch)
                if oldestLoadedDate == nil || window.from < oldestLoadedDate! {
                    oldestLoadedDate = window.from
                    nextWindow = window.previous
                }
            }
            pendingLibraryLoad = nil
            if request.kind == .initial { hasLoadedInitial = true }
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            if generation == expected, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func merge(_ batch: [ZoomRecordingMeeting]) {
        // Missing records are retained: a partial API response is not evidence
        // of deletion, and selected playback owns its existing immutable snapshot.
        var byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        for meeting in batch { byID[meeting.id] = meeting }
        let merged = byID.values.sorted {
            $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime > $1.startTime
        }
        if merged != meetings { meetings = merged }
    }

    func select(_ meeting: ZoomRecordingMeeting) {
        stopPlayback()
        selectedMeeting = meeting
        if let file = meeting.playableVideoFiles.first { play(file) }
    }

    func selectFromList(_ meeting: ZoomRecordingMeeting) {
        if let existing = playerWindows[meeting.id] {
            chat.clear()
            stopPlayback()
            selectedMeeting = meeting
            existing.present()
            return
        }
        // The Button's single action can accompany the double-click gesture.
        // Do not restart an already selected recording or its newly opened window.
        if selectedMeeting?.id == meeting.id {
            if selectedFile == nil, playerWindows[meeting.id] == nil,
               let file = meeting.playableVideoFiles.first { play(file) }
            return
        }
        playerWindows.values.forEach { $0.playback.pausePlayback() }
        select(meeting)
    }

    func openPlayerWindow(for meeting: ZoomRecordingMeeting) {
        if let existing = playerWindows[meeting.id] {
            chat.clear()
            stopPlayback()
            selectedMeeting = meeting
            existing.present()
            return
        }
        synchronizeDefaultPlaybackSpeed()
        let file = selectedMeeting?.id == meeting.id ? selectedFile : nil
        let position = file == nil ? nil : pendingPosition
            ?? RecordingPlaybackPosition(time: pendingSeekTime ?? player.currentTime(), rate: player.rate)
        let localVideo = file?.id == temporaryVideoFileID ? temporaryVideo : nil
        if localVideo != nil {
            // Move ownership before stopping the inline player can remove its fallback file.
            temporaryVideo = nil
            temporaryVideoFileID = nil
        }
        let playback = RecordingLibraryModel(client: client, makePlaybackSource: makePlaybackSource,
                                             downloadVideo: downloadVideo, fetchChat: fetchChat)
        let transferredSpeed = position.flatMap { $0.rate > 0 ? $0.rate : nil } ?? playbackSpeed
        playback.applyPlaybackSpeed(transferredSpeed)
        playback.isPreview = isPreview
        playback.selectedMeeting = meeting
        playback.chat.adoptState(from: chat)
        chat.clear()
        // Opening a player moves audio out of the library; other windows remain available.
        stopPlayback()
        playerWindows.values.forEach { $0.playback.pausePlayback() }
        selectedMeeting = meeting
        if let video = file ?? meeting.playableVideoFiles.first {
            if let localVideo {
                playback.temporaryVideo = localVideo
                playback.temporaryVideoFileID = video.id
                playback.selectedFile = video
                playback.isPreparing = true
                let resume = position ?? RecordingPlaybackPosition(time: .zero, rate: playback.playbackSpeed)
                playback.pendingPosition = resume
                playback.installPlayerItem(AVPlayerItem(url: localVideo), generation: playback.playbackGeneration,
                                           position: resume)
            } else { playback.play(video, resuming: position) }
        }
        let controller = RecordingPlayerWindowController(playback: playback, meeting: meeting)
        controller.onClose = { [weak self] in
            guard let self else { return }
            self.playerWindows.removeValue(forKey: meeting.id)
            if self.selectedMeeting?.id == meeting.id, self.selectedFile == nil {
                self.selectedMeeting = nil
                self.chat.clear()
            }
        }
        playerWindows[meeting.id] = controller
        controller.present()
    }

    public func closePlayerWindows() {
        let controllers = Array(playerWindows.values)
        playerWindows.removeAll()
        controllers.forEach { $0.close() }
    }

    private func pausePlayback() {
        pauseRevision = UUID()
        player.pause()
        if let position = pendingPosition {
            pendingPosition = RecordingPlaybackPosition(time: position.time, rate: 0)
        }
    }

    func play(_ file: ZoomRecordingFile) {
        playerWindows.values.forEach { $0.playback.pausePlayback() }
        play(file, resuming: nil)
    }

    private func play(_ file: ZoomRecordingFile, resuming resumePosition: RecordingPlaybackPosition?) {
        guard selectedFile?.id != file.id || playbackError != nil else { return }
        synchronizeDefaultPlaybackSpeed()
        // A second switch may arrive while the first is still loading at time zero.
        // Carry the original intent through until the replacement has finished seeking.
        let position = resumePosition ?? pendingPosition ?? (selectedFile == nil
            ? RecordingPlaybackPosition(time: .zero, rate: playbackSpeed)
            : RecordingPlaybackPosition(time: pendingSeekTime ?? player.currentTime(), rate: player.rate))
        if position.rate > 0 { applyPlaybackSpeed(position.rate) }
        playbackGeneration = UUID()
        cancelManualSeek()
        preparationTask?.cancel()
        preparationTask = nil
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        itemObservation = nil
        mediaLoader?.onFailure = nil
        cancelCurrentDownload()
        playbackError = nil
        selectedFile = file
        guard !isPreview else { return }
        isPreparing = true
        pendingPosition = position
        let expected = playbackGeneration
        if playbackSources[file.id]?.item.status == .failed {
            playbackSources.removeValue(forKey: file.id)?.invalidate()
        }
        let source = playbackSources[file.id] ?? makePlaybackSource(file)
        playbackSources[file.id] = source
        recentSourceIDs.removeAll { $0 == file.id }
        recentSourceIDs.append(file.id)
        trimPlaybackSources()
        source.loader?.onFailure = { [weak self] error in
            guard let self, self.playbackGeneration == expected else { return }
            if self.pendingPosition == nil {
                self.pendingPosition = RecordingPlaybackPosition(time: self.player.currentTime(), rate: self.player.rate)
            }
            self.isPreparing = false
            self.playbackError = (error as? ZoomAccountError)?.localizedDescription
                ?? (error as? RecordingMediaError)?.localizedDescription
                ?? "This recording couldn’t be streamed. Check your connection, or download it to play here."
            self.player.pause()
            self.playbackSources.removeValue(forKey: file.id)?.invalidate()
        }
        mediaLoader = source.loader
        preparationTask = Task { [weak self] in
            do {
                // Keep the previous frame visible while the new view's MP4 metadata loads.
                guard try await source.item.asset.load(.isPlayable) else { throw RecordingMediaError.unsupportedContent }
                try Task.checkCancellation()
                guard let self, self.playbackGeneration == expected, self.playbackError == nil else { return }
                self.installPlayerItem(source.item, generation: expected, position: position)
                if let temporaryVideo = self.temporaryVideo {
                    try? FileManager.default.removeItem(at: temporaryVideo)
                    self.temporaryVideo = nil
                    self.temporaryVideoFileID = nil
                }
            } catch {
                guard let self, self.playbackGeneration == expected, !Task.isCancelled else { return }
                self.isPreparing = false
                if self.playbackError == nil {
                    self.playbackError = "This video couldn’t be opened. Try downloading it, or refresh the library to renew its access."
                }
                self.playbackSources.removeValue(forKey: file.id)?.invalidate()
            }
        }
    }

    private func trimPlaybackSources() {
        // Keep recently visited views warm without retaining every recording in the library.
        while recentSourceIDs.count > 3 {
            playbackSources.removeValue(forKey: recentSourceIDs.removeFirst())?.invalidate()
        }
    }

    private func installPlayerItem(_ item: AVPlayerItem, generation expected: UUID,
                                   position: RecordingPlaybackPosition) {
        cancelManualSeek()
        let revision = UUID()
        itemRevision = revision
        if let playbackTimeObserver { player.removeTimeObserver(playbackTimeObserver) }
        if player.currentItem !== item { player.replaceCurrentItem(with: item) }
        videoSizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            let size = item.presentationSize
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == expected, self.itemRevision == revision,
                      size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
                self.videoAspectRatio = size.width / size.height
            }
        }
        playbackTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                              queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == expected, self.itemRevision == revision,
                      !self.isPreparing else { return }
                self.synchronizeChat(at: time)
            }
        }
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == expected, self.itemRevision == revision else { return }
                if status == .readyToPlay {
                    guard self.resumedItemRevision != revision else { return }
                    self.resumedItemRevision = revision
                    let completed = await self.player.seek(to: position.clamped(to: item.duration),
                                                           toleranceBefore: .zero, toleranceAfter: .zero)
                    guard self.playbackGeneration == expected, self.itemRevision == revision else { return }
                    self.isPreparing = false
                    guard completed, self.playbackError == nil, item.status == .readyToPlay else { return }
                    let rate = self.pendingPosition?.rate ?? position.rate
                    self.pendingPosition = nil
                    self.synchronizeChat(at: self.player.currentTime())
                    if rate != 0 { self.player.playImmediately(atRate: rate) }
                }
                else if status == .failed, self.playbackError == nil {
                    if self.pendingPosition == nil {
                        self.pendingPosition = RecordingPlaybackPosition(time: self.player.currentTime(), rate: self.player.rate)
                    }
                    self.isPreparing = false
                    self.playbackError = "This video couldn’t be played. Try downloading it, or refresh the library to renew its access."
                }
            }
        }
    }

    public func stopPlayback() {
        playbackGeneration = UUID()
        cancelManualSeek()
        if let playbackTimeObserver { player.removeTimeObserver(playbackTimeObserver) }
        playbackTimeObserver = nil
        preparationTask?.cancel()
        preparationTask = nil
        pendingPosition = nil
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservation = nil
        videoSizeObservation = nil
        videoAspectRatio = 16.0 / 9.0
        mediaLoader?.invalidate()
        mediaLoader = nil
        playbackSources.values.forEach { $0.invalidate() }
        playbackSources.removeAll()
        recentSourceIDs.removeAll()
        cancelCurrentDownload()
        if let temporaryVideo { try? FileManager.default.removeItem(at: temporaryVideo) }
        temporaryVideo = nil
        temporaryVideoFileID = nil
        selectedFile = nil
        isPreparing = false
        playbackError = nil
        chat.synchronize(playerTime: nil, file: nil, duration: nil)
    }

    private func synchronizeChat(at time: CMTime) {
        chat.synchronize(playerTime: time.seconds, file: selectedFile, duration: player.currentItem?.duration.seconds)
    }

    func seekToChatMessage(_ message: ZoomRecordingChatMessage) {
        guard !isPreparing, let seconds = chat.playbackTime(for: message), player.currentItem != nil else { return }
        chat.followsPlayback = true
        seekManually(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    private func cancelManualSeek() {
        manualSeekRevision = UUID()
        if manualSeekTask != nil { player.currentItem?.cancelPendingSeeks() }
        manualSeekTask?.cancel()
        manualSeekTask = nil
        pendingSeekTime = nil
    }

    private func seekManually(to target: CMTime) {
        guard let item = player.currentItem else { return }
        cancelManualSeek()
        pendingSeekTime = target
        let expected = playbackGeneration
        let revision = manualSeekRevision
        manualSeekTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.playbackGeneration == expected,
                  self.manualSeekRevision == revision, self.player.currentItem === item else { return }
            let completed = await self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled, self.playbackGeneration == expected,
                  self.manualSeekRevision == revision, self.player.currentItem === item else { return }
            self.pendingSeekTime = nil
            self.manualSeekTask = nil
            if completed { self.synchronizeChat(at: self.player.currentTime()) }
        }
    }

    private func cancelCurrentDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadedFile = nil
        downloadError = nil
    }

    func downloadSelected(to destination: URL? = nil) {
        guard !isPreview, let file = selectedFile, !isDownloading else { return }
        synchronizeDefaultPlaybackSpeed()
        let expected = playbackGeneration
        let expectedPause = pauseRevision
        let position = pendingPosition ?? RecordingPlaybackPosition(time: pendingSeekTime ?? player.currentTime(), rate: player.rate)
        let target = destination ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("Zooom-recording-\(UUID().uuidString).mp4")
        isDownloading = true
        downloadError = nil
        downloadTask = Task { [weak self, downloadVideo] in
            defer {
                if let self, self.playbackGeneration == expected {
                    self.isDownloading = false
                    self.downloadTask = nil
                }
            }
            do {
                try await downloadVideo(file, target)
                guard let self, self.playbackGeneration == expected, !Task.isCancelled else {
                    if destination == nil { try? FileManager.default.removeItem(at: target) }
                    return
                }
                self.isDownloading = false
                if destination == nil {
                    // Keep the selected speed and a failed stream's saved intent.
                    // A later model pause takes precedence over AVPlayer's transient rate.
                    let positionToResume = self.pendingPosition ?? RecordingPlaybackPosition(time: position.time,
                        rate: self.player.currentItem?.status == .readyToPlay && self.playbackError == nil
                            ? (self.player.rate == 0 ? 0 : self.playbackSpeed)
                            : (position.rate == 0 ? 0 : self.playbackSpeed))
                    // A hide/pause request revokes this download's automatic resume,
                    // even if AVPlayer still reports the rate from before that request.
                    let resume = RecordingPlaybackPosition(time: positionToResume.time,
                        rate: self.pauseRevision == expectedPause ? positionToResume.rate : 0)
                    self.preparationTask?.cancel()
                    self.preparationTask = nil
                    self.player.pause()
                    self.mediaLoader?.invalidate()
                    self.mediaLoader = nil
                    self.playbackSources.removeValue(forKey: file.id)?.invalidate()
                    let previousVideo = self.temporaryVideo
                    self.temporaryVideo = target
                    self.temporaryVideoFileID = file.id
                    self.playbackError = nil
                    self.isPreparing = true
                    self.pendingPosition = resume
                    self.installPlayerItem(AVPlayerItem(url: target), generation: expected,
                        position: resume)
                    if let previousVideo { try? FileManager.default.removeItem(at: previousVideo) }
                } else { self.downloadedFile = target }
            } catch {
                if destination == nil { try? FileManager.default.removeItem(at: target) }
                guard let self, self.playbackGeneration == expected else { return }
                self.isDownloading = false
                if !Task.isCancelled { self.downloadError = error.localizedDescription }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Discard account-specific metadata and media on every account mutation.
    public func clear() {
        resetLibrary(closingPlayerWindows: true)
    }

    private func resetLibrary(closingPlayerWindows: Bool) {
        generation = UUID()
        if closingPlayerWindows { closePlayerWindows() }
        chat.clear()
        stopPlayback()
        meetings = []
        selectedMeeting = nil
        search = ""
        error = nil
        isLoading = false
        isRefreshing = false
        activeLibraryLoad = nil
        pendingLibraryLoad = nil
        let waiters = libraryLoadWaiters
        libraryLoadWaiters = []
        for waiter in waiters { waiter.resume(returning: false) }
        hasLoadedInitial = false
        oldestLoadedDate = nil
        nextWindow = nil
        isPreview = false
    }

    func enterPreview(now: Date = .now) {
        clear()
        isPreview = true
        hasLoadedInitial = true
        let topics = ["Product design review", "Weekly team catch-up", "A conversation about what’s next", "Project walkthrough"]
        meetings = topics.enumerated().map { index, topic in
            ZoomRecordingMeeting(id: "preview-\(index)", topic: topic,
                startTime: now.addingTimeInterval(-Double(index + 1) * 86_400), duration: [42, 28, 55, 36][index],
                files: [ZoomRecordingFile(id: "preview-video-\(index)", recordingType: "shared_screen_with_speaker_view",
                    fileType: "MP4", fileSize: 0, downloadURL: URL(string: "https://zoom.us/preview-\(index)"),
                    playURL: nil, status: "completed")])
        }
    }
}
