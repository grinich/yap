import Foundation
import Observation
import YapMeetings

@MainActor @Observable
final class RecordingTranscriptModel {
    private(set) var isPresented = false
    private(set) var cues: [ZoomRecordingTranscriptCue] = []
    private(set) var activeCueIDs: Set<String> = []
    private(set) var scrollTargetID: String?
    var followsPlayback = true
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var hasTranscriptFile = false
    private(set) var error: String?
    private(set) var timingNotice: String?
    var query = "" { didSet { if query != oldValue { updateMatches() } } }
    private(set) var matchingCueIDs: [String] = []
    private(set) var currentMatchID: String?
    var matchCount: Int { matchingCueIDs.count }
    /// Zero means that there is no current match; otherwise this is one-based.
    var currentMatchIndex: Int {
        currentMatchID.flatMap { matchingCueIDs.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
    }

    @ObservationIgnored private var meeting: ZoomRecordingMeeting?
    @ObservationIgnored private var preview = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var isPlaybackActive = false
    @ObservationIgnored private var playerTime: TimeInterval?
    @ObservationIgnored private var videoFile: ZoomRecordingFile?
    @ObservationIgnored private var duration: TimeInterval?
    @ObservationIgnored private var content: RecordingTranscriptContents?
    @ObservationIgnored private let fetch: @Sendable (ZoomRecordingFile) async throws -> String

    init(fetch: @escaping @Sendable (ZoomRecordingFile) async throws -> String) { self.fetch = fetch }

    func select(_ meeting: ZoomRecordingMeeting?, isPreview: Bool) {
        guard self.meeting?.id != meeting?.id || self.meeting?.transcriptFiles != meeting?.transcriptFiles ||
                preview != isPreview else { return }
        let isNewMeeting = self.meeting?.id != meeting?.id || preview != isPreview
        resetContent(clearInteraction: isNewMeeting)
        if isNewMeeting {
            isPresented = false
            isPlaybackActive = false
            playerTime = nil
            videoFile = nil
            duration = nil
        }
        self.meeting = meeting
        preview = isPreview
        hasTranscriptFile = !(meeting?.transcriptFiles.isEmpty ?? true)
        if isPresented || isPlaybackActive { load() }
    }

    func setPlaybackActive(_ value: Bool) {
        guard isPlaybackActive != value else { return }
        isPlaybackActive = value
        if value { load() }
    }

    func setPresented(_ value: Bool) {
        isPresented = value
        // Changing tabs must preserve search position and the user's scroll choice.
        if value { load() }
    }

    func retry() { load(force: true) }

    private func load(force: Bool = false) {
        guard let meeting, !isLoading, force || !hasLoaded else { return }
        if preview {
            let sample = [
                ZoomRecordingTranscriptCue(id: "preview-transcript-1", start: 5, end: 12, speaker: "Alex",
                                           text: "Let’s walk through the latest design."),
                ZoomRecordingTranscriptCue(id: "preview-transcript-2", start: 15, end: 24, speaker: "Sam",
                                           text: "The updated version makes that much clearer.")
            ]
            publish(.init(cues: sample, origin: meeting.startTime, sourceOffsets: [:], anchoredCueIDs: []))
            hasTranscriptFile = true
            return
        }
        let files = meeting.transcriptFiles
        guard !files.isEmpty else {
            publish(.init(cues: [], origin: meeting.startTime, sourceOffsets: [:], anchoredCueIDs: []))
            return
        }
        isLoading = true
        error = nil
        let expected = generation
        loadTask = Task { [weak self, fetch] in
            do {
                let content = try await RecordingTranscriptContents.load(files: files, fallbackOrigin: meeting.startTime, fetch: fetch)
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.publish(content)
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.isLoading = false
                self.loadTask = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func publish(_ content: RecordingTranscriptContents) {
        self.content = content
        cues = content.cues
        hasLoaded = true
        isLoading = false
        error = nil
        loadTask = nil
        updateMatches()
        updateHighlight()
    }

    /// VTT clocks begin at their recording file. Use the difference between the
    /// transcript and video start timestamps, never the meeting chat's clock.
    func synchronize(playerTime: TimeInterval?, file: ZoomRecordingFile?, duration: TimeInterval?) {
        guard meeting != nil, let file, let playerTime, playerTime.isFinite else {
            self.playerTime = nil
            videoFile = nil
            self.duration = nil
            activeCueIDs = []
            scrollTargetID = nil
            timingNotice = nil
            return
        }
        self.playerTime = max(0, playerTime)
        videoFile = file
        self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let start = file.recordingStart, let end = file.recordingEnd, let duration = self.duration,
           end.timeIntervalSince(start) - duration > 5 {
            timingNotice = "Transcript timing may differ where this recording was paused or edited."
        } else { timingNotice = nil }
        updateHighlight()
    }

    func playbackTime(for cue: ZoomRecordingTranscriptCue) -> TimeInterval? {
        guard playerTime != nil, videoFile != nil else { return nil }
        let interval = playbackInterval(for: cue)
        guard interval.end > 0, duration.map({ interval.start < $0 }) ?? true else { return nil }
        return max(0, interval.start)
    }

    private func playbackInterval(for cue: ZoomRecordingTranscriptCue) -> (start: TimeInterval, end: TimeInterval) {
        let offset: TimeInterval
        if let content, content.anchoredCueIDs.contains(cue.id), let start = videoFile?.recordingStart {
            offset = start.timeIntervalSince(content.origin)
        } else {
            // If either file lacks metadata, the original VTT clock is the only
            // reliable clock available. Do not invent an offset from meeting time.
            offset = content?.sourceOffsets[cue.id] ?? 0
        }
        return (cue.start - offset, cue.end - offset)
    }

    private func updateHighlight() {
        guard let time = playerTime else { activeCueIDs = []; scrollTargetID = nil; return }
        var active: Set<String> = []
        var latest: (id: String, start: TimeInterval)?
        for cue in cues {
            let interval = playbackInterval(for: cue)
            guard interval.end > 0, interval.start <= time else { continue }
            if latest == nil || interval.start >= latest!.start { latest = (cue.id, interval.start) }
            if time < interval.end, duration.map({ time < $0 }) ?? true { active.insert(cue.id) }
        }
        if activeCueIDs != active { activeCueIDs = active }
        if scrollTargetID != latest?.id { scrollTargetID = latest?.id }
    }

    private func updateMatches() {
        let needle = Self.searchText(query)
        matchingCueIDs = needle.isEmpty ? [] : cues.filter {
            Self.searchText([$0.speaker, $0.text].compactMap { $0 }.joined(separator: " ")).contains(needle)
        }.map(\.id)
        if currentMatchID.map({ matchingCueIDs.contains($0) }) != true { currentMatchID = matchingCueIDs.first }
    }

    private static func searchText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @discardableResult func selectNextMatch() -> ZoomRecordingTranscriptCue? { selectMatch(direction: 1) }
    @discardableResult func selectPreviousMatch() -> ZoomRecordingTranscriptCue? { selectMatch(direction: -1) }

    private func selectMatch(direction: Int) -> ZoomRecordingTranscriptCue? {
        guard !matchingCueIDs.isEmpty else { return nil }
        let index = currentMatchID.flatMap { matchingCueIDs.firstIndex(of: $0) }
        let next = index.map { ($0 + direction + matchingCueIDs.count) % matchingCueIDs.count }
            ?? (direction > 0 ? 0 : matchingCueIDs.count - 1)
        currentMatchID = matchingCueIDs[next]
        followsPlayback = false
        return cues.first { $0.id == currentMatchID }
    }

    /// Copy and export include the complete transcript, independent of search.
    var transcriptText: String {
        cues.map { cue in
            let speaker = cue.speaker.map { "\($0): " } ?? ""
            return "[\(Self.timestamp(cue.start, milliseconds: false))] \(speaker)\(cue.text)"
        }.joined(separator: "\n\n")
    }

    var transcriptVTT: String {
        "WEBVTT\n\n" + cues.enumerated().map { index, cue in
            let text = Self.escapeVTT(cue.text).components(separatedBy: .newlines)
                .filter { !$0.isEmpty }.joined(separator: "\n")
            let body = cue.speaker.map { "<v \(Self.escapeVTT($0).replacingOccurrences(of: "\n", with: " "))>\(text)</v>" } ?? text
            return "\(index + 1)\n\(Self.timestamp(cue.start)) --> \(Self.timestamp(cue.end))\n\(body)\n"
        }.joined(separator: "\n")
    }

    private static func timestamp(_ seconds: TimeInterval, milliseconds: Bool = true) -> String {
        let total = Int64((max(0, seconds) * 1_000).rounded())
        let base = String(format: "%02lld:%02lld:%02lld", total / 3_600_000, total / 60_000 % 60, total / 1_000 % 60)
        return milliseconds ? base + String(format: ".%03lld", total % 1_000) : base
    }

    private static func escapeVTT(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    func adoptState(from other: RecordingTranscriptModel) {
        guard let meeting, meeting.id == other.meeting?.id,
              meeting.transcriptFiles == other.meeting?.transcriptFiles, preview == other.preview else { return }
        isPresented = other.isPresented
        followsPlayback = other.followsPlayback
        query = other.query
        if other.hasLoaded, let content = other.content {
            // A completed cache supersedes any request this player already started.
            generation = UUID()
            loadTask?.cancel()
            publish(content)
            hasTranscriptFile = other.hasTranscriptFile
            currentMatchID = other.currentMatchID
        } else if isPresented || isPlaybackActive { load() }
    }

    func clear() {
        isPresented = false
        isPlaybackActive = false
        resetContent(clearInteraction: true)
        meeting = nil
        preview = false
        hasTranscriptFile = false
        playerTime = nil
        videoFile = nil
        duration = nil
    }

    private func resetContent(clearInteraction: Bool) {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        content = nil
        cues = []
        hasLoaded = false
        isLoading = false
        error = nil
        activeCueIDs = []
        scrollTargetID = nil
        timingNotice = nil
        matchingCueIDs = []
        currentMatchID = nil
        if clearInteraction {
            query = ""
            followsPlayback = true
        }
    }
}

/// Fetch, parse, merge, and sort off the UI actor. Source offsets preserve the
/// recording-relative fallback for files without recording_start metadata.
private struct RecordingTranscriptContents: Sendable {
    let cues: [ZoomRecordingTranscriptCue]
    let origin: Date
    let sourceOffsets: [String: TimeInterval]
    let anchoredCueIDs: Set<String>

    @concurrent
    static func load(files: [ZoomRecordingFile], fallbackOrigin: Date,
                     fetch: @escaping @Sendable (ZoomRecordingFile) async throws -> String) async throws -> Self {
        let origin = files.compactMap(\.recordingStart).min() ?? fallbackOrigin
        var merged: [ZoomRecordingTranscriptCue] = []
        var offsets: [String: TimeInterval] = [:]
        var anchored: Set<String> = []
        var seen: Set<TranscriptCueContent> = []
        for file in files {
            try Task.checkCancellation()
            let text = try await fetch(file)
            try Task.checkCancellation()
            let parsed = try ZoomRecordingTranscriptParser.parse(text)
            let offset = file.recordingStart?.timeIntervalSince(origin) ?? 0
            for (index, cue) in parsed.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                let normalized = ZoomRecordingTranscriptCue(id: "\(file.id):\(cue.id)",
                    start: cue.start + offset, end: cue.end + offset, speaker: cue.speaker, text: cue.text)
                guard seen.insert(.init(start: normalized.start, end: normalized.end,
                                        speaker: normalized.speaker, text: normalized.text)).inserted else { continue }
                merged.append(normalized)
                offsets[normalized.id] = offset
                if file.recordingStart != nil { anchored.insert(normalized.id) }
            }
        }
        try Task.checkCancellation()
        let sorted = merged.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        try Task.checkCancellation()
        return .init(cues: sorted, origin: origin, sourceOffsets: offsets, anchoredCueIDs: anchored)
    }
}

private struct TranscriptCueContent: Hashable {
    let start: TimeInterval
    let end: TimeInterval
    let speaker: String?
    let text: String
}
