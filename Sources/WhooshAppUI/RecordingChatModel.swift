import Foundation
import Observation
import WhooshMeetings

@MainActor @Observable
final class RecordingChatModel {
    private(set) var isPresented = false
    private(set) var messages: [ZoomRecordingChatMessage] = []
    private(set) var activeMessageIDs: Set<String> = []
    private(set) var scrollTargetID: String?
    var followsPlayback = true
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var hasChatFile = false
    private(set) var timingNotice: String?

    @ObservationIgnored private var meeting: ZoomRecordingMeeting?
    @ObservationIgnored private var preview = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var meetingTime: TimeInterval?
    @ObservationIgnored private var fileStart: TimeInterval = 0
    @ObservationIgnored private var duration: TimeInterval?
    @ObservationIgnored private let fetch: @Sendable (ZoomRecordingFile) async throws -> String

    init(fetch: @escaping @Sendable (ZoomRecordingFile) async throws -> String) { self.fetch = fetch }

    func select(_ meeting: ZoomRecordingMeeting?, isPreview: Bool) {
        guard self.meeting?.id != meeting?.id || self.meeting?.chatFiles != meeting?.chatFiles || preview != isPreview else { return }
        resetContent()
        self.meeting = meeting
        preview = isPreview
        hasChatFile = !(meeting?.chatFiles.isEmpty ?? true)
        if isPresented { load() }
    }

    func setPresented(_ value: Bool) {
        isPresented = value
        if value {
            followsPlayback = true
            load()
        }
    }

    func retry() { load(force: true) }

    private func load(force: Bool = false) {
        guard let meeting, !isLoading, force || !hasLoaded else { return }
        guard !preview else {
            messages = [
                .init(id: "preview-chat-1", offset: 15, sender: "Alex", recipient: nil, text: "I’ve added the notes here."),
                .init(id: "preview-chat-2", offset: 42, sender: "Sam", recipient: nil, text: "Thanks — let’s look at the next version.")
            ]
            hasChatFile = true
            hasLoaded = true
            updateHighlight()
            return
        }
        let files = meeting.chatFiles
        guard !files.isEmpty else { hasLoaded = true; return }
        isLoading = true
        error = nil
        let expected = generation
        loadTask = Task { [weak self, fetch] in
            do {
                let messages = try await RecordingChatContents.load(files: files, fetch: fetch)
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.messages = messages
                self.hasLoaded = true
                self.isLoading = false
                self.loadTask = nil
                self.updateHighlight()
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.isLoading = false
                self.loadTask = nil
                self.error = error.localizedDescription
            }
        }
    }

    /// Zoom's chat clock starts at the meeting, not at the beginning of each MP4.
    func synchronize(playerTime: TimeInterval?, file: ZoomRecordingFile?, duration: TimeInterval?) {
        guard let meeting, let file, let playerTime, playerTime.isFinite else {
            meetingTime = nil
            self.duration = nil
            activeMessageIDs = []
            scrollTargetID = nil
            timingNotice = nil
            return
        }
        fileStart = max(0, (file.recordingStart ?? meeting.startTime).timeIntervalSince(meeting.startTime))
        self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        meetingTime = fileStart + max(0, playerTime)
        if let start = file.recordingStart, let end = file.recordingEnd, let duration = self.duration,
           end.timeIntervalSince(start) - duration > 5 {
            timingNotice = "Chat timing may differ where this recording was paused or edited."
        } else { timingNotice = nil }
        updateHighlight()
    }

    func playbackTime(for message: ZoomRecordingChatMessage) -> TimeInterval? {
        guard meetingTime != nil else { return nil }
        let time = message.offset - fileStart
        guard time >= 0, duration.map({ time < $0 }) ?? true else { return nil }
        return time
    }

    private func updateHighlight() {
        guard let time = meetingTime else { activeMessageIDs = []; scrollTargetID = nil; return }
        var low = 0
        var high = messages.count
        while low < high {
            let middle = (low + high) / 2
            if messages[middle].offset <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { activeMessageIDs = []; scrollTargetID = nil; return }
        let last = low - 1
        let timestamp = messages[last].offset
        var first = last
        while first > 0, messages[first - 1].offset == timestamp { first -= 1 }
        let active = Set(messages[first...last].map(\.id))
        if activeMessageIDs != active { activeMessageIDs = active }
        if scrollTargetID != messages[last].id { scrollTargetID = messages[last].id }
    }

    func adoptState(from other: RecordingChatModel) {
        guard meeting?.id == other.meeting?.id else { return }
        isPresented = other.isPresented
        followsPlayback = other.followsPlayback
        if other.hasLoaded {
            messages = other.messages
            hasLoaded = true
            hasChatFile = other.hasChatFile
            updateHighlight()
        } else if isPresented { load() }
    }

    func clear() {
        isPresented = false
        resetContent()
        meeting = nil
        preview = false
        hasChatFile = false
    }

    private func resetContent() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        messages = []
        hasLoaded = false
        isLoading = false
        error = nil
        meetingTime = nil
        activeMessageIDs = []
        scrollTargetID = nil
        followsPlayback = true
        timingNotice = nil
    }
}

/// Text parsing, hashing, deduplication, and ordering run away from the UI actor.
/// Only the complete, current result is published by RecordingChatModel.
private enum RecordingChatContents {
    @concurrent
    static func load(files: [ZoomRecordingFile],
                     fetch: @escaping @Sendable (ZoomRecordingFile) async throws -> String) async throws -> [ZoomRecordingChatMessage] {
        var merged: [ZoomRecordingChatMessage] = []
        var seen: Set<MessageOccurrence> = []
        for file in files {
            try Task.checkCancellation()
            let text = try await fetch(file)
            try Task.checkCancellation()
            let parsed = ZoomRecordingChatParser.parse(text)
            try Task.checkCancellation()
            if parsed.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw RecordingChatContentError.unreadable
            }
            var occurrences: [MessageContent: Int] = [:]
            for (index, message) in parsed.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                let content = MessageContent(message)
                let ordinal = occurrences[content, default: 0]
                occurrences[content] = ordinal + 1
                guard seen.insert(MessageOccurrence(content: content, ordinal: ordinal)).inserted else { continue }
                merged.append(.init(id: "\(file.id):\(message.id)", offset: message.offset,
                                    sender: message.sender, recipient: message.recipient, text: message.text))
            }
        }
        try Task.checkCancellation()
        // Explicit original positions keep equal-timestamp messages in transcript order.
        var comparisons = 0
        let ordered = try merged.enumerated().sorted {
            comparisons += 1
            if comparisons.isMultiple(of: 256) { try Task.checkCancellation() }
            return $0.element.offset == $1.element.offset ? $0.offset < $1.offset : $0.element.offset < $1.element.offset
        }
        var messages: [ZoomRecordingChatMessage] = []
        messages.reserveCapacity(ordered.count)
        for (index, entry) in ordered.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            messages.append(entry.element)
        }
        try Task.checkCancellation()
        return messages
    }
}

private struct MessageContent: Hashable {
    let offset: TimeInterval
    let sender: String
    let recipient: String?
    let text: String
    init(_ message: ZoomRecordingChatMessage) {
        offset = message.offset; sender = message.sender; recipient = message.recipient; text = message.text
    }
}
private struct MessageOccurrence: Hashable { let content: MessageContent; let ordinal: Int }
private enum RecordingChatContentError: Error, LocalizedError {
    case unreadable
    var errorDescription: String? { "This saved chat could not be read. Its timestamps may use an unsupported format." }
}
