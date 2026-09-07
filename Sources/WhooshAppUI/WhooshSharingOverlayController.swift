import AppKit
import Observation
import SwiftUI
import WhooshMeetings

@MainActor @Observable
public final class WhooshSharingPresentation {
    public private(set) var isPresenting = false
    public var chatVisible = true
    @ObservationIgnored public weak var mainWindow: NSWindow?
    var chatDraft = ""
    private(set) var isSending = false
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var wasSharing = false
    @ObservationIgnored private var sendID: UUID?

    public init() {}

    func synchronize(sessionID: UUID?, isSharing: Bool) {
        if self.sessionID != sessionID {
            self.sessionID = sessionID
            chatDraft = ""
            isSending = false
            sendID = nil
            wasSharing = false
            chatVisible = true
        }
        if isSharing && !wasSharing { chatVisible = true }
        wasSharing = isSharing
    }

    func setPresenting(_ value: Bool) {
        if isPresenting != value { isPresenting = value }
    }

    func sendMessage(in meeting: MeetingCoordinator) {
        guard !isSending, meeting.isConnected, meeting.capabilities.canChat, !meeting.isApplyingControl,
              !chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              chatDraft.count <= 4_000 else { return }
        let draft = chatDraft
        let session = meeting.sessionID
        let request = UUID()
        sendID = request
        isSending = true
        Task { [weak self] in
            await meeting.sendChat(text: draft, sessionID: session)
            guard let self, self.sendID == request else { return }
            if meeting.sessionID == session, meeting.lastError == nil, self.chatDraft == draft {
                self.chatDraft = ""
            }
            self.isSending = false
            self.sendID = nil
        }
    }
}

enum WhooshSharingOverlayLayout {
    static func shouldPresent(isConnected: Bool, isPreview: Bool, hasMainWindow: Bool,
                              applicationIsActive: Bool, mainWindowIsKey: Bool,
                              mainWindowIsVisible: Bool, mainWindowIsMiniaturized: Bool,
                              mainWindowHasKeySheet: Bool = false) -> Bool {
        let mainWindowIsForeground = applicationIsActive && (mainWindowIsKey || mainWindowHasKeySheet) &&
            mainWindowIsVisible && !mainWindowIsMiniaturized
        return isConnected && !isPreview && hasMainWindow && !mainWindowIsForeground
    }

    static func shouldPresentChat(isPresenting: Bool, isSharing: Bool, chatVisible: Bool) -> Bool {
        isPresenting && isSharing && chatVisible
    }

    static func participants(from participants: [MeetingParticipant]) -> [MeetingParticipant] {
        var seen: Set<String> = []
        let others = Array(participants.filter { !$0.isSelf && seen.insert($0.id).inserted }.prefix(6))
        if !others.isEmpty { return others }
        // A solo call still needs a visible companion when the meeting is in
        // the background. Reuse the current page's subscribed self renderer;
        // camera-off calls naturally show the same initials tile as the canvas.
        return participants.first(where: \.isSelf).map { [$0] } ?? []
    }

    static func stripFrame(in screen: CGRect, aspectRatios: [Double]) -> CGRect {
        let single = aspectRatios.count <= 1
        let ratio = aspectRatios.first.flatMap { $0.isFinite && (0.125...8).contains($0) ? $0 : nil } ?? 16 / 9
        let videoHeight = single ? min(384 / ratio, screen.height * 0.5 - 32) : min(380, screen.height * 0.5 - 32)
        let width = single ? min(384, videoHeight * ratio) + 16 : min(720, screen.width * 0.65)
        let size = CGSize(width: min(screen.width, max(200, width)), height: min(screen.height, max(140, videoHeight + 32)))
        return clampedStripFrame(CGRect(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 20,
                                       width: size.width, height: size.height), in: screen)
    }

    static func chatFrame(in screen: CGRect) -> CGRect {
        let size = CGSize(width: min(320, screen.width), height: min(400, screen.height))
        return CGRect(x: max(screen.minX, screen.maxX - size.width - 20),
                      y: min(screen.maxY - size.height, screen.minY + 20), width: size.width, height: size.height)
    }

    static func clampedStripFrame(_ frame: CGRect, in screen: CGRect) -> CGRect {
        let width = min(max(1, frame.width), screen.width)
        let height = min(max(1, frame.height), screen.height)
        return CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - height),
                      width: width, height: height)
    }

}

struct WhooshSharingChatPlacement {
    private var lastPresentedScreen: CGRect?

    mutating func frameForPresentation(currentFrame: CGRect?, on screen: CGRect) -> CGRect {
        defer { lastPresentedScreen = screen }
        // A hidden panel must retain its own last display until it is shown.
        // The participant strip can move displays independently in the meantime.
        guard let currentFrame, lastPresentedScreen == screen else {
            return WhooshSharingOverlayLayout.chatFrame(in: screen)
        }
        return currentFrame
    }
}

