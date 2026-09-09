import SwiftUI
import AppKit
import YapCalendar
import YapMeetings
import YapSystem

public struct YapRootView: View {
    @Bindable var model: YapModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let applicationDelegate: YapApplicationDelegate?
    public init(model: YapModel, applicationDelegate: YapApplicationDelegate? = nil) {
        self.model = model
        self.applicationDelegate = applicationDelegate
    }

    public var body: some View {
        Group {
            if model.activeCall { MeetingView(model: model) }
            else { TodayView(model: model) }
        }
        .frame(minWidth: model.recordings.isPresented && !model.activeCall ? 700 : 320, minHeight: 240)
        .tint(YapTheme.accent)
        .navigationTitle(windowTitle)
        .background {
            if !reduceTransparency {
                YapWindowBackdrop().ignoresSafeArea()
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .background(WindowBehavior(model: model, title: windowTitle,
                                   showsCloseButton: !model.activeCall || model.areMeetingControlsVisible))
        .containerBackground(windowBackground, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar(removing: .title)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isPreview {
                HStack {
                    Text("Preview · no live connection")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !model.activeCall {
                        Button("Exit preview") { Task { await model.exitPreview() } }
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(.thinMaterial)
            }
        }
        .onChange(of: model.showSettings, initial: true) { _, requested in
            guard requested else { return }
            model.showSettings = false
            openSettings()
            NSApplication.shared.activate()
        }
        .onChange(of: model.activeCall) { _, active in
            if active { model.recordings.dismiss() }
        }
        .sheet(isPresented: $model.showJoinSheet) { JoinMeetingSheet(model: model) }
        .confirmationDialog(model.meeting.isHost ? "Leave or end this meeting?" : "Leave this meeting?", isPresented: $model.showLeaveConfirmation, titleVisibility: .visible) {
            Button("Leave meeting", role: .destructive) { Task { await model.leaveMeeting() } }
            if model.meeting.isHost { Button("End for everyone", role: .destructive) { Task { await model.leaveMeeting(endForEveryone: true) } } }
            Button("Stay", role: .cancel) {}
        } message: { Text(model.meeting.isHost ? "Ending the meeting disconnects everyone. Leaving keeps it open when Zoom allows a host handoff." : "Your microphone, camera, and sharing will stop.") }
        .alert("Yap", isPresented: Binding(get: { model.error != nil || model.meeting.lastError != nil }, set: { if !$0 { model.error = nil; model.meeting.dismissError() } })) {
            ZoomSignInButton(error: model.error ?? model.meeting.lastError ?? "",
                             recovery: model.recordings.zoomSignInRecovery)
            Button("OK", role: .cancel) { model.error = nil; model.meeting.dismissError() }
        } message: { Text(model.error ?? model.meeting.lastError ?? "") }
        .alert("Open in Zoom Workplace?", isPresented: Binding(
            get: { model.unsupportedZoomLink != nil },
            set: { if !$0 { model.unsupportedZoomLink = nil } }
        ), presenting: model.unsupportedZoomLink) { url in
            Button("Open Zoom Workplace") {
                Task {
                    do { try await ZoomLinkHandlerService().openInZoom(url) }
                    catch { model.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This link uses a Zoom feature that Yap doesn’t support yet. You can open it in the official app.")
        }
        .onAppear {
            applicationDelegate?.configure(model: model, openMainWindow: { openWindow(id: "main") })
        }
        .task { if applicationDelegate == nil { await model.start() } }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in Task { await model.refreshOnForeground() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.refreshOnForeground() } }
    }

    private var windowBackground: AnyShapeStyle {
        if reduceTransparency { return AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) }
        // The explicit native backdrop is shared by the agenda and meeting.
        // A second window material would cover its desktop sampling.
        return AnyShapeStyle(Color.clear)
    }

    private var windowTitle: String {
        if model.activeCall {
            return model.meeting.displayTitle
        }
        if model.recordings.isPresented { return "Recordings" }
        return model.isPreview ? "Agenda Preview" : "Agenda"
    }
}

struct TodayView: View {
    @Bindable var model: YapModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct RecordingPresentation: Equatable {
        let isAvailable: Bool
        let accountRevision: UUID
    }

    private var recordingPresentation: RecordingPresentation {
        RecordingPresentation(
            isAvailable: model.recordings.isPresented && !model.isPreview && !model.zoomConnection.isBusy,
            accountRevision: model.zoomConnection.accountRevision)
    }

    var body: some View {
        GeometryReader { available in
            let compact = available.size.width < 560
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let upcoming = AgendaRules.upcoming(model.events, now: context.date)
                HStack(spacing: 0) {
                    if model.recordings.isPresented {
                        VStack(spacing: 0) {
                            windowHeader
                            RecordingSidebar(model: model.recordings, connection: model.zoomConnection,
                                             isPreview: model.isPreview, openSettings: { model.showSettings = true })
                        }
                        .frame(width: 260)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        Divider()
                        RecordingPlayerView(model: model.recordings)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 0) {
                            windowHeader
                            ScrollView {
                                VStack(alignment: .leading, spacing: compact ? 18 : 28) {
                                    if let next = upcoming.first {
                                        nextMeetingCard(next, now: context.date, compact: compact)
                                        let items = Array(upcoming.dropFirst().prefix(8))
                                        if !items.isEmpty { agenda(items, now: context.date, compact: compact) }
                                    } else if model.isCalendarConnected {
                                        emptyAgenda
                                    } else {
                                        welcome(compact: compact)
                                    }
                                }
                                .padding(.horizontal, compact ? 16 : 24)
                                .padding(.top, compact ? 4 : 12)
                                .padding(.bottom, compact ? 16 : 24)
                                .frame(maxWidth: 960)
                                .frame(maxWidth: .infinity)
                            }
                            .scrollEdgeEffectStyle(.soft, for: .top)
                            .background(Color.clear)
                        }
                    }
                }
                .clipped()
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .task(id: recordingPresentation) {
            guard recordingPresentation.isAvailable else { return }
            await model.recordings.refreshForPresentation()
        }
        .onDisappear { model.recordings.suspendPlayback() }
    }

    private var windowHeader: some View {
        HStack {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
                    model.recordings.toggle()
                }
            } label: {
                Label("Recordings", systemImage: "sidebar.left")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(model.recordings.isPresented ? YapTheme.accent.opacity(0.15) : .clear, in: Capsule())
                    .foregroundStyle(model.recordings.isPresented ? YapTheme.accent : .primary)
            }
            .buttonStyle(.plain)
            .yapIconHover(isSelected: model.recordings.isPresented, cornerRadius: 100)
            .accessibilityLabel("Recordings")
            .accessibilityValue(model.recordings.isPresented ? "Open" : "Closed")
            .help("Show or hide recordings · ⇧⌘R")
            .background(YapWindowInteractionRegion(isEnabled: true))
            Spacer(minLength: 0)
            if !model.recordings.isPresented {
                meetingActions
                    .background(YapWindowInteractionRegion(isEnabled: true))
            }
        }
        .frame(minHeight: 36)
        .padding(.leading, 52)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .overlay(YapWindowDragSurface())
    }

    private var meetingActions: some View {
        ViewThatFits(in: .horizontal) {
            meetingActionRow(iconOnly: false)
            meetingActionRow(iconOnly: true)
        }
    }

    private func meetingActionRow(iconOnly: Bool) -> some View {
        Group {
            if iconOnly { meetingActionButtons.labelStyle(.iconOnly) }
            else { meetingActionButtons.labelStyle(.titleAndIcon) }
        }
        .controlSize(iconOnly ? .regular : .large)
        .buttonBorderShape(.capsule)
        .fixedSize()
    }

    private var meetingActionButtons: some View {
        HStack(spacing: 8) {
            Button { Task { await model.hostMeeting() } } label: {
                Label {
                    HStack(spacing: 10) {
                        Text("Start new meeting")
                        Text("⇧⌘N").font(.system(size: 11, weight: .medium)).opacity(0.7).accessibilityHidden(true)
                    }
                } icon: { Image(systemName: "plus") }
                .foregroundStyle(.white)
            }
            .buttonStyle(.glassProminent)
            .yapIconHover(cornerRadius: 100)
            .help("Start new meeting · ⇧⌘N")
            .accessibilityLabel("Start new meeting")
            Button("Join with a link…", systemImage: "link") {
                model.selectedEvent = nil
                model.joinLink = ""
                model.showJoinSheet = true
            }
            .buttonStyle(.glass)
            .yapIconHover(cornerRadius: 100)
            .tint(nil as Color?)
            .foregroundStyle(.primary)
            .help("Join with a link · ⌘J")
            .accessibilityLabel("Join with a link")
        }
    }

    private func nextMeetingCard(_ event: CalendarEvent, now: Date, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 16 : 22) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Up Next", systemImage: "video")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(YapTheme.accent)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                Text(AgendaPresentation.startLabel(for: event, now: now))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing).lineLimit(2)
            }
            VStack(alignment: .leading, spacing: compact ? 7 : 9) {
                Text(event.title).font(.system(size: compact ? 22 : 28, weight: .semibold))
                    .tracking(-0.5).lineLimit(compact ? 3 : 2)
                if compact {
                    VStack(alignment: .leading, spacing: 4) {
                        meetingTime(event)
                        Text(event.calendarName).lineLimit(1).help(event.calendarName)
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        meetingTime(event)
                        Text("·")
                        Text(event.calendarName).lineLimit(1).help(event.calendarName)
                    }.font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            if AgendaRules.showsJoinButton(for: event, now: now) {
                if compact {
                    VStack(alignment: .leading, spacing: 12) {
                        joiningDetails
                        joinNextButton(event).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    HStack(alignment: .bottom) {
                        joiningDetails
                        Spacer()
                        joinNextButton(event)
                    }
                }
            }
        }
        .padding(compact ? 16 : 28)
        .cardSurface()
    }

    private func meetingTime(_ event: CalendarEvent) -> some View {
        HStack(spacing: 6) {
            Text(event.startDate, style: .time)
            Text("–")
            Text(event.endDate, style: .time)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var joiningDetails: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Joining as \(model.displayName)")
                .font(.system(size: 12, weight: .medium)).lineLimit(2)
            Label("Camera off · microphone muted", systemImage: "mic.slash")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func joinNextButton(_ event: CalendarEvent) -> some View {
        Button { Task { await model.joinNextCalendarMeeting(expectedEventID: event.id) } } label: {
            HStack(spacing: 14) {
                Text(model.isPreview ? "Preview meeting" : "Join meeting")
                Text("⌘↵").font(.system(size: 12, weight: .medium)).opacity(0.7).accessibilityHidden(true)
            }
            .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 9)
        }
        .buttonStyle(.glassProminent).buttonBorderShape(.capsule)
        .keyboardShortcut(.return, modifiers: [.command])
    }

    private func welcome(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 18 : 24) {
            HStack(spacing: compact ? 12 : 18) {
                YapMark(size: compact ? 38 : 60)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Yap")
                        .font(.system(size: compact ? 19 : 22, weight: .semibold))
                    Text("For people who professionally yap for a living.")
                        .font(.system(size: compact ? 12 : 14)).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(alignment: .top, spacing: 18) {
                if !compact {
                    Image(systemName: "calendar").font(.system(size: 24, weight: .light))
                        .foregroundStyle(YapTheme.accent).frame(width: 40)
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("Bring your day into view").font(.system(size: 15, weight: .semibold))
                    Text("Connect Google Calendar to see what’s coming up and join your Zoom meetings from here.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button { Task { await model.connectGoogle() } } label: {
                        HStack(spacing: 8) {
                            if model.isConnecting { ProgressView().controlSize(.small) }
                            Text(model.isConnecting ? "Waiting for Google…" : "Connect Google Calendar")
                                .fixedSize(horizontal: false, vertical: true)
                            if !model.isConnecting { Image(systemName: "arrow.right") }
                        }.padding(.horizontal, compact ? 4 : 10).padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent).buttonBorderShape(.capsule).disabled(model.isConnecting)
                    Text("Read-only access. You choose which calendars appear.").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }.padding(compact ? 16 : 28).cardSurface()
    }

    private var emptyAgenda: some View {
        Text("No upcoming Zoom meetings")
            .font(.body).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
    }

    private func agenda(_ items: [CalendarEvent], now: Date, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Upcoming Meetings").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.mini) }
            }
            VStack(spacing: 0) {
                ForEach(items) { event in
                    HStack(spacing: compact ? 10 : 16) {
                        if !compact {
                            RoundedRectangle(cornerRadius: 2).fill(YapTheme.accent.opacity(0.65)).frame(width: 3, height: 32)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title).font(.system(size: compact ? 13 : 14, weight: .medium))
                                .lineLimit(compact ? 2 : 1)
                            Text(event.calendarName).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).help(event.calendarName)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(event.startDate, style: .time).font(.system(size: 12, weight: .medium))
                                .monospacedDigit().fixedSize()
                            if let dateLabel = AgendaPresentation.dateLabel(for: event.startDate, now: now) {
                                Text(dateLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1).help(dateLabel)
                            }
                        }
                        .frame(maxWidth: compact ? 92 : nil, alignment: .trailing)
                        if AgendaRules.showsJoinButton(for: event, now: now) {
                            Button { Task { await model.joinNextCalendarMeeting(expectedEventID: event.id) } } label: {
                                Image(systemName: "arrow.up.right")
                                    .frame(width: 32, height: 32).contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless).yapIconHover()
                            .accessibilityLabel("Join \(event.title)").help("Join \(event.title)")
                        }
                    }.padding(.vertical, 13)
                    if event.id != items.last?.id { Divider().padding(.leading, compact ? 0 : 19) }
                }
            }
        }
    }
}

struct JoinMeetingSheet: View {
    @Bindable var model: YapModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case link, name }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.selectedEvent?.title ?? "Join a meeting").font(.title2).fontWeight(.semibold)
            Text("Paste your Zoom invitation link. You’ll join with your camera off and microphone muted.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let event = model.selectedEvent, AgendaRules.meetingURLs(for: event).count > 1 {
                Text("This invitation has multiple Zoom links. Choose the intended meeting.").font(.callout)
                ForEach(AgendaRules.meetingURLs(for: event), id: \.absoluteString) { url in
                    Button(url.host().map { "\($0) · \(url.lastPathComponent)" } ?? "Zoom meeting") { model.joinLink = url.absoluteString }
                }
            }
            TextField("Zoom meeting link", text: $model.joinLink).textFieldStyle(.roundedBorder).controlSize(.large)
                .focused($focusedField, equals: .link)
                .accessibilityLabel("Zoom meeting link")
                .accessibilityIdentifier("join-link-field")
            TextField("Your name", text: $model.displayName).textFieldStyle(.roundedBorder).controlSize(.large)
                .focused($focusedField, equals: .name)
                .accessibilityLabel("Your name")
            if let message = model.joinInputError {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("join-input-error")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.isPreview ? "Join preview" : "Join meeting") { Task { await model.joinPastedLink() } }
                    .buttonStyle(.glassProminent)
                    .disabled(model.joinLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(30).frame(width: 460).tint(YapTheme.accent)
        .onAppear { focusedField = .link }
    }
}

