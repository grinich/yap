import Foundation
import SwiftUI
import YapMeetings

/// The saved meeting conversation follows the recording's playhead until the
/// viewer scrolls away. Messages remain selectable and the pane is read-only.
struct RecordingChatView: View {
    @Bindable var model: RecordingLibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private var chat: RecordingChatModel { model.chat }

    var body: some View {
        VStack(spacing: 0) {
            // The shared player header owns the title and chat toggle, matching
            // the live meeting inspector. Keep the transcript itself headerless.
            if let notice = chat.timingNotice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                Divider().opacity(0.4)
            }

            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(chat.messages) { message in
                                messageRow(message).id(message.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 16)
                    }
                    .overlay { if chat.messages.isEmpty { emptyState } }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting || phase == .tracking { chat.followsPlayback = false }
                    }
                    .onChange(of: chat.scrollTargetID) { _, _ in
                        if chat.followsPlayback { scrollToPlayhead(proxy) }
                    }
                    .onAppear { if chat.followsPlayback { scrollToPlayhead(proxy, animated: false) } }
                    .accessibilityLabel("Recorded meeting chat")

                    if !chat.messages.isEmpty {
                        Divider().opacity(0.4)
                        HStack(spacing: 8) {
                            if chat.followsPlayback {
                                Label("Following playback", systemImage: "play.circle")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            } else {
                                Button("Follow playback", systemImage: "play.circle") {
                                    chat.followsPlayback = true
                                    scrollToPlayhead(proxy)
                                }
                                .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                                .accessibilityHint("Scrolls to the message at the current playback position")
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(YapWindowInteractionRegion(isEnabled: true))
    }

    @ViewBuilder private var emptyState: some View {
        if chat.isLoading {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading chat…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = chat.error {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 27, weight: .ultraLight)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("Couldn’t load chat").font(.system(size: 13, weight: .medium))
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                Button("Retry") { chat.retry() }.buttonStyle(.bordered).controlSize(.small)
            }
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 27, weight: .ultraLight)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(chat.hasChatFile ? "No saved messages" : "No chat saved")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Text(chat.hasChatFile
                     ? "This recording’s chat file has no messages to show."
                     : "Chat appears here when it was saved with the cloud recording.")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func messageRow(_ message: ZoomRecordingChatMessage) -> some View {
        let active = chat.activeMessageIDs.contains(message.id)
        let canSeek = chat.playbackTime(for: message) != nil && !model.isPreparing
        let unavailableReason = model.isPreparing ? "Wait for the video to finish opening" : "This message is outside the current video"
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(message.sender)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).help(message.sender)
                Spacer(minLength: 4)
                Button(timestamp(message.offset)) { model.seekToChatMessage(message) }
                    .font(.system(size: 10)).monospacedDigit().buttonStyle(.plain)
                    .foregroundStyle(active ? YapTheme.accent : .secondary)
                    .fixedSize().disabled(!canSeek)
                    .help(canSeek ? "Play from this message" : unavailableReason)
                    .accessibilityLabel("Message at \(timestamp(message.offset))")
                    .accessibilityHint(canSeek ? "Seeks the recording to this message" : unavailableReason)
            }
            if let recipient = message.recipient, !recipient.isEmpty,
               recipient.caseInsensitiveCompare("Everyone") != .orderedSame {
                Text("To \(recipient)").font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).help(recipient)
            }
            Text(ChatMessageLinks.attributedText(message.text))
                .font(.system(size: 13)).foregroundStyle(.primary)
                .tint(YapTheme.accent)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11).padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(active ? YapTheme.accent.opacity(colorScheme == .dark ? 0.20 : 0.10)
                              : Color.primary.opacity(colorScheme == .dark ? 0.075 : 0.045))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(active ? YapTheme.accent.opacity(contrast == .increased ? 0.9 : 0.5)
                                      : Color.primary.opacity(contrast == .increased ? 0.4 : 0.045),
                                      lineWidth: active || contrast == .increased ? 1 : 0.5)
                        .allowsHitTesting(false)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func scrollToPlayhead(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let target = chat.scrollTargetID ?? chat.messages.first?.id else { return }
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
        } else { proxy.scrollTo(target, anchor: .center) }
    }

    private func timestamp(_ offset: TimeInterval) -> String {
        let seconds = offset.isFinite ? Int(max(0, min(offset, Double(Int.max / 2)))) : 0
        return [seconds / 3_600, (seconds / 60) % 60, seconds % 60]
            .map { $0 < 10 ? "0\($0)" : String($0) }.joined(separator: ":")
    }
}
