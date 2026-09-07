import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhooshMeetings

struct RecordingTranscriptView: View {
    @Bindable var model: RecordingLibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var copied: UUID?
    @State private var exportError: String?

    private var transcript: RecordingTranscriptModel { model.transcript }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                searchControls(proxy)
                if let notice = transcript.timingNotice {
                    Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.bottom, 10)
                }
                Divider().opacity(0.4)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(transcript.cues) { cue in
                            cueRow(cue).id(cue.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 16)
                }
                .overlay { if transcript.cues.isEmpty { emptyState } }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting || phase == .tracking { transcript.followsPlayback = false }
                }
                .onChange(of: transcript.scrollTargetID) { _, _ in
                    if transcript.followsPlayback { scrollToPlayhead(proxy) }
                }
                .onChange(of: transcript.query) { _, query in
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        transcript.followsPlayback = false
                        if let id = transcript.currentMatchID { scroll(to: id, proxy: proxy) }
                    }
                }
                .onChange(of: transcript.currentMatchID) { _, id in
                    if !transcript.followsPlayback, let id { scroll(to: id, proxy: proxy) }
                }
                .onAppear {
                    if transcript.followsPlayback { scrollToPlayhead(proxy, animated: false) }
                    else if let id = transcript.currentMatchID { scroll(to: id, proxy: proxy, animated: false) }
                }
                .accessibilityLabel("Recorded meeting transcript")

                if !transcript.cues.isEmpty { footer(proxy) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WhooshWindowInteractionRegion())
        .onAppear { transcript.setPresented(true) }
        .onDisappear { transcript.setPresented(false) }
        .task(id: copied) {
            guard copied != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = nil
        }
        .alert("Couldn’t save transcript", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private func searchControls(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                TextField("Search transcript", text: Binding(get: { transcript.query }, set: { transcript.query = $0 }))
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .accessibilityLabel("Search transcript")
                    .onSubmit { navigateMatch(forward: true, proxy: proxy) }
                if !transcript.query.isEmpty {
                    Button { transcript.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).whooshIconHover(cornerRadius: 6)
                    .accessibilityLabel("Clear transcript search")
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            if !transcript.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 4) {
                    Text(transcript.matchCount == 0 ? "No matches" : "\(transcript.currentMatchIndex) of \(transcript.matchCount) passages")
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    matchButton("Previous match", icon: "chevron.up") { navigateMatch(forward: false, proxy: proxy) }
                    matchButton("Next match", icon: "chevron.down") { navigateMatch(forward: true, proxy: proxy) }
                }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    private func matchButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 24).contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).whooshIconHover(cornerRadius: 6)
        .disabled(transcript.matchCount == 0).help(title).accessibilityLabel(title)
    }

    private func navigateMatch(forward: Bool, proxy: ScrollViewProxy) {
        let cue = forward ? transcript.selectNextMatch() : transcript.selectPreviousMatch()
        guard let cue else { return }
        scroll(to: cue.id, proxy: proxy)
        model.seekToTranscriptCue(cue, followingPlayback: false)
    }

    private func cueRow(_ cue: ZoomRecordingTranscriptCue) -> some View {
        let active = transcript.activeCueIDs.contains(cue.id)
        let match = transcript.currentMatchID == cue.id
        let canSeek = !model.isPreparing && transcript.playbackTime(for: cue) != nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let speaker = cue.speaker, !speaker.isEmpty {
                    Text(highlighted(speaker)).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(1).help(speaker)
                }
                Spacer(minLength: 4)
                Button(timestamp(cue.start)) { model.seekToTranscriptCue(cue) }
                    .buttonStyle(.plain).font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(active ? WhooshTheme.accent : .secondary)
                    .padding(.vertical, 3).contentShape(Rectangle())
                    .disabled(!canSeek)
                    .accessibilityLabel("Passage at \(timestamp(cue.start))")
                    .help(canSeek ? "Jump to this passage" : "This passage is outside the current video or the video is opening")
            }
            Text(highlighted(cue.text))
                .font(.system(size: 13)).foregroundStyle(.primary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if canSeek { model.seekToTranscriptCue(cue) } }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(active ? WhooshTheme.accent.opacity(colorScheme == .dark ? 0.20 : 0.10)
                      : Color.primary.opacity(match ? 0.06 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(active || match ? WhooshTheme.accent.opacity(contrast == .increased ? 0.9 : 0.5) : .clear,
                              lineWidth: 1).allowsHitTesting(false)
        }
        .contextMenu {
            Button("Copy passage", systemImage: "doc.on.doc") { copy(passageText(cue)) }
            Button("Jump to passage", systemImage: "play") { model.seekToTranscriptCue(cue) }.disabled(!canSeek)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func footer(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            HStack(spacing: 5) {
                if transcript.followsPlayback {
                    Label("Following playback", systemImage: "play.circle")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Button("Follow playback", systemImage: "play.circle") {
                        transcript.followsPlayback = true
                        scrollToPlayhead(proxy)
                    }
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                    .accessibilityHint("Scrolls to the passage at the current playback position")
                }
                Spacer(minLength: 0)
                Button { copy(transcript.transcriptText) } label: {
                    Image(systemName: copied == nil ? "doc.on.doc" : "checkmark")
                        .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).whooshIconHover(cornerRadius: 8)
                .help(copied == nil ? "Copy transcript" : "Copied")
                .accessibilityLabel("Copy transcript")
                Menu {
                    Button("Download text (.txt)") { saveTranscript(asVTT: false) }
                    Button("Download WebVTT (.vtt)") { saveTranscript(asVTT: true) }
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
                .whooshIconHover(cornerRadius: 8).help("Download transcript").accessibilityLabel("Download transcript")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 10) {
            if transcript.isLoading {
                ProgressView().controlSize(.small)
                Text("Loading transcript…").font(.system(size: 13)).foregroundStyle(.secondary)
            } else if let error = transcript.error {
                Image(systemName: "exclamationmark.bubble").font(.system(size: 27, weight: .ultraLight)).foregroundStyle(.tertiary)
                Text("Couldn’t load transcript").font(.system(size: 13, weight: .medium))
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Retry") { transcript.retry() }.buttonStyle(.bordered).controlSize(.small)
            } else {
                Image(systemName: "text.alignleft").font(.system(size: 27, weight: .ultraLight)).foregroundStyle(.tertiary)
                Text(transcript.hasTranscriptFile ? "No spoken passages" : "No transcript available")
                    .font(.system(size: 13, weight: .medium))
                Text(transcript.hasTranscriptFile
                     ? "This transcript has no spoken passages to show."
                     : "Zoom hasn’t provided an audio transcript for this recording. It may still be processing, or transcription wasn’t enabled.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let query = transcript.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return result }
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: result),
               let upper = AttributedString.Index(range.upperBound, within: result) {
                result[lower..<upper].backgroundColor = Color.yellow.opacity(colorScheme == .dark ? 0.3 : 0.4)
            }
            start = range.upperBound
        }
        return result
    }

    private func scrollToPlayhead(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if let id = transcript.scrollTargetID ?? transcript.cues.first?.id { scroll(to: id, proxy: proxy, animated: animated) }
    }

    private func scroll(to id: String, proxy: ScrollViewProxy, animated: Bool = true) {
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
        } else { proxy.scrollTo(id, anchor: .center) }
    }

    private func timestamp(_ time: TimeInterval) -> String {
        let seconds = time.isFinite ? Int(max(0, min(time, Double(Int.max / 2)))) : 0
        return [seconds / 3_600, (seconds / 60) % 60, seconds % 60]
            .map { String(format: "%02d", $0) }.joined(separator: ":")
    }

    private func passageText(_ cue: ZoomRecordingTranscriptCue) -> String {
        "[\(timestamp(cue.start))] " + (cue.speaker.map { "\($0): " } ?? "") + cue.text
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) { copied = UUID() }
    }

    private func saveTranscript(asVTT: Bool) {
        let text = asVTT ? transcript.transcriptVTT : transcript.transcriptText
        let panel = NSSavePanel()
        panel.title = "Save transcript"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [asVTT ? (UTType(filenameExtension: "vtt") ?? .plainText) : .plainText]
        let topic = (model.selectedMeeting?.topic ?? "Recording")
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
        panel.nameFieldStringValue = String(topic.prefix(120)) + " transcript." + (asVTT ? "vtt" : "txt")
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do { try await RecordingTranscriptExport.write(text, to: url) }
                catch { exportError = error.localizedDescription }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

private enum RecordingTranscriptExport {
    @concurrent static func write(_ text: String, to url: URL) async throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