struct WhooshSharingStopTransition {
    private var sessionID: UUID?
    private var wasSharing = false

    mutating func consume(sessionID: UUID?, isSharing: Bool, isConnected: Bool) -> Bool {
        let didStop = sessionID != nil && self.sessionID == sessionID && wasSharing && !isSharing && isConnected
        self.sessionID = sessionID
        wasSharing = isSharing
        return didStop
    }
}

/// Keeps participants visible when a connected meeting is in the background,
/// using self view until another visible participant joins.
/// These windows are not guaranteed to be excluded from Zoom's display capture.
@MainActor
public final class WhooshSharingOverlayController: NSObject, NSWindowDelegate {
    private let model: WhooshModel
    private let openMainWindow: () -> Void
    private var stripPanel: NSPanel?
    private var chatPanel: NSPanel?
    private var isInteracting = false
    private var isPositioningStrip = false
    private var customStripFrame: CGRect?
    private var timer: Timer?
    private var stopped = false
    private var presentedSessionID: UUID?
    private var chatPlacement = WhooshSharingChatPlacement()
    private var stopTransition = WhooshSharingStopTransition()

    public init(model: WhooshModel, openMainWindow: @escaping () -> Void = {}) {
        self.model = model
        self.openMainWindow = openMainWindow
        super.init()
        observe()
        refresh()
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.invalidate()
        timer = nil
        dismissPanels()
    }

