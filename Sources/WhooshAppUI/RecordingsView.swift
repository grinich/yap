import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import WhooshMeetings

struct RecordingSidebar: View {
    @Bindable var model: RecordingLibraryModel
    @Bindable var connection: ZoomConnectionModel
    let isPreview: Bool
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recordings").font(.system(size: 20, weight: .semibold))
                    Text("Your Zoom cloud library").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain).padding(6)
                .disabled(model.isLoading || isPreview || connection.isBusy)
                .help("Refresh recordings").accessibilityLabel("Refresh recordings")
                .background(WhooshWindowInteractionRegion())
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 18)
            .overlay(WhooshWindowDragSurface())

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search recordings", text: $model.search)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .accessibilityLabel("Search loaded recordings")
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }
            .padding(9).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 14).padding(.bottom, 12)
            .background(WhooshWindowInteractionRegion())

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.filteredMeetings) { meeting in
                        recordingRow(meeting)
                    }
                    if model.filteredMeetings.isEmpty, !model.isLoading {
                        if isPreview {
                            sidebarMessage("Connect to your library", detail: "Exit preview to browse your Zoom cloud recordings.")
                        } else if model.error == nil {
                            sidebarMessage(model.search.isEmpty ? "No recordings in this period" : "No matching recordings",
                                           detail: model.search.isEmpty ? "Try loading an earlier month. Recordings appear here after Zoom finishes processing them." : "Search covers the recordings loaded so far.")
                        }
                    }
                    if let error = model.error {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Couldn’t load recordings", systemImage: "exclamationmark.circle")
                                .font(.system(size: 12, weight: .medium))
                            Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            HStack {
                                Button("Retry") {
                                    Task {
                                        if model.hasLoadedInitial { await model.loadOlder() }
                                        else { await model.loadInitial() }
                                    }
                                }
                                Button("Zoom settings", action: openSettings)
                            }.controlSize(.small)
                        }
                        .padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 6).padding(.vertical, 12)
                    }
                    if model.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading recordings…").font(.system(size: 12)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 22)
                    }
                    if !isPreview, model.oldestLoadedDate != nil, model.error == nil {
                        Button { Task { await model.loadOlder() } } label: {
                            Label("Load earlier month", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 12)).frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(model.isLoading || connection.isBusy).padding(.top, 10)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 20)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .background(WhooshWindowInteractionRegion())
            Spacer(minLength: 0)
            if let since = model.oldestLoadedDate {
                Text("\(model.meetings.count) recordings · since \(since.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
        .background(.quaternary.opacity(0.12))
    }

    private func sidebarMessage(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(.horizontal, 12).padding(.vertical, 20)
    }

    private func recordingRow(_ meeting: ZoomRecordingMeeting) -> some View {
        let selected = model.selectedMeeting?.id == meeting.id
        let count = meeting.playableVideoFiles.count
        return Button { model.selectFromList(meeting) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: count > 0 ? "play.rectangle" : "clock")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(selected ? WhooshTheme.accent : .secondary)
                    .frame(width: 24, height: 27)
                VStack(alignment: .leading, spacing: 6) {
                    Text(meeting.topic.isEmpty ? "Untitled meeting" : meeting.topic)
                        .font(.system(size: 12, weight: .medium)).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(meeting.startTime.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(count == 0 ? "No video available" : "\(meeting.duration) min\(count > 1 ? " · \(count) videos" : "")")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? WhooshTheme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.openPlayerWindow(for: meeting)
        })
        .contextMenu {
            Button("Open in New Window", systemImage: "macwindow") {
                model.openPlayerWindow(for: meeting)
            }
            Button("Copy link", systemImage: "link") {
                RecordingSharing.copyLink(for: meeting)
            }
            .disabled(meeting.shareableURL == nil)
        }
        .help("Double-click to open in a new window")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text("Open in New Window")) {
            model.openPlayerWindow(for: meeting)
        }
    }
}

struct RecordingPlayerView: View {
    @Bindable var model: RecordingLibraryModel
    private let headerHeight: CGFloat = 100
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copiedLink: UUID?

