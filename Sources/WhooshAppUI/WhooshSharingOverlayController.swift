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

    static func stripFrame(in screen: CGRect, count: Int) -> CGRect {
        let count = max(1, min(6, count))
        let maximumWidth = max(1, screen.width * 0.6)
        let spacing: CGFloat = 8
        let padding: CGFloat = 8
        let tileWidth = max(1, min(112, (maximumWidth - padding * 2 - spacing * CGFloat(count - 1)) / CGFloat(count)))
        let width = min(maximumWidth, tileWidth * CGFloat(count) + spacing * CGFloat(count - 1) + padding * 2)
        let height = min(screen.height, tileWidth * 9 / 16 + padding * 2)
        return CGRect(x: screen.midX - width / 2, y: max(screen.minY, screen.maxY - height - 12),
                      width: width, height: height)
    }

    static func chatFrame(in screen: CGRect) -> CGRect {
        let size = CGSize(width: min(320, screen.width), height: min(400, screen.height))
        return CGRect(x: max(screen.minX, screen.maxX - size.width - 20),
                      y: min(screen.maxY - size.height, screen.minY + 20), width: size.width, height: size.height)
    }

    static func handleFrame(for strip: CGRect) -> CGRect {
        CGRect(x: strip.midX - 22, y: strip.minY - 18, width: 44, height: 14)
    }

    static func stripFrame(forHandle handle: CGRect, stripSize: CGSize) -> CGRect {
        CGRect(x: handle.midX - stripSize.width / 2, y: handle.maxY + 4,
               width: stripSize.width, height: stripSize.height)
    }

    static func clampedStripFrame(_ frame: CGRect, in screen: CGRect) -> CGRect {
        let width = min(frame.width, screen.width)
        let height = min(frame.height, max(1, screen.height - 18))
        return CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY + 18), screen.maxY - height),
                      width: width, height: height)
    }

    static func pointerHidesStrip(_ point: CGPoint, frame: CGRect, wasHidden: Bool,
                                 handleFrame: CGRect? = nil, isDragging: Bool = false) -> Bool {
        guard !isDragging, handleFrame?.insetBy(dx: -4, dy: -4).contains(point) != true else { return false }
        return frame.insetBy(dx: wasHidden ? -32 : -14, dy: wasHidden ? -32 : -14).contains(point)
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

struct WhooshOverlayDrag {
    private var pointerOrigin: CGPoint?
    private var windowOrigin: CGPoint?

    mutating func begin(pointer: CGPoint, windowOrigin: CGPoint) {
        pointerOrigin = pointer
        self.windowOrigin = windowOrigin
    }
    func translatedOrigin(pointer: CGPoint) -> CGPoint? {
        guard let pointerOrigin, let windowOrigin else { return nil }
        return CGPoint(x: windowOrigin.x + pointer.x - pointerOrigin.x,
                       y: windowOrigin.y + pointer.y - pointerOrigin.y)
    }
    mutating func end() { pointerOrigin = nil; windowOrigin = nil }
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
    private var handlePanel: NSPanel?
    private var isDragging = false
    private var isPositioningHandle = false
    private var customStripAnchor: CGPoint?
    private var layoutSessionID: UUID?
    private var timer: Timer?
    private var stopped = false
    private var pointerHidden = false
    private var stripTargetAlpha: CGFloat?
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
        if layoutSessionID != meeting.sessionID {
            layoutSessionID = meeting.sessionID
            customStripAnchor = nil
        }
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

    private func updateStrip(on screen: NSScreen) {
        let participants = WhooshSharingOverlayLayout.participants(from: model.meeting.visibleParticipants)
        guard !participants.isEmpty else { dismissStrip(); return }
        var frame = WhooshSharingOverlayLayout.stripFrame(in: screen.visibleFrame, count: participants.count)
        if let customStripAnchor {
            frame.origin = CGPoint(x: customStripAnchor.x - frame.width / 2, y: customStripAnchor.y - frame.height)
        }
        frame = WhooshSharingOverlayLayout.clampedStripFrame(frame, in: screen.visibleFrame)
        if isDragging, let stripPanel { frame = stripPanel.frame }
        if stripPanel == nil {
            let panel = SharingPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            configure(panel)
            panel.ignoresMouseEvents = true
            panel.isMovable = false
            let content = NSHostingView(rootView: SharingParticipantStrip(model: model))
            content.sizingOptions = []
            panel.contentView = content
            stripPanel = panel
        }
        guard let panel = stripPanel else { return }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        updateHandle(for: frame)
        let hidden = WhooshSharingOverlayLayout.pointerHidesStrip(NSEvent.mouseLocation, frame: frame,
            wasHidden: pointerHidden, handleFrame: handlePanel?.frame, isDragging: isDragging)
        pointerHidden = hidden
        let alpha: CGFloat = hidden ? 0 : NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.90
        if stripTargetAlpha != alpha {
            let initialPresentation = stripTargetAlpha == nil
            stripTargetAlpha = alpha
            if initialPresentation || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.alphaValue = alpha
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    panel.animator().alphaValue = alpha
                }
            }
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func updateHandle(for strip: CGRect, duringDrag: Bool = false) {
        guard !isDragging || duringDrag else { return }
        let frame = WhooshSharingOverlayLayout.handleFrame(for: strip)
        if handlePanel == nil {
            let panel = SharingHandlePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: false)
            configure(panel)
            panel.delegate = self
            panel.isMovable = true
            let content = SharingDragHandleView(frame: CGRect(origin: .zero, size: frame.size))
            content.dragChanged = { [weak self] dragging in
                if !dragging { self?.synchronizeStripWithHandle() }
                self?.isDragging = dragging
                self?.refresh()
            }
            panel.contentView = content
            handlePanel = panel
        }
        guard let panel = handlePanel else { return }
        isPositioningHandle = true
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        isPositioningHandle = false
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    public func windowDidMove(_ notification: Notification) {
        guard !isPositioningHandle, let handle = handlePanel,
              notification.object as? NSWindow === handle else { return }
        synchronizeStripWithHandle()
    }

    private func synchronizeStripWithHandle() {
        guard let handle = handlePanel, let strip = stripPanel, let screen = sharingScreen() else { return }
        let proposed = WhooshSharingOverlayLayout.stripFrame(forHandle: handle.frame, stripSize: strip.frame.size)
        let frame = WhooshSharingOverlayLayout.clampedStripFrame(proposed, in: screen.visibleFrame)
        customStripAnchor = CGPoint(x: frame.midX, y: frame.maxY)
        strip.setFrame(frame, display: true)
        updateHandle(for: frame, duringDrag: true)
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
        handlePanel?.orderOut(nil)
        handlePanel?.contentView = nil
        handlePanel?.delegate = nil
        handlePanel = nil
        isDragging = false
        pointerHidden = false
        stripTargetAlpha = nil
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
private final class SharingHandlePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SharingDragHandleView: NSView {
    var dragChanged: ((Bool) -> Void)?
    private var drag = WhooshOverlayDrag()
    override init(frame: NSRect) {
        super.init(frame: frame)
        let content = NSHostingView(rootView:
            Capsule().fill(.secondary).frame(width: 20, height: 3)
                .frame(width: 44, height: 14)
                .modifier(SharingGlass())
                .allowsHitTesting(false))
        content.sizingOptions = []
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        toolTip = "Drag to move the participant strip"
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("Move participant strip")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        drag.begin(pointer: window.convertPoint(toScreen: event.locationInWindow), windowOrigin: window.frame.origin)
        dragChanged?(true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let origin = drag.translatedOrigin(pointer: window.convertPoint(toScreen: event.locationInWindow)) else { return }
        window.setFrameOrigin(origin)
    }
    override func mouseUp(with event: NSEvent) {
        drag.end()
        dragChanged?(false)
    }
}

private struct SharingParticipantStrip: View {
    @Bindable var model: WhooshModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WhooshSharingOverlayLayout.participants(from: model.meeting.visibleParticipants)) { participant in
                ParticipantTile(participant: participant, meeting: model.meeting, preservesRendererSize: true)
                    .aspectRatio(16 / 9, contentMode: .fit)
            }
        }
        .padding(8)
        .modifier(SharingGlass())
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
