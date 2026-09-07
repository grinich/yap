import AppKit
import SwiftUI
import WhooshMeetings
import WhooshSystem

struct MeetingView: View {
    @Bindable var model: WhooshModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var showShareChooser = false
    @State private var copiedInvitation: URL?
    @State private var isPointerInside = false
    @State private var keyboardControlsActive = false
    @State private var isTrackingMenu = false
    @State private var participantSearch = ""
    @FocusState private var isParticipantSearchFocused: Bool

    private var meeting: MeetingCoordinator { model.meeting }
    private var focusedParticipant: MeetingParticipant? {
        meeting.visibleParticipants.first { $0.id == model.focusedParticipantID }
    }
    private var invitationToCopy: URL? {
        MeetingPresentationRules.invitationToCopy(meeting.invitationURL, isConnected: meeting.isConnected, isDemo: meeting.isDemo)
    }
    private var canManageWaitingRoom: Bool {
        meeting.isHost && meeting.capabilities.canAdmitParticipants
    }
    private var showsConnectionStage: Bool {
        !meeting.isConnected && meeting.participants.isEmpty && meeting.selectedReceivedShare == nil
    }
    private var showsControls: Bool {
        isPointerInside || keyboardControlsActive || voiceOverEnabled || isTrackingMenu ||
        showShareChooser || model.showLeaveConfirmation || !meeting.isConnected
    }

    private func copyInvitation(_ invitation: URL) {
        guard invitationToCopy == invitation else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(invitation.absoluteString, forType: .string) { copiedInvitation = invitation }
    }

