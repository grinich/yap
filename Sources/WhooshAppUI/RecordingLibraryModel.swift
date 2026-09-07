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
    private(set) var selectedFile: ZoomRecordingFile?
    private(set) var isLoading = false
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
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var mediaLoader: RecordingMediaLoader?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var videoSizeObservation: NSKeyValueObservation?
    @ObservationIgnored private var playbackSpeedObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemRevision = UUID()
    @ObservationIgnored private var resumedItemRevision: UUID?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var playbackGeneration = UUID()
    @ObservationIgnored private var temporaryVideo: URL?
    @ObservationIgnored private var temporaryVideoFileID: String?
    @ObservationIgnored private var playbackSources: [String: RecordingPlaybackSource] = [:]
    @ObservationIgnored private var recentSourceIDs: [String] = []
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPosition: RecordingPlaybackPosition?
    @ObservationIgnored private var playbackTimeObserver: Any?
    @ObservationIgnored private var chatSeekTask: Task<Void, Never>?

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
        return query.isEmpty ? meetings : meetings.filter { $0.topic.localizedStandardContains(query) }
    }

    public func toggle() {
        if isPresented { dismiss() }
        else { isPresented = true }
    }

    public func dismiss() {
        isPresented = false
        stopPlayback()
    }

    func loadInitial(now: Date = .now) async {
        guard !isPreview, !hasLoadedInitial, !isLoading else { return }
        let expected = generation
        if nextWindow == nil { nextWindow = .containing(now) }
        await loadMonths(3)
        if expected == generation, error == nil, !Task.isCancelled { hasLoadedInitial = true }
    }

    func loadOlder() async { await loadMonths(1) }

    func refresh() async {
        resetLibrary(closingPlayerWindows: false)
        await loadInitial()
    }

    private func loadMonths(_ count: Int) async {
        guard !isLoading, !Task.isCancelled else { return }
        let expected = generation
        isLoading = true
        error = nil
        defer { if expected == generation { isLoading = false } }
        do {
            for _ in 0..<count {
                guard let window = nextWindow else { break }
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
                var byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
                for meeting in batch { byID[meeting.id] = meeting }
                meetings = byID.values.sorted {
                    $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime > $1.startTime
                }
                oldestLoadedDate = window.from
                nextWindow = window.previous
            }
        } catch is CancellationError {
        } catch {
            if generation == expected, !Task.isCancelled { self.error = error.localizedDescription }
        }
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
            ?? RecordingPlaybackPosition(time: player.currentTime(), rate: player.rate)
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
        controller.onClose = { [weak self] in self?.playerWindows.removeValue(forKey: meeting.id) }
        playerWindows[meeting.id] = controller
        controller.present()
    }

    public func closePlayerWindows() {
        let controllers = Array(playerWindows.values)
        playerWindows.removeAll()
        controllers.forEach { $0.close() }
    }

    private func pausePlayback() {
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
            : RecordingPlaybackPosition(time: player.currentTime(), rate: player.rate))
        if position.rate > 0 { applyPlaybackSpeed(position.rate) }
        playbackGeneration = UUID()
        chatSeekTask?.cancel()
        chatSeekTask = nil
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
        chatSeekTask?.cancel()
        chatSeekTask = nil
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
        let expected = playbackGeneration
        chatSeekTask?.cancel()
        chatSeekTask = Task { [weak self] in
            guard let self else { return }
            let completed = await self.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                                                   toleranceBefore: .zero, toleranceAfter: .zero)
            guard completed, !Task.isCancelled, self.playbackGeneration == expected else { return }
            self.synchronizeChat(at: self.player.currentTime())
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
        let position = pendingPosition ?? RecordingPlaybackPosition(time: player.currentTime(), rate: player.rate)
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
                    // A speed or pause change made while downloading belongs to
                    // the fallback too. AVPlayer.rate can briefly lag a requested
                    // speed change; use it only for paused/playing intent, and
                    // restore the selected speed. Failed streams retain their intent.
                    let resume = self.pendingPosition ?? RecordingPlaybackPosition(time: position.time,
                        rate: self.player.currentItem?.status == .readyToPlay && self.playbackError == nil
                            ? (self.player.rate == 0 ? 0 : self.playbackSpeed)
                            : (position.rate == 0 ? 0 : self.playbackSpeed))
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
