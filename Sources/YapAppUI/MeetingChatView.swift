import SwiftUI
import AppKit
import YapMeetings
import UniformTypeIdentifiers

/// One chat composer and draft across the meeting inspector and sharing panel.
struct MeetingChatView: View {
    var meeting: MeetingCoordinator
    @Bindable var presentation: YapMeetingPresentation
    var isPreview: Bool
    var isCompact = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredMessage: UUID?
    @State private var expandedThreads: Set<UUID> = []
    @State private var scrollPolicy = MeetingChatScrollPolicy()
    @State private var scrollTarget: MeetingChatThread.ScrollTarget?
    @State private var fileScrollTarget: String?
    @State private var scrollRequestID = UUID()
    @State private var isChatComposerFocused = false
    @State private var searchQuery = ""
    @State private var showsSearch = false
    @State private var editor = MeetingChatEditorState()
    @State private var showsLink = false
    @State private var linkURL = ""
    @State private var localError: String?
    @State private var pendingDelete: MeetingChatMessage?

    private var effectiveRecipient: MeetingChatRecipient {
        presentation.replyingTo?.replyRecipient ?? presentation.chatRecipient
    }
    private var chatAvailabilityMessage: String? {
        guard !meeting.canChat(to: effectiveRecipient) else { return nil }
        if !meeting.isConnected { return "Chat is available when you’re connected to the meeting." }
        if !meeting.capabilities.canChat || meeting.chatRecipients.isEmpty { return "Chat is currently unavailable in this meeting." }
        let recovery = presentation.replyingTo == nil ? "Choose another recipient." : "Cancel this reply to choose another recipient."
        if effectiveRecipient.kind == .participant, let id = effectiveRecipient.participantID,
           !meeting.participants.contains(where: { $0.id == id }) {
            return "This person is no longer in the meeting. \(recovery)"
        }
        return "Messaging this recipient isn’t available with the current chat permissions. \(recovery)"
    }
    private var entries: [MeetingChatEntry] {
        let threads = MeetingChatThread.group(meeting.chatMessages).filter {
            MeetingChatArchive.matches($0.root, query: searchQuery) || $0.replies.contains { MeetingChatArchive.matches($0, query: searchQuery) }
        }.map(MeetingChatEntry.thread)
        let files = meeting.chatAttachments.filter {
            searchQuery.isEmpty || [$0.name, $0.senderName, $0.recipient.label].joined(separator: " ").localizedStandardContains(searchQuery)
        }.map(MeetingChatEntry.attachment)
        return (threads + files).sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            chatToolbar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(entries) { entry in
                            switch entry {
                            case .thread(let thread): threadRow(thread)
                            case .attachment(let file): attachmentRow(file).id("file:\(file.id)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 16)
                }
                .overlay {
                    if entries.isEmpty {
                        ViewThatFits(in: .vertical) {
                            VStack(spacing: 10) {
                                Image(systemName: "bubble.left")
                                    .font(.system(size: 27, weight: .ultraLight))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                                Text(searchQuery.isEmpty ? "No messages yet" : "No matching messages")
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            Text(searchQuery.isEmpty ? "No messages yet" : "No matching messages")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                    }
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollGeometryChange(for: MeetingChatScrollGeometry.self) { geometry in
                    MeetingChatScrollGeometry(contentHeight: geometry.contentSize.height,
                        visibleMinY: geometry.visibleRect.minY, visibleMaxY: geometry.visibleRect.maxY)
                } action: { old, new in
                    scrollPolicy.geometryChanged(from: old, to: new)
                }
                .onChange(of: meeting.chatMessages.map(\.id)) { previousIDs, _ in
                    let previous = Set(previousIDs)
                    // Removing a message is not an incoming message, even when it was last.
                    guard let last = meeting.chatMessages.last(where: { !previous.contains($0.id) }) else { return }
                    if scrollPolicy.receivedMessage(isFromSelf: last.isFromSelf), searchQuery.isEmpty {
                        scrollToLatest()
                    }
                }
                .onChange(of: meeting.chatAttachments.map(\.id)) { previousIDs, _ in
                    let previous = Set(previousIDs)
                    guard let last = meeting.chatAttachments.last(where: { !previous.contains($0.id) }) else { return }
                    if scrollPolicy.receivedMessage(isFromSelf: last.isFromSelf), searchQuery.isEmpty { scrollToLatest() }
                }
                .onChange(of: meeting.sessionID, initial: true) { _, sessionID in
                    presentation.synchronize(sessionID: sessionID)
                    expandedThreads.removeAll(); hoveredMessage = nil; pendingDelete = nil
                    searchQuery = ""; showsSearch = false
                    scrollPolicy.reopen(sessionID: sessionID)
                    scrollToLatest()
                }
                .task(id: scrollRequestID) {
                    // Let the expanded reply rows enter the view tree before targeting one.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    if let fileScrollTarget { proxy.scrollTo(fileScrollTarget, anchor: .bottom) }
                    else if let scrollTarget { proxy.scrollTo(scrollTarget.messageID, anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    if scrollPolicy.hasNewMessages {
                        Button("New messages", systemImage: "arrow.down") {
                            searchQuery = ""
                            scrollPolicy.jumpToLatest()
                            scrollToLatest()
                        }
                        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                        .accessibilityHint("Scrolls to the latest chat message")
                        .padding(.bottom, 8)
                    }
                }
            }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 8) {
                if let reply = presentation.replyingTo {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrowshape.turn.up.left")
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Replying to \(reply.isFromSelf ? "yourself" : reply.senderName)").font(.caption.bold())
                            Text(reply.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Button("Cancel reply", systemImage: "xmark") { presentation.replyingTo = nil }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).help("Cancel reply")
                    }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                recipientPicker
                if let availability = chatAvailabilityMessage {
                    Text(availability).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("meeting-chat-availability")
                }
                HStack(alignment: .bottom, spacing: 8) {
                    MeetingChatRichEditor(text: $presentation.chatDraft, runs: $presentation.chatRuns,
                        state: editor, isEnabled: meeting.canChat(to: effectiveRecipient),
                        placeholder: chatAvailabilityMessage == nil ? "Message \(effectiveRecipient.label)" : "Chat unavailable",
                        focusRequest: presentation.chatFocusRequest, onFocusChange: { isChatComposerFocused = $0 },
                        send: { presentation.sendMessage(in: meeting) })
                        .frame(height: isCompact ? 32 : 54)
                        .padding(.leading, 4)
                    sendControl
                }
                .padding(5)
                .background {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(reduceTransparency ? Color(nsColor: .controlBackgroundColor) :
                                Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.035))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(
                        isChatComposerFocused && chatAvailabilityMessage == nil ? Color.accentColor.opacity(0.7) :
                            Color.primary.opacity(contrast == .increased ? 0.45 : 0.10),
                        lineWidth: (isChatComposerFocused && chatAvailabilityMessage == nil) || contrast == .increased ? 1 : 0.5)
                        .allowsHitTesting(false)
                }
                composerTools
                if presentation.chatDraft.count > 4_000 {
                    if isCompact {
                        ScrollView(.vertical) {
                            lengthWarning.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: 14)
                    } else {
                        lengthWarning
                    }
                } else if isPreview {
                    Text("Preview messages stay on this Mac").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, isCompact ? 8 : 12)
        }
        .onAppear { presentation.chatFocusRequest = UUID() }
        .onChange(of: searchQuery) { _, _ in
            if !searchQuery.isEmpty { expandedThreads.formUnion(MeetingChatThread.group(meeting.chatMessages).map(\.id)) }
        }
        .alert("Chat", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
            Button("OK") { localError = nil }
        } message: { Text(localError ?? "") }
        .confirmationDialog("Delete this message for everyone who received it?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            if let message = pendingDelete {
                Button("Delete message", role: .destructive) {
                    let session = meeting.sessionID
                    Task { await meeting.deleteChat(message, sessionID: session) }
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private func scrollToLatest() {
        if let file = meeting.chatAttachments.last, file.date >= (meeting.chatMessages.last?.date ?? .distantPast) {
            fileScrollTarget = "file:\(file.id)"; scrollTarget = nil
            scrollRequestID = UUID()
            return
        }
        fileScrollTarget = nil
        scrollTarget = MeetingChatThread.latestScrollTarget(in: meeting.chatMessages)
        if let threadID = scrollTarget?.expandedThreadID { expandedThreads.insert(threadID) }
        scrollRequestID = UUID()
    }

    private var lengthWarning: some View {
        Text("Keep your message under 4,000 characters.")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func messageRow(_ message: MeetingChatMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.isFromSelf { Spacer(minLength: 18) }
            VStack(alignment: message.isFromSelf ? .trailing : .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.isFromSelf ? "You" : message.senderName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(1)
                        .help(message.senderName)
                    Text(message.date, style: .time)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize()
                }
                .padding(message.isFromSelf ? .leading : .trailing, canReply(message) ? 66 : 40)
                if message.recipient.kind != .everyone {
                    Label(message.recipient.label, systemImage: message.recipient.kind == .participant ? "lock.fill" : "person.2")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .accessibilityLabel("To \(message.recipient.label)")
                }
                // Keep metadata and bubble geometry identical before and during hover.
                // Actions live opposite the sender, so the timestamp stays readable.
                MeetingChatMessageText(message: message, actions: textActions(for: message))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .background {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(message.isFromSelf ?
                                  Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.10) :
                                  Color.primary.opacity(colorScheme == .dark ? 0.075 : 0.045))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.4 : 0.045),
                                          lineWidth: contrast == .increased ? 1 : 0.5)
                            .allowsHitTesting(false)
                    }
            }
            if !message.isFromSelf { Spacer(minLength: 18) }
        }
        .frame(maxWidth: .infinity, alignment: message.isFromSelf ? .trailing : .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-chat-message-\(message.id)")
        .contentShape(Rectangle())
        .onHover { hoveredMessage = $0 ? message.id : (hoveredMessage == message.id ? nil : hoveredMessage) }
        .overlay(alignment: message.isFromSelf ? .topLeading : .topTrailing) {
            if hoveredMessage == message.id {
                HStack(spacing: 2) {
                    if canReply(message) {
                        Button("Reply", systemImage: "bubble.left.and.bubble.right") { beginReply(message) }
                            .labelStyle(.iconOnly).help(message.canReply ? "Reply in thread" : "Reply to \(message.replyRecipient?.label ?? "recipient")")
                            .frame(width: 24, height: 24)
                            .disabled(!meeting.isConnected || presentation.isSending)
                    }
                    Menu {
                        Button("Copy") { copy(message) }
                        Button("Quote") { quote(message) }
                        if message.isFromSelf && message.canDelete {
                            Divider()
                            Button("Delete message", role: .destructive) { pendingDelete = message }
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("More message actions")
                }
                .buttonStyle(.borderless).padding(4)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.18)))
                .offset(y: -6)
            }
        }
        .contextMenu {
            if canReply(message) { Button("Reply") { beginReply(message) }.disabled(!meeting.isConnected || presentation.isSending) }
            Button("Copy") { copy(message) }
            Button("Quote") { quote(message) }
            if message.isFromSelf && message.canDelete { Button("Delete message", role: .destructive) { pendingDelete = message } }
        }
        .accessibilityAction(named: "Copy message") { copy(message) }
        .accessibilityAction(named: "Quote message") { quote(message) }
    }

    private func textActions(for message: MeetingChatMessage) -> [MeetingChatMessageText.Action] {
        var actions: [MeetingChatMessageText.Action] = []
        if canReply(message), !presentation.isSending { actions.append(.init(title: "Reply", perform: { beginReply(message) })) }
        actions.append(.init(title: "Copy", perform: { copy(message) }))
        actions.append(.init(title: "Quote", perform: { quote(message) }))
        if message.isFromSelf && message.canDelete { actions.append(.init(title: "Delete message", perform: { pendingDelete = message })) }
        return actions
    }

    private func beginReply(_ message: MeetingChatMessage) {
        guard let recipient = message.replyRecipient else { return }
        presentation.chatRecipient = recipient
        presentation.replyingTo = message
        if let thread = MeetingChatThread.group(meeting.chatMessages).first(where: { $0.id == message.id || $0.replies.contains { $0.id == message.id } }) { expandedThreads.insert(thread.id) }
        presentation.chatFocusRequest = UUID()
    }
    private func copy(_ message: MeetingChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }
    private func quote(_ message: MeetingChatMessage) {
        if !presentation.quoteMessage(message) {
            localError = "Quoting this message isn’t available because its audience cannot be preserved."
        }
    }

    private func canReply(_ message: MeetingChatMessage) -> Bool {
        guard let recipient = message.replyRecipient else { return false }
        return (message.canReply || recipient.kind == .participant || recipient.kind == .waitingRoom) && meeting.canChat(to: recipient)
    }

    private var chatToolbar: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Find in chat", systemImage: "magnifyingglass") {
                    showsSearch.toggle()
                    if !showsSearch { searchQuery = "" }
                }.labelStyle(.iconOnly).help("Find in chat")
                Spacer()
                Menu {
                    Button("Save Chat…", systemImage: "square.and.arrow.down") { saveChat() }
                        .disabled(meeting.chatMessages.isEmpty && meeting.chatAttachments.isEmpty)
                    Divider()
                    Button("About chat features") {
                        localError = "Send messages and files to the recipients allowed by the host. Message editing and message reactions aren’t available in Yap. You can delete your own messages when the meeting allows it."
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Chat options")
            }.buttonStyle(.borderless)
            if showsSearch {
                HStack {
                    TextField("Search messages, people, and files", text: $searchQuery).textFieldStyle(.roundedBorder)
                    if !searchQuery.isEmpty { Button("Clear search", systemImage: "xmark.circle.fill") { searchQuery = "" }.labelStyle(.iconOnly).buttonStyle(.borderless) }
                }
            }
        }.padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var recipientPicker: some View {
        HStack(spacing: 5) {
            Text("To:").foregroundStyle(.secondary)
            Menu {
                ForEach(meeting.chatRecipients) { recipient in
                    Button(recipient.label) { presentation.chatRecipient = recipient; presentation.chatFocusRequest = UUID() }
                }
                if meeting.chatRecipients.isEmpty { Text("The host has restricted chat") }
            } label: {
                Label(effectiveRecipient.label, systemImage: effectiveRecipient.kind == .participant ? "lock.fill" : "person.2")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
            .disabled(presentation.replyingTo != nil || presentation.isSending)
            .accessibilityLabel("Message recipient").accessibilityValue(effectiveRecipient.label)
            Spacer(minLength: 0)
        }.font(.caption)
    }

    private var composerTools: some View {
        HStack(spacing: 12) {
            Button("Attach file", systemImage: "paperclip") { chooseFile() }
                .disabled(!meeting.chatPolicy.canTransferFiles || !meeting.canChat(to: effectiveRecipient) ||
                          ![MeetingChatRecipient.Kind.everyone, .participant].contains(effectiveRecipient.kind) || meeting.isApplyingControl)
                .help(meeting.chatPolicy.canTransferFiles ? "Send a file to \(effectiveRecipient.label)" : "File sharing is disabled in this meeting")
            Menu {
                Button("Bold") { editor.toggle(.bold) }
                Button("Italic") { editor.toggle(.italic) }
                Button("Underline") { editor.toggle(.underline) }
                Button("Strikethrough") { editor.toggle(.strikethrough) }
                Divider()
                Button("Insert Link…") { showsLink = true }
            } label: { Image(systemName: "textformat") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Format selected text")
            .disabled(!meeting.canChat(to: effectiveRecipient))
            .popover(isPresented: $showsLink) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Insert link").font(.headline)
                    TextField("https://example.com", text: $linkURL).textFieldStyle(.roundedBorder).frame(width: 240)
                    HStack {
                        Button("Cancel") { showsLink = false }
                        Spacer()
                        Button("Insert") {
                            if let url = MeetingChatRichText.safeLink(linkURL) { editor.insertLink(url); linkURL = ""; showsLink = false }
                        }.disabled(MeetingChatRichText.safeLink(linkURL) == nil)
                    }
                }.padding(14)
            }
            Spacer()
            if !isCompact { Text("Shift-Return for a new line").font(.system(size: 9)).foregroundStyle(.tertiary) }
        }.labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
    }

    private func threadRow(_ thread: MeetingChatThread) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            messageRow(thread.root).id(thread.root.id)
            if !thread.replies.isEmpty {
                Button(expandedThreads.contains(thread.id) ? "Collapse replies" : "\(thread.replies.count) \(thread.replies.count == 1 ? "reply" : "replies")",
                       systemImage: expandedThreads.contains(thread.id) ? "chevron.up" : "chevron.down") {
                    if !expandedThreads.insert(thread.id).inserted { expandedThreads.remove(thread.id) }
                }.buttonStyle(.plain).foregroundStyle(.tint).font(.caption)
                if expandedThreads.contains(thread.id) {
                    VStack(spacing: 16) { ForEach(thread.replies) { message in messageRow(message).id(message.id) } }
                        .padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 1) }
                }
            }
        }.accessibilityElement(children: .contain)
    }

    private func attachmentRow(_ file: MeetingChatAttachment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(file.senderName) → \(file.recipient.label)").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name).font(.callout).lineLimit(2).textSelection(.enabled)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: file.bytes), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    if file.status == .transferring {
                        ProgressView(value: file.progress)
                        Text("\(Int(file.progress * 100))%").font(.caption).monospacedDigit()
                    } else if file.status == .completed {
                        Text(file.isFromSelf ? "Sent" : "Saved").font(.caption).foregroundStyle(.secondary)
                    } else if file.status == .failed || file.status == .cancelled {
                        Text(file.status == .failed ? "Transfer failed" : "Cancelled").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if !file.isFromSelf && (file.status == .available || file.status == .failed || file.status == .cancelled) {
                    Button(file.status == .available ? "Save file" : "Retry download", systemImage: "arrow.down.circle") { saveFile(file) }
                        .labelStyle(.iconOnly).disabled(!meeting.isConnected || meeting.isApplyingControl)
                } else if file.status == .transferring {
                    Button("Cancel transfer", systemImage: "xmark.circle") {
                        let session = meeting.sessionID
                        Task { await meeting.cancelChatFile(file.id, sessionID: session) }
                    }.labelStyle(.iconOnly).disabled(!meeting.isConnected || meeting.isApplyingControl)
                }
            }
        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("meeting-chat-attachment-\(file.id)")
    }

    private func chooseFile() {
        let session = meeting.sessionID
        let recipient = effectiveRecipient
        let panel = NSOpenPanel(); panel.title = "Send a file to \(recipient.label)"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await meeting.sendChatFile(url, recipient: recipient, sessionID: session) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func saveFile(_ file: MeetingChatAttachment) {
        let session = meeting.sessionID
        let panel = NSSavePanel(); panel.title = "Save attachment"
        panel.nameFieldStringValue = MeetingChatArchive.safeFileName(file.name)
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await meeting.receiveChatFile(file.id, to: url, sessionID: session) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func saveChat() {
        let text = MeetingChatArchive.text(messages: meeting.chatMessages, attachments: meeting.chatAttachments, title: meeting.meetingTitle)
        let panel = NSSavePanel(); panel.title = "Save Chat"
        panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Meeting Chat.txt"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { localError = "Yap couldn’t save the chat. \(error.localizedDescription)" }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private var sendButton: some View {
        Button("Send message", systemImage: "arrow.up") { presentation.sendMessage(in: meeting) }
            .labelStyle(.iconOnly).controlSize(.regular).buttonBorderShape(.circle)
            .yapIconHover(cornerRadius: 100)
            .help("Send message")
            .disabled(presentation.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || presentation.chatDraft.count > 4_000 || presentation.isSending || !meeting.isConnected || !meeting.capabilities.canChat || !meeting.canChat(to: effectiveRecipient) || meeting.isApplyingControl)
    }

    @ViewBuilder private var sendControl: some View {
        if reduceTransparency { sendButton.buttonStyle(.borderedProminent) }
        else { sendButton.buttonStyle(.glassProminent) }
    }
}
