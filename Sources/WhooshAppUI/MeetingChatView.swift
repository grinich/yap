import SwiftUI
import WhooshMeetings

/// One chat composer and draft across the meeting inspector and sharing panel.
struct MeetingChatView: View {
    var meeting: MeetingCoordinator
    @Bindable var presentation: WhooshSharingPresentation
    var isPreview: Bool
    var isCompact = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @State private var showChatNotice = false
    @State private var scrollPolicy = MeetingChatScrollPolicy()
    @FocusState private var isChatComposerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(meeting.chatMessages) { message in
                            messageRow(message).id(message.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 16)
                }
                .overlay {
                    if meeting.chatMessages.isEmpty {
                        ViewThatFits(in: .vertical) {
                            VStack(spacing: 10) {
                                Image(systemName: "bubble.left")
                                    .font(.system(size: 27, weight: .ultraLight))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                                Text("No messages yet")
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            Text("No messages yet")
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
                .onChange(of: meeting.chatMessages.last?.id) { _, _ in
                    guard let last = meeting.chatMessages.last else { return }
                    if scrollPolicy.receivedMessage(isFromSelf: last.isFromSelf) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: meeting.sessionID) { _, sessionID in
                    if scrollPolicy.synchronize(sessionID: sessionID), let last = meeting.chatMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onAppear {
                    scrollPolicy.reopen(sessionID: meeting.sessionID)
                    if let last = meeting.chatMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    if scrollPolicy.hasNewMessages {
                        Button("New messages", systemImage: "arrow.down") {
                            scrollPolicy.jumpToLatest()
                            if let last = meeting.chatMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                        .accessibilityHint("Scrolls to the latest chat message")
                        .padding(.bottom, 8)
                    }
                }
            }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 8) {
                if let notice = meeting.chatLegalNotice {
                    if isCompact {
                        ScrollView(.vertical) {
                            chatNoticeButton(notice)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: 24)
                    } else {
                        chatNoticeButton(notice)
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message everyone", text: $presentation.chatDraft, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...(isCompact ? 1 : 4))
                        .padding(.leading, 7).padding(.vertical, 6)
                        .focused($isChatComposerFocused)
                        .onSubmit { presentation.sendMessage(in: meeting) }.accessibilityLabel("Message everyone")
                        .disabled(!meeting.isConnected || !meeting.capabilities.canChat)
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
                        isChatComposerFocused ? Color.accentColor.opacity(0.7) :
                            Color.primary.opacity(contrast == .increased ? 0.45 : 0.10),
                        lineWidth: isChatComposerFocused || contrast == .increased ? 1 : 0.5)
                        .allowsHitTesting(false)
                }
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
        .onChange(of: meeting.sessionID, initial: true) { _, sessionID in
            presentation.synchronize(sessionID: sessionID, isSharing: meeting.sharing.isSharing)
        }
        .onAppear { isChatComposerFocused = true }
    }

    private func chatNoticeButton(_ notice: MeetingChatLegalNotice) -> some View {
        Button { showChatNotice.toggle() } label: {
            HStack(alignment: .top, spacing: 6) {
                Text(notice.prompt).font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "info.circle").font(.system(size: 12))
            }
            .foregroundStyle(.primary)
        }
        .buttonStyle(.borderless).accessibilityLabel(notice.prompt)
        .tint(nil as Color?)
        .accessibilityHint("Opens Zoom’s chat privacy information")
        .popover(isPresented: $showChatNotice, arrowEdge: .top) {
            Text(notice.explanation)
                .font(.system(size: 13)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(20).frame(width: 300)
        }
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
                Text(message.text)
                    .font(.system(size: 13)).foregroundStyle(.primary)
                    .textSelection(.enabled)
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
    }

    private var sendButton: some View {
        Button("Send message", systemImage: "arrow.up") { presentation.sendMessage(in: meeting) }
            .labelStyle(.iconOnly).controlSize(.regular).buttonBorderShape(.circle)
            .help("Send message")
            .disabled(presentation.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || presentation.chatDraft.count > 4_000 || presentation.isSending || !meeting.isConnected || !meeting.capabilities.canChat || meeting.isApplyingControl)
    }

    @ViewBuilder private var sendControl: some View {
        if reduceTransparency { sendButton.buttonStyle(.borderedProminent) }
        else { sendButton.buttonStyle(.glassProminent) }
    }
}