public enum YapDeepLink {
    static func isOpenAppURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "yap" && parts.host?.lowercased() == "open"
            && parts.path.isEmpty && parts.user == nil && parts.password == nil && parts.port == nil
            && parts.query == nil && parts.fragment == nil
    }

    public static func meetingURL(from url: URL) -> URL? {
        // Keep invitations saved before the rename usable, with the same strict
        // meeting URL validation as newly generated Yap links.
        guard ["yap", "whoosh", "zooom"].contains(url.scheme?.lowercased() ?? "") else {
            return ZoomMeetingLinkParser.normalizedJoinURL(url.absoluteString)
        }
        guard url.host?.lowercased() == "join", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              parts.path.isEmpty else { return nil }
        let values = (parts.queryItems ?? []).filter { $0.name == "url" }
        guard values.count == 1, let value = values.first?.value else { return nil }
        return ZoomMeetingLinkParser.normalizedJoinURL(value)
    }

    /// Unsupported Zoom actions may be handed to the official app explicitly.
    /// Never send an arbitrary scheme or a disguised third-party host there.
    static func isZoomApplicationURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["zoommtg", "zoomus"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil,
              let host = parts.host?.lowercased() else { return false }
        return host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "zoom.com" || host.hasSuffix(".zoom.com")
    }
}