    var body: some View {
        Group {
            if let meeting = model.selectedMeeting {
                GeometryReader { geometry in
                    let overlaysChat = geometry.size.width < 660
                    let chatWidth = max(0, min(300, geometry.size.width - 32))
                    HStack(spacing: 0) {
                        playerContent(meeting)
                            .padding(.top, headerHeight)
                        if model.chat.isPresented && !overlaysChat {
                            chatPane(width: chatWidth)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if model.chat.isPresented && overlaysChat {
                            chatPane(width: chatWidth)
                        }
                    }
                    .overlay(alignment: .top) { playerHeader(meeting, chatWidth: chatWidth) }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: model.chat.isPresented)
                }
                .clipped()
            } else {
                emptyPlayer(title: "Pick a recording", subtitle: "Your meetings, ready to replay. Select a recording from the library to start watching.")
                    .overlay(alignment: .top) {
                        WhooshWindowDragSurface().frame(height: headerHeight)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RecordingPlaybackKeyboardShortcuts(model: model))
        .task(id: copiedLink) {
            guard copiedLink != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copiedLink = nil
        }
        .onChange(of: model.selectedMeeting?.id) { _, _ in copiedLink = nil }
    }

    private func playerHeader(_ meeting: ZoomRecordingMeeting, chatWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 12) {
                    Text(meeting.topic.isEmpty ? "Untitled meeting" : meeting.topic)
                        .font(.system(size: 18, weight: .semibold)).lineLimit(1)
                        .help(meeting.topic.isEmpty ? "Untitled meeting" : meeting.topic)
                    recordingActions(meeting)
                        .fixedSize()
                        .background(WhooshWindowInteractionRegion())
                }
                Text(meeting.startTime.formatted(date: .long, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                if model.chat.isPresented {
                    Text("Chat")
                        .font(.headline).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                        .frame(height: 32)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    Spacer(minLength: 0)
                }
                Toggle(isOn: Binding(get: { model.chat.isPresented }, set: { model.chat.setPresented($0) })) {
                    Label("Chat", systemImage: "bubble")
                }
                .toggleStyle(.button).labelStyle(.iconOnly).buttonStyle(.borderless)
                .frame(width: 32, height: 32)
                .background(model.chat.isPresented ? Color.primary.opacity(0.09) : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .tint(nil as Color?).foregroundStyle(.primary)
                .help("\(model.chat.isPresented ? "Hide" : "Show") chat")
                .background(WhooshWindowInteractionRegion())
            }
            // Match the transcript’s leading inset inside the actual chat pane.
            .frame(width: model.chat.isPresented ? max(32, chatWidth - 14 - 24) : 32)
        }
        .padding(24)
        .frame(height: headerHeight)
        .overlay(WhooshWindowDragSurface())
    }

    private func recordingActions(_ meeting: ZoomRecordingMeeting) -> some View {
        HStack(spacing: 12) {
            Button(copiedLink == nil ? "Copy link" : "Link copied", systemImage: copiedLink == nil ? "link" : "checkmark") {
                if RecordingSharing.copyLink(for: meeting) { copiedLink = UUID() }
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
            .frame(width: 32, height: 32)
            .foregroundStyle(.primary)
            .disabled(meeting.shareableURL == nil)
            .help(meeting.shareableURL == nil ? "No sharing link is available for this recording" : "Copy recording link")
            if model.selectedFile != nil, !model.isPreview {
                Button("Save video…", systemImage: "arrow.down.to.line", action: saveVideo)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .frame(width: 32, height: 32).foregroundStyle(.primary)
                    .disabled(model.isDownloading).help("Save video to your Mac")
            }
        }
    }

    private func chatPane(width: CGFloat) -> some View {
        RecordingChatView(model: model)
            // Like live meeting chat, the glass extends behind the shared
            // header, whose trailing toggle is the sole open/close control.
            .padding(.top, headerHeight)
            .whooshGlassSurface(cornerRadius: 22)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(width: width)
            .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func playerContent(_ meeting: ZoomRecordingMeeting) -> some View {
        VStack(spacing: 0) {
            if model.isPreview {
                emptyPlayer(title: "Recording preview", subtitle: "These are sample meetings. Exit preview and connect Zoom to watch your own cloud recordings.")
            } else if !meeting.playableVideoFiles.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        videoPicker(meeting)
                        speedPicker
                    }
                    VStack(spacing: 10) {
                        videoPicker(meeting)
                        speedPicker
                    }
                }
                .background(WhooshWindowInteractionRegion())
                .padding(.horizontal, 24).padding(.bottom, 16)
                ZStack {
                    NativeRecordingPlayer(player: model.player)
                        .background(.black)
                    if model.isPreparing {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text("Opening recording…").font(.system(size: 12))
                        }
                        .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let error = model.playbackError {
                        VStack(spacing: 14) {
                            Image(systemName: "arrow.down.circle").font(.system(size: 28, weight: .light))
                            Text(error).font(.system(size: 12)).multilineTextAlignment(.center)
                            Button("Download to play") { model.downloadSelected() }
                                .buttonStyle(.borderedProminent).disabled(model.isDownloading)
                        }
                        .padding(24).frame(maxWidth: 320)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    } else if model.selectedFile == nil {
                        if model.playerWindows[meeting.id] != nil {
                            VStack(spacing: 12) {
                                Text("Open in a separate window").foregroundStyle(.secondary)
                                Button("Show player window", systemImage: "arrow.up.right.square") {
                                    model.openPlayerWindow(for: meeting)
                                }.buttonStyle(.borderedProminent)
                            }
                        } else {
                            Button("Play recording", systemImage: "play.fill") {
                                if let file = meeting.playableVideoFiles.first { model.play(file) }
                            }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                .background(WhooshWindowInteractionRegion())
                .aspectRatio(model.videoAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24).padding(.bottom, 16)
                downloadStatus.padding(.horizontal, 24).padding(.bottom, 20)
            } else {
                emptyPlayer(title: "No video available yet", subtitle: "Zoom may still be processing this meeting, or it was recorded as audio only. Refresh the library to check again.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func videoPicker(_ meeting: ZoomRecordingMeeting) -> some View {
        if meeting.playableVideoFiles.count > 1 {
            Picker("Video", selection: Binding(get: { model.selectedFile?.id ?? "" }, set: { id in
                if let file = meeting.playableVideoFiles.first(where: { $0.id == id }) { model.play(file) }
            })) {
                if model.selectedFile == nil { Text("Choose a video").tag("") }
                ForEach(meeting.playableVideoFiles) { file in
                    Text(RecordingFilePresentation.label(for: file, among: meeting.playableVideoFiles)).tag(file.id)
                }
            }
            .pickerStyle(.menu).font(.system(size: 12))
        }
    }

    private var speedPicker: some View {
        Picker("Speed", selection: Binding(get: { model.playbackSpeed }, set: { model.setPlaybackSpeed($0) })) {
            ForEach(RecordingLibraryModel.playbackSpeeds, id: \.self) { speed in
                Text(speed.formatted(.number.precision(.fractionLength(0...2))) + "×").tag(speed)
            }
            if !RecordingLibraryModel.playbackSpeeds.contains(model.playbackSpeed) {
                Text(model.playbackSpeed.formatted(.number.precision(.fractionLength(0...2))) + "×")
                    .tag(model.playbackSpeed)
            }
        }
        .pickerStyle(.menu).font(.system(size: 12)).fixedSize()
        .disabled(model.selectedFile == nil)
        .help("Playback speed").accessibilityLabel("Playback speed")
    }

    @ViewBuilder private var downloadStatus: some View {
        if model.isDownloading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Downloading video…").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancelDownload() }.controlSize(.small)
            }
        } else if let error = model.downloadError {
            Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
        } else if let url = model.downloadedFile {
            HStack {
                Label("Video saved", systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.controlSize(.small)
            }
        } else {
            Text("Cloud recording").font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func emptyPlayer(title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 21, weight: .medium))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 275)
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func saveVideo() {
        let panel = NSSavePanel()
        panel.title = "Save recording"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.mpeg4Movie]
        let topic = (model.selectedMeeting?.topic ?? "Recording")
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
        panel.nameFieldStringValue = String(topic.prefix(120)) + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.downloadSelected(to: url)
    }
}

enum RecordingFilePresentation {
    static func label(for file: ZoomRecordingFile, among files: [ZoomRecordingFile]) -> String {
        let matching = files.filter { $0.displayName == file.displayName }
        guard matching.count > 1, let index = matching.firstIndex(where: { $0.id == file.id }) else {
            return file.displayName
        }
        return "\(file.displayName) · Part \(index + 1)"
    }
}

@MainActor
private enum RecordingSharing {
    @discardableResult static func copyLink(for meeting: ZoomRecordingMeeting) -> Bool {
        guard let url = meeting.shareableURL else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

struct NativeRecordingPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.speeds = RecordingLibraryModel.playbackSpeeds.map {
            AVPlaybackSpeed(rate: $0, localizedName: $0.formatted(.number.precision(.fractionLength(0...2))) + "×")
        }
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 180))
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
