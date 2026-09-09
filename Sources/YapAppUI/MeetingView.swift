import AppKit
import SwiftUI
import YapMeetings
import YapSystem

struct MeetingView: View {
    @Bindable var model: YapModel
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
        meeting.presentationParticipant
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
                connectionStage
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
                                            .yapGlassSurface(cornerRadius: 20)
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
                        if let sidebar = model.sidebar {
                            Text(sidebar == .chat ? "Chat" : "People")
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
        .background(YapWindowPointerPresence(onChange: { inside in
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
            if notification.object as? NSWindow === model.meetingPresentation.mainWindow { keyboardControlsActive = false }
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
            if let invitation = invitationToCopy {
                Button {
                    copyInvitation(invitation)
                } label: {
                    Label(copiedInvitation == invitation ? "Invite link copied" : "Copy invite link",
                          systemImage: copiedInvitation == invitation ? "checkmark" : "link")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .yapIconHover()
                .tint(nil as Color?).foregroundStyle(.primary)
                .help("Copy invite link")
            }
            if !showsConnectionStage {
                Menu {
                    Picker("View", selection: Binding(get: { meeting.layout }, set: { meeting.setLayout($0) })) {
                        ForEach(MeetingLayout.allCases, id: \.self) { layout in
                            Label { Text(layout.title) } icon: {
                                Image(nsImage: (layout == .gallery ? RecordingPlaybackLayout.gallery : .speaker).image)
                            }.tag(layout)
                        }
                    }
                    .pickerStyle(.inline).labelsHidden()
                    if model.focusedParticipantID != nil {
                        Button("Unpin participant", systemImage: "pin.slash") { model.focusedParticipantID = nil }
                    }
                    if meeting.layout == .gallery || !meeting.receivedShares.isEmpty || model.isPreview { Divider() }
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
                    if meeting.layout == .gallery {
                        Picker("People per page", selection: Binding(get: { model.gridLimit }, set: { model.updateGridLimit($0) })) {
                            ForEach([25, 49, 100], id: \.self) { count in
                                Text("Up to \(count)").tag(count)
                            }
                            Text("Show all").tag(0)
                        }
                        .pickerStyle(.inline)
                    }
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
                    HStack(spacing: 4) {
                        Image(nsImage: (meeting.layout == .gallery ? RecordingPlaybackLayout.gallery : .speaker).image)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .frame(width: 56, height: 32)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
                .yapIconHover()
                .background(YapWindowInteractionRegion(isEnabled: showsControls))
                .tint(nil as Color?).foregroundStyle(.primary)
                .help("Meeting layout").accessibilityLabel("Meeting layout")
                .accessibilityValue(meeting.layout.title)
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
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .toggleStyle(.button).labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .background(model.sidebar == sidebar ? Color.primary.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .yapIconHover(isSelected: model.sidebar == sidebar)
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
                                        .frame(width: stripHeight * participant.tileAspectRatio, height: stripHeight)
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
        } else if let pair = meeting.oneToOneParticipants {
            speakerCanvas(pair.remote, local: pair.local, compactHeight: compactHeight)
        } else if let focusedParticipant {
            speakerCanvas(focusedParticipant,
                          local: meeting.participants.first { $0.isSelf && $0.id != focusedParticipant.id },
                          compactHeight: compactHeight)
        } else if meeting.visibleParticipants.count == 1, let participant = meeting.visibleParticipants.first {
            participantTile(participant, immersive: true)
        } else {
            MeetingGalleryView(meeting: meeting) { participant in participantTileContent(participant) }
            .id(meeting.sessionID)
            .padding(6)
        }
    }

    private func speakerCanvas(_ speaker: MeetingParticipant, local: MeetingParticipant?, compactHeight: Bool) -> some View {
        participantTile(speaker, focused: model.focusedParticipantID == speaker.id, immersive: true)
            .overlay {
                if let local {
                    MeetingCornerSelfView(participant: local, meeting: meeting, compactHeight: compactHeight,
                                          showsControls: showsControls)
                        .padding(.trailing, model.sidebar != nil ? 22 : 0)
                }
            }
    }

    private func participantTile(_ participant: MeetingParticipant, focused: Bool = false, immersive: Bool = false) -> some View {
        participantTileContent(participant, focused: focused, immersive: immersive)
            .overlay { YapVideoWindowDragSurface().accessibilityHidden(true) }
            .contextMenu {
                Button(model.focusedParticipantID == participant.id ? "Unpin \(participant.name)" : "Focus on \(participant.name)", systemImage: model.focusedParticipantID == participant.id ? "pin.slash" : "pin") { pin(participant) }
            }
    }

    private func participantTileContent(_ participant: MeetingParticipant, focused: Bool = false, immersive: Bool = false) -> some View {
        ParticipantTile(participant: participant, meeting: meeting, isFocused: focused,
                        allowsNativeVideo: true,
                        fillsFrame: immersive, showsInfo: !immersive || showsControls)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture(count: 2) { pin(participant) }
            .accessibilityAction(named: model.focusedParticipantID == participant.id ? "Unpin this person" : "Focus on this person") { pin(participant) }
            .help(participant.name + (participant.isMuted ? " · Microphone muted" : " · Microphone on"))
    }

    private func pin(_ participant: MeetingParticipant) {
        meeting.selectReceivedShare(nil)
        if model.focusedParticipantID == participant.id { model.focusedParticipantID = nil; return }
        model.focusedParticipantID = participant.id
    }

    private var pageControls: some View {
        HStack(spacing: 16) {
            Button { meeting.setPage(meeting.pageIndex - 1) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
                .yapIconHover(cornerRadius: 8)
                .disabled(meeting.pageIndex == 0).accessibilityLabel("Previous participants")
            Text("\(meeting.pageIndex + 1) of \(meeting.pageCount)")
                .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            Button { meeting.setPage(meeting.pageIndex + 1) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
                .yapIconHover(cornerRadius: 8)
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
        .yapGlassSurface(cornerRadius: 24)
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
                        YapSystemMediaEffects.showMicrophoneModes()
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
                        YapSystemMediaEffects.showVideoEffects()
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
                .yapIconHover(cornerRadius: 16)
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
        MeetingConnectionView(title: meeting.meetingTitle, status: meeting.status) {
            if meeting.status == .reconnecting { model.showLeaveConfirmation = true }
            else { Task { await model.leaveMeeting() } }
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
                MeetingChatView(meeting: meeting, presentation: model.meetingPresentation,
                                isPreview: model.isPreview, isCompact: compact)
            } else { peopleInspector }
        }
        // The shared header keeps its buttons fixed at the window's trailing
        // edge. The panel's glass reaches behind that row, just like the video.
        .padding(.top, compact ? 54 : 62)
        .yapTrailingPanelSurface()
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
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Clear search")
                    .yapIconHover(cornerRadius: 4)
                    .accessibilityLabel("Clear people search")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .background(YapSearchFocusBoundary {
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
                        ParticipantAvatarView(participant: participant, sessionID: meeting.sessionID,
                                              diameter: 30, fontSize: 11, backgroundOpacity: 0.45)
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
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .yapIconHover(cornerRadius: 8)
                        .tint(nil as Color?).foregroundStyle(.primary)
                        .help(model.focusedParticipantID == participant.id ? "Unpin \(participant.name)" : "Focus on \(participant.name)")
                        .accessibilityLabel(model.focusedParticipantID == participant.id ? "Unpin \(participant.name)" : "Focus on \(participant.name)")
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

struct MeetingChromeVisibility: ViewModifier {
    static func animation(isVisible: Bool) -> Animation {
        .easeInOut(duration: isVisible ? 0.14 : 0.28)
    }
    var isVisible: Bool
    var reduceMotion: Bool
    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .animation(reduceMotion ? nil : Self.animation(isVisible: isVisible), value: isVisible)
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
            .yapIconHover(cornerRadius: 16)
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
    var fillsFrame = false
    var showsInfo = true

    private var color: Color { YapTheme.palette[abs(participant.avatarSeed % YapTheme.palette.count)] }

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
                                         fillsFrame: fillsFrame,
                                         aspectRatio: participant.tileAspectRatio)
                        .allowsHitTesting(false)
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
                        ParticipantAvatarView(participant: participant, sessionID: meeting.sessionID, diameter: avatarSize)
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
            // Full-bleed video stays square beneath the native window mask,
            // but its inset speaking outline must follow the rounded edge.
            .overlay(RoundedRectangle(cornerRadius: compact ? 7 : 12, style: .continuous).strokeBorder(participant.isSpeaking ? .mint.opacity(0.65) : fillsFrame ? .clear : .white.opacity(0.04), lineWidth: participant.isSpeaking ? 1.5 : 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(participant.name)\(participant.isSelf ? ", you" : "")\(participant.isHost ? ", host" : ""), \(participant.isMuted ? "microphone muted" : "microphone on"), \(participant.isCameraEnabled ? "camera on" : "camera off")")
    }
}