    private func observe() {
        guard !stopped else { return }
        withObservationTracking {
            let meeting = model.meeting
            _ = meeting.sessionID
            _ = meeting.sharing
            _ = meeting.isConnected
            _ = meeting.visibleParticipants
            _ = model.isPreview
            _ = model.sharingPresentation.chatVisible
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.observe()
                self.refresh()
            }
        }
    }

    private func refresh() {
        guard !stopped else { return }
        let meeting = model.meeting
        let presentation = model.sharingPresentation
        let shouldReturnToMeeting = stopTransition.consume(sessionID: meeting.sessionID,
                                                           isSharing: meeting.sharing.isSharing,
                                                           isConnected: meeting.isConnected && !model.isPreview)
        presentation.synchronize(sessionID: meeting.sessionID, isSharing: meeting.sharing.isSharing)
        if meeting.isConnected && !model.isPreview {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                if let timer { RunLoop.main.add(timer, forMode: .common) }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
        if shouldReturnToMeeting {
            dismissPanels()
            openMainWindow()
            return
        }
        let shouldPresent = WhooshSharingOverlayLayout.shouldPresent(
            isConnected: meeting.isConnected, isPreview: model.isPreview,
            hasMainWindow: presentation.mainWindow != nil,
            applicationIsActive: NSApplication.shared.isActive,
            mainWindowIsKey: presentation.mainWindow?.isKeyWindow == true,
            mainWindowIsVisible: presentation.mainWindow?.isVisible == true,
            mainWindowIsMiniaturized: presentation.mainWindow?.isMiniaturized == true,
            mainWindowHasKeySheet: presentation.mainWindow?.attachedSheet?.isKeyWindow == true)
        guard shouldPresent, let screen = sharingScreen() else { dismissPanels(); return }
        if presentedSessionID != meeting.sessionID { dismissPanels() }
        presentedSessionID = meeting.sessionID
        // The main canvas relinquishes its renderer hosts before the strip
        // acquires them. Dismissal tears down strip hosts before handing back.
        presentation.setPresenting(true)
        updateStrip(on: screen)
        updateChat(on: screen)
    }

    private func sharingScreen() -> NSScreen? {
        if let target = model.meeting.sharing.target, target.kind == .display,
           let displayID = UInt32(target.id),
           let screen = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
           }) { return screen }
        return model.sharingPresentation.mainWindow?.screen ?? NSScreen.main
    }

    private func updateStrip(on fallbackScreen: NSScreen) {
        let participants = WhooshSharingOverlayLayout.participants(from: model.meeting.visibleParticipants)
        guard !participants.isEmpty else { dismissStrip(); return }
        // Remember the user's display as well as their position. Moving a PiP
        // to another monitor must not snap it back to the main meeting's display.
        let screen = customStripFrame.flatMap { frame in
            NSScreen.screens.max { lhs, rhs in
                Self.intersectionArea(frame, lhs.visibleFrame) < Self.intersectionArea(frame, rhs.visibleFrame)
            }.flatMap { Self.intersectionArea(frame, $0.visibleFrame) > 0 ? $0 : nil }
        } ?? fallbackScreen
        let proposed = customStripFrame ?? WhooshSharingOverlayLayout.stripFrame(in: screen.visibleFrame,
            aspectRatios: participants.map(\.tileAspectRatio))
        let frame = WhooshSharingOverlayLayout.clampedStripFrame(proposed, in: screen.visibleFrame)
        if stripPanel == nil {
            let panel = SharingPictureInPicturePanel(contentRect: frame,
                styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            configure(panel)
            panel.title = "Picture in picture"
            panel.setAccessibilityLabel("Picture in picture")
            panel.isMovable = true
            panel.minSize = NSSize(width: min(200, screen.visibleFrame.width), height: min(140, screen.visibleFrame.height))
            panel.delegate = self
            let content = SharingPictureInPictureView(rootView: SharingParticipantStrip(model: model))
            content.interactionChanged = { [weak self] active in
                self?.isInteracting = active
                if !active { self?.refresh() }
            }
            panel.contentView = content
            stripPanel = panel
        }
        guard let panel = stripPanel else { return }
        panel.maxSize = screen.visibleFrame.size
        if !isInteracting, !panel.inLiveResize, panel.frame != frame {
            isPositioningStrip = true
            panel.setFrame(frame, display: true)
            isPositioningStrip = false
        }
        customStripFrame = panel.frame
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private static func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    public func windowDidMove(_ notification: Notification) { rememberStripFrame(notification) }
    public func windowDidResize(_ notification: Notification) { rememberStripFrame(notification) }
    private func rememberStripFrame(_ notification: Notification) {
        guard !isPositioningStrip, let panel = stripPanel, notification.object as? NSWindow === panel else { return }
        customStripFrame = panel.frame
    }

    private func updateChat(on screen: NSScreen) {
        guard WhooshSharingOverlayLayout.shouldPresentChat(isPresenting: model.sharingPresentation.isPresenting,
            isSharing: model.meeting.sharing.isSharing, chatVisible: model.sharingPresentation.chatVisible) else {
            chatPanel?.orderOut(nil)
            return
        }
        let frame = chatPlacement.frameForPresentation(currentFrame: chatPanel?.frame, on: screen.visibleFrame)
        if let panel = chatPanel, panel.frame != frame { panel.setFrame(frame, display: true) }
        if chatPanel == nil {
            let panel = SharingPanel(contentRect: frame,
                                     styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            configure(panel)
            panel.title = "Chat"
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.minSize = NSSize(width: 280, height: 240)
            panel.delegate = self
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            let content = NSHostingView(rootView: SharingChatSurface(model: model))
            content.sizingOptions = []
            panel.contentView = content
            chatPanel = panel
        }
        guard let panel = chatPanel else { return }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func configure(_ panel: NSPanel) {
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        // Legacy defense only; modern ScreenCaptureKit may still capture it.
        panel.sharingType = .none
    }

    private func dismissStrip() {
        stripPanel?.orderOut(nil)
        stripPanel?.contentView = nil
        stripPanel = nil
        isInteracting = false

    }

    private func dismissPanels() {
        dismissStrip()
        chatPanel?.orderOut(nil)
        chatPanel?.contentView = nil
        chatPanel?.delegate = nil
        chatPanel = nil
        presentedSessionID = nil
        chatPlacement = WhooshSharingChatPlacement()
        model.sharingPresentation.setPresenting(false)
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === chatPanel {
            model.sharingPresentation.chatVisible = false
            sender.orderOut(nil)
            return false
        }
        return true
    }
}

@MainActor
private final class SharingPanel: NSPanel {
    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SharingPictureInPicturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct SharingParticipantStrip: View {
    @Bindable var model: WhooshModel

    var body: some View {
        let people = WhooshSharingOverlayLayout.participants(from: model.meeting.visibleParticipants)
        MeetingTileLayout(aspectRatios: people.map(\.tileAspectRatio), spacing: 8) {
            ForEach(people) { participant in
                ParticipantTile(participant: participant, meeting: model.meeting)
            }
        }
        .padding(8).padding(.bottom, 16)
        .modifier(SharingGlass())
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.16), lineWidth: 0.75))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                .frame(width: 24, height: 24).accessibilityHidden(true)
        }
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }
}

private struct SharingChatSurface: View {
    @Bindable var model: WhooshModel
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 28)
                .modifier(SharingGlass(bottomCornerRadius: 0))
                .accessibilityHidden(true)
            MeetingChatView(meeting: model.meeting, presentation: model.sharingPresentation, isPreview: model.isPreview)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct SharingGlass: ViewModifier {
    var bottomCornerRadius: CGFloat = 14
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: bottomCornerRadius,
                               bottomTrailingRadius: bottomCornerRadius, topTrailingRadius: 14)
    }
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}