    var body: some View {
        Group {
            if showsConnectionStage {
                VStack(spacing: 0) {
                    meetingHeader
                    connectionStage
                }
            } else {
                GeometryReader { available in
                    let compactWidth = available.size.width < 620
                    let compactHeight = available.size.height < 420
                    let inspectorWidth = min(320, max(280, available.size.width - 400))
                    let overlayInspector = compactWidth && model.sidebar != nil
                    let showsPager = meeting.pageCount > 1 && !(compactHeight && (meeting.selectedReceivedShare != nil || overlayInspector))
                    HStack(spacing: 0) {
                        participantCanvas(compactHeight: compactHeight)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .environment(\.colorScheme, .dark)
                            .overlay(alignment: .top) {
                                // Keep important meeting state readable without
                                // covering the adjacent conversation panel.
                                Group {
                                    if overlayInspector { EmptyView() }
                                    else if compactHeight && hasPersistentNotices {
                                        ScrollView { persistentNotices }
                                            .scrollBounceBehavior(.basedOnSize)
                                            .frame(maxHeight: max(40, available.size.height - (showsPager ? 194 : 150)))
                                    } else { persistentNotices }
                                }
                                .padding(.top, compactHeight ? 54 : 70)
                                .environment(\.colorScheme, .dark)
                            }
                            .overlay {
                                if compactWidth, let sidebar = model.sidebar {
                                    inspector(sidebar, compact: true)
                                        .padding(.bottom, showsPager ? 120 : 76)
                                        .environment(\.colorScheme, .dark)
                                        .transition(.move(edge: .trailing).combined(with: .opacity))
                                }
                            }
                            .overlay(alignment: .bottom) {
                                VStack(spacing: 10) {
                                    if showsPager {
                                        pageControls.padding(.horizontal, 14).padding(.vertical, 9)
                                            .whooshGlassSurface(cornerRadius: 20)
                                    }
                                    callControls
                                }
                                .padding(.horizontal, 14).padding(.bottom, 16)
                                .environment(\.colorScheme, .dark)
                                .modifier(MeetingChromeVisibility(isVisible: showsControls, reduceMotion: reduceMotion))
                            }
                            // Let the canvas continue beneath the inspector's
                            // rounded leading corners instead of exposing black.
                            .padding(.trailing, !compactWidth && model.sidebar != nil ? -22 : 0)
                        if !compactWidth, let sidebar = model.sidebar {
                            inspector(sidebar)
                                .frame(width: inspectorWidth)
                                .environment(\.colorScheme, .dark)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .background(Color.black)
                    .overlay(alignment: .top) {
                        meetingHeader
                            .background(LinearGradient(colors: [.black.opacity(0.56), .clear], startPoint: .top, endPoint: .bottom))
                            .modifier(MeetingChromeVisibility(isVisible: showsControls, reduceMotion: reduceMotion))
                        .environment(\.colorScheme, .dark)
                    }
                    .overlay(alignment: .topLeading) {
                        if model.sidebar == .people {
                            Text("People")
                                .font(.headline).foregroundStyle(.white)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.leading, compactWidth ? 54 : available.size.width - inspectorWidth + 16)
                                .padding(.top, 22)
                                .allowsHitTesting(false)
                                .transition(.opacity.combined(with: .move(edge: .trailing)))
                        }
                    }
                }
                .ignoresSafeArea()
            }
        }
        .background(WhooshWindowPointerPresence(onChange: { inside in
            isPointerInside = inside
            keyboardControlsActive = false
        }, onKeyboardActivity: { keyboardControlsActive = true }))
        .sheet(isPresented: $showShareChooser) { MeetingShareChooser(meeting: meeting) }
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: model.sidebar)
        .onChange(of: showsControls, initial: true) { _, visible in model.areMeetingControlsVisible = visible }
        .onDisappear { model.areMeetingControlsVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in isTrackingMenu = true }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in isTrackingMenu = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if notification.object as? NSWindow === model.sharingPresentation.mainWindow { keyboardControlsActive = false }
        }
        .onChange(of: meeting.pageIndex) { _, _ in
            if focusedParticipant == nil { model.focusedParticipantID = nil }
        }
        .onChange(of: meeting.sessionID) { _, _ in
            showShareChooser = false
            copiedInvitation = nil
        }
        .task(id: copiedInvitation) {
            guard copiedInvitation != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copiedInvitation = nil
        }
    }

    private var hasPersistentNotices: Bool {
        !meeting.meetingIndicators.isEmpty || meeting.sharing.target != nil ||
        (canManageWaitingRoom && !meeting.waitingRoomParticipants.isEmpty) || !meeting.isConnected
    }

    private var persistentNotices: some View {
        VStack(spacing: 0) {
            if !meeting.meetingIndicators.isEmpty { MeetingIndicatorsBar(meeting: meeting) }
            if let target = meeting.sharing.target { sharingBanner(target) }
            if canManageWaitingRoom && !meeting.waitingRoomParticipants.isEmpty { waitingRoomBanner }
            if !meeting.isConnected { connectionStatus }
        }
    }

    private var meetingHeader: some View {
        ViewThatFits(in: .horizontal) {
            meetingHeaderRow(showsTitle: true)
            meetingHeaderRow(showsTitle: false)
        }
    }

    private func meetingHeaderRow(showsTitle: Bool) -> some View {
        HStack(spacing: 10) {
            if showsTitle {
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.meetingTitle.isEmpty ? "Your meeting" : meeting.meetingTitle)
                    .font(.headline)
                    .lineLimit(1)
                if !showsConnectionStage {
                    Text("\(meeting.participants.count) \(meeting.participants.count == 1 ? "person" : "people")\(meeting.isHost ? " · You’re hosting" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 120, alignment: .leading)
            }
            Spacer(minLength: 12)
            if model.sidebar == .chat, !showsConnectionStage {
                Text("Chat")
                    .font(.headline).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            if let invitation = invitationToCopy {
                Button(copiedInvitation == invitation ? "Invite link copied" : "Copy invite link", systemImage: copiedInvitation == invitation ? "checkmark" : "link") {
                    copyInvitation(invitation)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .frame(width: 32, height: 32)
                .tint(nil as Color?).foregroundStyle(.primary)
                .help("Copy invite link")
            }
            if !showsConnectionStage {
                Menu {
                    if meeting.capabilities.canReceiveShare && !meeting.receivedShares.isEmpty {
                        Section("Shared content") {
                            ForEach(meeting.receivedShares) { share in
                                Button("View \(share.ownerName)’s screen", systemImage: "rectangle.on.rectangle") {
                                    model.focusedParticipantID = nil
                                    meeting.selectReceivedShare(share.id)
                                }
                            }
                            if meeting.selectedReceivedShare != nil {
                                Button("Show people", systemImage: "person.2") { meeting.selectReceivedShare(nil) }
                            }
                        }
                    }
                    if focusedParticipant != nil {
                        Button("Show everyone", systemImage: "square.grid.2x2") { model.focusedParticipantID = nil }
                        Divider()
                    }
                    Picker("People per page", selection: Binding(get: { model.gridLimit }, set: { model.updateGridLimit($0) })) {
                        ForEach([25, 49, 100], id: \.self) { count in
                            Text("Up to \(count)").tag(count)
                        }
                        Text("Show all").tag(0)
                    }
                    .pickerStyle(.inline)
                    if model.isPreview {
                        Section("Sample participants") {
                            ForEach([2, 6, 25, 49, 100], id: \.self) { count in
                                Button("\(count) people") {
                                    model.setPreviewPeople(count)
                                    if model.gridLimit != 0 { model.updateGridLimit(max(model.gridLimit, count)) }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "square.grid.2x2").font(.system(size: 15))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).fixedSize()
                .background(WhooshWindowInteractionRegion(isEnabled: showsControls))
                .tint(nil as Color?).foregroundStyle(.primary)
                .help("Meeting layout").accessibilityLabel("Meeting layout")
                .disabled(!meeting.isConnected)
                inspectorToggle("Chat", symbol: "bubble", sidebar: .chat)
                    .disabled(!meeting.isConnected)
                inspectorToggle("People", symbol: "person.2", sidebar: .people)
                    .disabled(!meeting.isConnected)
            }
        }
        .padding(.leading, 54).padding(.trailing, 16).padding(.top, 14).padding(.bottom, 16)
    }

    private func inspectorToggle(_ label: String, symbol: String, sidebar: MeetingSidebar) -> some View {
        Toggle(isOn: Binding(get: { model.sidebar == sidebar }, set: { model.sidebar = $0 ? sidebar : nil })) {
            Label(label, systemImage: symbol)
        }
        .toggleStyle(.button).labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .frame(width: 32, height: 32)
        .background(model.sidebar == sidebar ? Color.primary.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .tint(nil as Color?).foregroundStyle(.primary)
        .help("\(model.sidebar == sidebar ? "Hide" : "Show") \(label.lowercased())")
    }

    @ViewBuilder
    private func participantCanvas(compactHeight: Bool) -> some View {
        if meeting.capabilities.canReceiveShare, let share = meeting.selectedReceivedShare {
            GeometryReader { geometry in
                let stripHeight = min(90, max(40, geometry.size.height * 0.22))
                VStack(spacing: 12) {
                    ReceivedShareSurface(meeting: meeting, share: share)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !compactHeight && !meeting.visibleParticipants.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(meeting.visibleParticipants) { participant in
                                    participantTile(participant)
                                        .frame(width: stripHeight * 16 / 9, height: stripHeight)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .frame(height: stripHeight)
                    }
                }
            }
            // Shared documents keep their full bounds and their own toolbar;
            // unlike camera video, they must not sit beneath floating controls.
            .padding(.top, compactHeight ? 54 : 70)
            .padding(.bottom, compactHeight ? 76 : (meeting.pageCount > 1 ? 138 : 96))
            .padding(.horizontal, 12)
        } else if meeting.participants.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "video").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                Text("A little room for conversation.")
                    .font(.system(size: 20, weight: .medium))
                Text("People will appear here when they arrive.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if meeting.visibleParticipants.count == 1, let participant = meeting.visibleParticipants.first {
            participantTile(participant, immersive: true)
        } else if let focusedParticipant {
            GeometryReader { geometry in
                let stripHeight = min(90, max(40, geometry.size.height * 0.22))
                ZStack(alignment: .bottom) {
                    participantTile(focusedParticipant, focused: true, immersive: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !compactHeight && meeting.visibleParticipants.count > 1 {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(meeting.visibleParticipants.filter { $0.id != focusedParticipant.id }) { participant in
                                    participantTile(participant)
                                        .frame(width: stripHeight * 16 / 9, height: stripHeight)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .frame(height: stripHeight)
                        .padding(.horizontal, 16).padding(.bottom, meeting.pageCount > 1 ? 138 : 96)
                    }
                }
            }
        } else {
            MeetingTileLayout(spacing: meeting.visibleParticipants.count > 25 ? 6 : 10) {
                ForEach(meeting.visibleParticipants) { participant in participantTile(participant) }
            }
            .padding(6)
        }
    }

    private func participantTile(_ participant: MeetingParticipant, focused: Bool = false, immersive: Bool = false) -> some View {
        ParticipantTile(participant: participant, meeting: meeting, isFocused: focused,
                        allowsNativeVideo: !model.sharingPresentation.isPresenting,
                        fillsFrame: immersive, showsInfo: !immersive || showsControls)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture(count: 2) { pin(participant) }
            .contextMenu {
                Button(focused ? "Show everyone" : "Focus on \(participant.name)", systemImage: focused ? "square.grid.2x2" : "pin") { pin(participant) }
            }
            .accessibilityAction(named: focused ? "Show everyone" : "Focus on this person") { pin(participant) }
            .help(participant.name + (participant.isMuted ? " · Microphone muted" : " · Microphone on"))
    }

    private func pin(_ participant: MeetingParticipant) {
        meeting.selectReceivedShare(nil)
        if model.focusedParticipantID == participant.id { model.focusedParticipantID = nil; return }
        if let index = meeting.participants.firstIndex(where: { $0.id == participant.id }) {
            meeting.setPage(index / meeting.pageSize)
        }
        model.focusedParticipantID = participant.id
    }

    private var pageControls: some View {
        HStack(spacing: 16) {
            Button { meeting.setPage(meeting.pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(meeting.pageIndex == 0).accessibilityLabel("Previous participants")
            Text("\(meeting.pageIndex + 1) of \(meeting.pageCount)")
                .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            Button { meeting.setPage(meeting.pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(meeting.pageIndex + 1 >= meeting.pageCount).accessibilityLabel("Next participants")
        }
        .buttonStyle(.borderless)
        .tint(nil as Color?).foregroundStyle(.primary)
    }

    private var callControls: some View {
        ViewThatFits(in: .horizontal) {
            callControlRow(iconOnly: false).fixedSize()
            callControlRow(iconOnly: true).fixedSize()
        }
        .padding(8)
        .whooshGlassSurface(cornerRadius: 24)
        .accessibilityElement(children: .contain)
    }

    private func callControlRow(iconOnly: Bool) -> some View {
        HStack(spacing: 8) {
                callButton(
                    meeting.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone",
                    symbol: meeting.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
                    caption: meeting.isMicrophoneMuted ? "Mic off" : "Mic on", iconOnly: iconOnly
                ) { Task { await meeting.setMicrophoneMuted(!meeting.isMicrophoneMuted) } }
                .accessibilityValue(meeting.isMicrophoneMuted ? "Muted" : "On")
                .contextMenu {
                    Button("Microphone modes…", systemImage: "waveform") {
                        WhooshSystemMediaEffects.showMicrophoneModes()
                    }
                    .disabled(model.isPreview || !meeting.isConnected)
                }
                .disabled(!meeting.isConnected || meeting.isApplyingControl)
                callButton(
                    meeting.isCameraEnabled ? "Turn camera off" : "Turn camera on",
                    symbol: meeting.isCameraEnabled ? "video.fill" : "video.slash.fill",
                    caption: meeting.isCameraEnabled ? "Camera on" : "Camera off", iconOnly: iconOnly
                ) { Task { await meeting.setCameraEnabled(!meeting.isCameraEnabled) } }
                .accessibilityValue(meeting.isCameraEnabled ? "On" : "Off")
                .help("\(meeting.isCameraEnabled ? "Turn camera off" : "Turn camera on") · \(MeetingPresentationRules.videoQualityDescription(meeting.videoQuality))")
                .contextMenu {
                    Section("Video quality") {
                        Text(MeetingPresentationRules.videoQualityDescription(meeting.videoQuality))
                    }
                    Divider()
                    Button("Video effects…", systemImage: "camera.filters") {
                        WhooshSystemMediaEffects.showVideoEffects()
                    }
                    .disabled(model.isPreview || !meeting.isCameraEnabled)
                }
                .disabled(!meeting.isConnected || meeting.isApplyingControl)
                callButton(meeting.sharing.isSharing ? "Switch shared window or display" : "Choose a window or display to share", symbol: "rectangle.on.rectangle", caption: meeting.sharing.isSharing ? "Switch" : "Share", iconOnly: iconOnly) {
                    showShareChooser = true
                }
                .disabled(!meeting.isConnected || !meeting.capabilities.canShare || (!meeting.isDemo && !meeting.capabilities.canEnumerateShareTargets) || meeting.isApplyingControl)
                MeetingCloudRecordingCallControl(meeting: meeting, iconOnly: iconOnly)
                Divider().frame(height: 24).padding(.horizontal, 2)
                callButton("Leave meeting", symbol: "phone.down.fill", caption: "Leave", iconOnly: iconOnly, destructive: true) {
                    model.showLeaveConfirmation = true
                }
                .disabled(meeting.status == .leaving)
        }
    }

    @ViewBuilder
    private func callButton(_ label: String, symbol: String, caption: String, iconOnly: Bool, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        let button = Button(role: destructive ? .destructive : nil, action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                if !iconOnly { Text(caption) }
            }
            .frame(minWidth: iconOnly ? 24 : 0, minHeight: 22)
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .controlSize(.large)
        .help(label).accessibilityLabel(label)
        if destructive {
            button.buttonStyle(MeetingLeaveButtonStyle())
        } else {
            // The dock supplies the one glass surface; avoid glass on glass.
            button.buttonStyle(.borderless)
                .tint(nil as Color?).foregroundStyle(.primary)
        }
    }

    private func sharingBanner(_ target: ShareTarget) -> some View {
        HStack(spacing: 10) {
            Image(systemName: target.kind == .demo ? "rectangle.dashed" : "rectangle.inset.filled")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.kind == .demo ? "Preview · nothing is being broadcast" : "You’re sharing \(target.title)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                if target.kind == .demo { Text(target.title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Button("Stop sharing", systemImage: "stop.fill") { Task { await meeting.stopShare() } }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
                .tint(nil as Color?).foregroundStyle(.primary)
                .disabled(meeting.isApplyingControl)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.16)))
        .padding(.horizontal, 20).padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }

    private var connectionStage: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.regular)
            Text(meeting.status.label).font(.headline)
            if meeting.status == .waitingForHost {
                Text("The meeting will begin when the host starts it.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if meeting.status == .waitingRoom {
                Text("The host will let you in.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .overlay(alignment: .bottom) {
            if meeting.status != .leaving {
                Button(meeting.status == .reconnecting ? "Leave meeting…" : meeting.status == .waitingRoom ? "Leave waiting room" : "Cancel") {
                    if meeting.status == .reconnecting { model.showLeaveConfirmation = true }
                    else { Task { await model.leaveMeeting() } }
                }
                .buttonStyle(.bordered).controlSize(.regular)
                .tint(nil as Color?).foregroundStyle(.primary)
                .keyboardShortcut(.cancelAction)
                .padding(.bottom, 20)
            }
        }
    }

    private var connectionStatus: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(meeting.status.label).font(.system(size: 12, weight: .medium))
        }
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }

    private var waitingRoomBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.badge.clock").foregroundStyle(.tint)
            Text("\(meeting.waitingRoomParticipants.count) \(meeting.waitingRoomParticipants.count == 1 ? "person is" : "people are") waiting to join")
                .font(.system(size: 12, weight: .medium)).lineLimit(2)
            Spacer(minLength: 8)
            Button("Review") { model.sidebar = .people }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
                .tint(nil as Color?).foregroundStyle(.primary)
                .accessibilityLabel("Review people in the waiting room")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 20).padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }

    private func inspector(_ sidebar: MeetingSidebar, compact: Bool = false) -> some View {
        VStack(spacing: 0) {
            if compact && hasPersistentNotices {
                ScrollView { persistentNotices }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: 24)
            }
            if sidebar == .chat {
                MeetingChatView(meeting: meeting, presentation: model.sharingPresentation,
                                isPreview: model.isPreview, isCompact: compact)
            } else { peopleInspector }
        }
        // The shared header keeps its buttons fixed at the window's trailing
        // edge. The panel's glass reaches behind that row, just like the video.
        .padding(.top, compact ? 54 : 62)
        .whooshGlassSurface(cornerRadius: 22)
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private var peopleInspector: some View {
        let query = participantSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: (String) -> Bool = { name in
            query.isEmpty || name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
        }
        let people = meeting.participants.filter { matches($0.name) }
        let waiting = canManageWaitingRoom ? meeting.waitingRoomParticipants.filter { matches($0.name) } : []
        return VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search people", text: $participantSearch)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .focused($isParticipantSearchFocused)
                    .accessibilityLabel("Search people")
                if !participantSearch.isEmpty {
                    Button { participantSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("Clear search")
                    .accessibilityLabel("Clear people search")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .background(WhooshSearchFocusBoundary {
                if isParticipantSearchFocused { isParticipantSearchFocused = false }
            })
            .padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if !query.isEmpty && people.isEmpty && waiting.isEmpty {
                    Text("No matching people")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .accessibilityLabel("No matching people")
                }
                if !waiting.isEmpty {
                    Text("Waiting room · \(waiting.count)")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.bottom, 6)
                    ForEach(waiting) { participant in
                        WaitingRoomRow(meeting: meeting, participant: participant)
                    }
                    if !people.isEmpty { Divider().padding(.horizontal, 16).padding(.vertical, 12) }
                }
                if canManageWaitingRoom && !meeting.waitingRoomParticipants.isEmpty && !people.isEmpty {
                    Text("In the meeting · \(people.count)")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.bottom, 6)
                }
                ForEach(people) { participant in
                    HStack(spacing: 10) {
                        Text(participant.initials).font(.system(size: 11, weight: .medium))
                            .frame(width: 30, height: 30)
                            .background(WhooshTheme.palette[abs(participant.avatarSeed % WhooshTheme.palette.count)].opacity(0.45), in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(participant.name + (participant.isSelf ? " (you)" : ""))
                                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                            if participant.isHost { Text("Host").font(.system(size: 10)).foregroundStyle(.secondary) }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(participant.name)\(participant.isSelf ? ", you" : "")\(participant.isHost ? ", host" : ""), \(participant.isMuted ? "microphone muted" : "microphone on")")
                        Spacer(minLength: 4)
                        if participant.isMuted {
                            Image(systemName: "mic.slash").font(.system(size: 11)).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        Button { pin(participant) } label: {
                            Image(systemName: model.focusedParticipantID == participant.id ? "pin.fill" : "pin")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .tint(nil as Color?).foregroundStyle(.primary)
                        .help(model.focusedParticipantID == participant.id ? "Show everyone" : "Focus on \(participant.name)")
                        .accessibilityLabel(model.focusedParticipantID == participant.id ? "Show everyone" : "Focus on \(participant.name)")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .accessibilityElement(children: .contain)
                }
            }
            }
            // A search starts at the first result, even after scrolling far
            // down the full roster. Keep focus in the search field above.
            .id(query)
        }
    }
}

private struct MeetingChromeVisibility: ViewModifier {
    var isVisible: Bool
    var reduceMotion: Bool
    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .animation(reduceMotion ? nil : .easeInOut(duration: isVisible ? 0.14 : 0.28), value: isVisible)
    }
}

private struct MeetingLeaveButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let dark = colorScheme == .dark
        let foreground = dark ? Color(red: 1, green: 0.53, blue: 0.49) : Color(red: 0.64, green: 0.12, blue: 0.10)
        let background = dark
            ? Color(red: configuration.isPressed ? 0.29 : 0.22, green: 0.105, blue: 0.105)
            : Color(red: 0.98, green: configuration.isPressed ? 0.84 : 0.91, blue: configuration.isPressed ? 0.82 : 0.90)
        configuration.label
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(foreground.opacity(contrast == .increased ? 0.65 : 0.15)))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

struct ParticipantTile: View {
    var participant: MeetingParticipant
    var meeting: MeetingCoordinator
    var isFocused = false
    var allowsNativeVideo = true
    var preservesRendererSize = false
    var fillsFrame = false
    var showsInfo = true

    private var color: Color { WhooshTheme.palette[abs(participant.avatarSeed % WhooshTheme.palette.count)] }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 90
            let tiny = geometry.size.height < 44
            let rendersNativeVideo = allowsNativeVideo && participant.isCameraEnabled && meeting.capabilities.supportsNativeVideo
            ZStack {
                RoundedRectangle(cornerRadius: fillsFrame ? 0 : compact ? 7 : 12)
                    .fill(Color(red: 0.105, green: 0.12, blue: 0.125))
                LinearGradient(colors: [color.opacity(0.17), color.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if rendersNativeVideo {
                    NativeVideoContainer(meeting: meeting, participantID: participant.id,
                                         preservesRendererSize: preservesRendererSize, fillsFrame: fillsFrame)
                        // Focus A → B must mount a new owner for B's renderer,
                        // rather than reuse A's older host behind B's thumbnail.
                        .id(participant.id)
                } else {
                    let inset = min(compact ? 4.0 : 12.0, max(0, min(geometry.size.width, geometry.size.height)) * 0.08)
                    let nameSize = min(compact ? 10.0 : 14.0, max(1, geometry.size.height * (tiny ? 0.28 : 0.12)))
                    let nameHeight = min(max(0, geometry.size.height - inset * 2), nameSize * 1.25)
                    let spacing = min(tiny ? 2.0 : 8.0, max(0, geometry.size.height) * 0.045)
                    let avatarSize = max(0, min(100, geometry.size.width - inset * 2,
                        geometry.size.height * (tiny ? 0.45 : compact ? 0.5 : 0.46),
                        geometry.size.height - inset * 2 - nameHeight - spacing))
                    let badgeSize = min(22, avatarSize * 0.34)
                    VStack(spacing: spacing) {
                        Text(participant.initials)
                            .font(.system(size: max(1, min(42, avatarSize * 0.42)), weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.76))
                            .lineLimit(1).minimumScaleFactor(0.5)
                            .frame(width: avatarSize, height: avatarSize)
                            .background(color.opacity(0.22), in: Circle())
                            .overlay(alignment: .topTrailing) {
                                if participant.isMuted || participant.isSpeaking {
                                    Image(systemName: participant.isMuted ? "mic.slash.fill" : "waveform")
                                        .font(.system(size: max(1, badgeSize * 0.55), weight: .medium))
                                        .foregroundStyle(participant.isMuted ? .white.opacity(0.85) : .mint)
                                        .frame(width: badgeSize, height: badgeSize)
                                        .background(Color.black.opacity(0.75), in: Circle())
                                        .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                                }
                            }
                        Text(participant.name)
                            .font(.system(size: nameSize, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            .frame(height: nameHeight)
                    }
                    .padding(inset)
                }
                if rendersNativeVideo && tiny && showsInfo {
                    // A 100-person grid at a small window size cannot fit full
                    // names. Keep initials and media state distinct; names stay
                    // available through hover, VoiceOver, and the People list.
                    VStack {
                        HStack {
                            Spacer(minLength: 0)
                            if participant.isMuted {
                                Image(systemName: "mic.slash.fill").font(.system(size: 6)).foregroundStyle(.white.opacity(0.8))
                            } else if participant.isSpeaking {
                                Image(systemName: "waveform").font(.system(size: 6)).foregroundStyle(.mint)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(3)
                } else if rendersNativeVideo && showsInfo {
                    VStack {
                        HStack {
                            Spacer()
                            if isFocused {
                                Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                                    .padding(12)
                            }
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 4) {
                            Text(participant.name + (participant.isSelf ? " (you)" : ""))
                                .font(.system(size: compact ? 9 : 11, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 2)
                            if participant.isMuted { Image(systemName: "mic.slash.fill").font(.system(size: compact ? 8 : 10)) }
                            else if participant.isSpeaking { Image(systemName: "waveform").font(.system(size: compact ? 8 : 10)).foregroundStyle(.mint) }
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, compact ? 6 : 12).padding(.vertical, compact ? 5 : 10)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.24)], startPoint: .top, endPoint: .bottom))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: fillsFrame ? 0 : compact ? 7 : 12))
            .overlay(RoundedRectangle(cornerRadius: fillsFrame ? 0 : compact ? 7 : 12).strokeBorder(participant.isSpeaking ? .mint.opacity(0.65) : fillsFrame ? .clear : .white.opacity(0.04), lineWidth: participant.isSpeaking ? 1.5 : 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(participant.name)\(participant.isSelf ? ", you" : "")\(participant.isHost ? ", host" : ""), \(participant.isMuted ? "microphone muted" : "microphone on"), \(participant.isCameraEnabled ? "camera on" : "camera off")")
    }
}

/// Fits equal 16:9 tiles into the available canvas and centers incomplete rows.
/// The maximum-area layout is calculated once per layout pass, including at 100 tiles.
private struct MeetingTileLayout: Layout {
    var spacing: CGFloat

    private func arrangement(count: Int, size: CGSize) -> (columns: Int, tile: CGSize) {
        guard count > 0 else { return (1, .zero) }
        var best = (columns: 1, tile: CGSize.zero)
        for columns in 1...count {
            let rows = Int(ceil(Double(count) / Double(columns)))
            let width = max(0, (size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
            let height = max(0, (size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows))
            let fittedWidth = min(width, height * 16 / 9)
            if fittedWidth > best.tile.width { best = (columns, CGSize(width: fittedWidth, height: fittedWidth * 9 / 16)) }
        }
        return best
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 450))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let layout = arrangement(count: subviews.count, size: bounds.size)
        let rows = Int(ceil(Double(subviews.count) / Double(layout.columns)))
        let totalHeight = CGFloat(rows) * layout.tile.height + CGFloat(rows - 1) * spacing
        for index in subviews.indices {
            let row = index / layout.columns
            let column = index % layout.columns
            let itemsInRow = min(layout.columns, subviews.count - row * layout.columns)
            let rowWidth = CGFloat(itemsInRow) * layout.tile.width + CGFloat(itemsInRow - 1) * spacing
            let position = CGPoint(
                x: bounds.minX + (bounds.width - rowWidth) / 2 + CGFloat(column) * (layout.tile.width + spacing),
                y: bounds.minY + (bounds.height - totalHeight) / 2 + CGFloat(row) * (layout.tile.height + spacing)
            )
            subviews[index].place(at: position, anchor: .topLeading, proposal: ProposedViewSize(layout.tile))
        }
    }
}
