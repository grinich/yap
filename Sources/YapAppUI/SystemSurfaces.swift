import SwiftUI
import AppKit
import YapSystem

private let yapMainWindowAttached = Notification.Name("com.grinich.yap.main-window-attached")
let yapMainWindowWillHide = Notification.Name("com.grinich.yap.main-window-will-hide")

/// Window focus changes are frequent; only a real hide/reveal refreshes the library.
struct YapRecordingsWindowReveal {
    private var isAwaitingReveal = false

    mutating func windowWillHide() { isAwaitingReveal = true }

    mutating func shouldRefresh(isVisible: Bool, isMiniaturized: Bool, isApplicationHidden: Bool,
                                recordingsPresented: Bool, isPreview: Bool, isAccountBusy: Bool,
                                hasActiveCall: Bool) -> Bool {
        guard isAwaitingReveal, isVisible, !isMiniaturized, !isApplicationHidden else { return false }
        // Consume even an ineligible reveal: the view's presentation task owns
        // a later account/preview transition or opening the recordings pane.
        isAwaitingReveal = false
        return recordingsPresented && !isPreview && !isAccountBusy && !hasActiveCall
    }
}

public struct YapMenuBarView: View {
    @Bindable var model: YapModel
    @Environment(\.openWindow) private var openWindow
    public init(model: YapModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { YapMark(size: 28); Text("Yap").font(.headline); Spacer(); if model.isPreview { Text("Preview").font(.caption).foregroundStyle(.orange) } }
            if model.activeCall {
                Text(model.meeting.meetingTitle).font(.system(size: 16, weight: .semibold))
                Text(model.meeting.status.label).foregroundStyle(.secondary)
                HStack {
                    Button(model.meeting.isMicrophoneMuted ? "Unmute" : "Mute") { Task { await model.meeting.setMicrophoneMuted(!model.meeting.isMicrophoneMuted) } }
                    if model.meeting.sharing.isSharing { Button("Stop sharing", role: .destructive) { Task { await model.meeting.stopShare() } } }
                }.disabled(!model.meeting.isConnected || model.meeting.isApplyingControl)
            } else if let event = model.nextMeeting {
                Text("UP NEXT").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(.secondary)
                Text(event.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                Text(event.startDate, style: .time).foregroundStyle(.secondary)
                Button(model.isPreview ? "Preview meeting" : "Join meeting") { showMain(); Task { await model.handleSystemAction(.joinNextMeeting) } }
                    .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
            } else {
                Text(model.isCalendarConnected ? "No upcoming Zoom meetings." : "Connect your calendar to bring your next meeting here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            Button(model.activeCall ? "Return to meeting" : "Open Yap") { showMain() }.buttonStyle(.plain)
            Button("Quit Yap") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }.padding(22).frame(width: 280).tint(YapTheme.accent)
    }

    private func showMain() { openWindow(id: "main"); NSApplication.shared.activate() }
}

public struct YapCommands: Commands {
    let model: YapModel
    @Environment(\.openWindow) private var openWindow
    public init(model: YapModel) { self.model = model }

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Yap") { YapSystemActions.request(.openYap) }.keyboardShortcut("0", modifiers: .command)
            Button("Join with a link…") {
                openWindow(id: "main"); model.selectedEvent = nil; model.joinLink = ""; model.showJoinSheet = true
            }.keyboardShortcut("j", modifiers: .command).disabled(model.activeCall)
            Button("Join next meeting") { openWindow(id: "main"); Task { await model.handleSystemAction(.joinNextMeeting) } }
                .keyboardShortcut(.return, modifiers: .command).disabled(model.nextMeeting == nil || model.activeCall)
            Button("Start a meeting") { openWindow(id: "main"); Task { await model.hostMeeting() } }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.activeCall)
        }
        CommandGroup(after: .toolbar) {
            Button(model.recordings.isPresented ? "Hide Recordings" : "Show Recordings") {
                openWindow(id: "main")
                model.recordings.toggle()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.activeCall)
            Button("Refresh Calendar") { Task { await model.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.isCalendarConnected || model.isRefreshing || model.isPreview || model.activeCall)
        }
        CommandGroup(replacing: .help) {
            Link("Report a Bug", destination: URL(string: "https://github.com/grinich/yap/issues/new/choose")!)
        }
        CommandMenu("Meeting") {
            Button(model.meeting.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone") { Task { await model.meeting.setMicrophoneMuted(!model.meeting.isMicrophoneMuted) } }
                .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(!model.meeting.isConnected || model.meeting.isApplyingControl)
            Button(model.meeting.isCameraEnabled ? "Turn camera off" : "Turn camera on") { Task { await model.meeting.setCameraEnabled(!model.meeting.isCameraEnabled) } }
                .keyboardShortcut("v", modifiers: [.command, .shift]).disabled(!model.meeting.isConnected || model.meeting.isApplyingControl)
            Button(model.sidebar == .chat ? "Hide Chat" : "Show Chat") { openWindow(id: "main"); NSApplication.shared.activate(); model.sidebar = model.sidebar == .chat ? nil : .chat }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(!model.meeting.isConnected)
            Button(model.sidebar == .people ? "Hide People" : "Show People") { openWindow(id: "main"); NSApplication.shared.activate(); model.sidebar = model.sidebar == .people ? nil : .people }.disabled(!model.meeting.isConnected)
            Button("Stop sharing") { Task { await model.meeting.stopShare() } }.disabled(!model.meeting.sharing.isSharing || !model.meeting.isConnected || model.meeting.isApplyingControl)
            Divider()
            MeetingCloudRecordingMenuItems(meeting: model.meeting)
            Divider()
            Button("Leave meeting…") { model.showLeaveConfirmation = true }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(!model.activeCall)
        }
    }
}

@MainActor
public final class YapApplicationDelegate: NSObject, NSApplicationDelegate {
    public weak var model: YapModel?
    private var openMainWindow: (() -> Void)?
    private var routingTask: Task<Void, Never>?
    private var isObservingActions = false
    private var menuBarController: YapMenuBarController?
    private var sharingOverlayController: YapSharingOverlayController?
    private let incomingURLs = YapIncomingURLRouter()
    private var recordingsWindowReveal = YapRecordingsWindowReveal()
    private lazy var windowPresenter = YapMainWindowPresenter(actions: .init(
        afterMenuTracking: { action in
            RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { action() } }
        },
        openWindow: { [weak self] in self?.openMainWindow?() },
        revealApplication: {
            if NSApplication.shared.isHidden { NSApplication.shared.unhide(nil) }
            NSApplication.shared.activate()
        },
        applicationIsActive: { NSApplication.shared.isActive },
        restoreWindow: { [weak self] in
            guard let window = self?.model?.sharingPresentation.mainWindow else { return nil }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            if let sheet = window.attachedSheet { sheet.makeKeyAndOrderFront(nil) }
            return YapMainWindowState(isVisible: window.isVisible,
                isMiniaturized: window.isMiniaturized,
                isKey: window.isKeyWindow || window.attachedSheet?.isKeyWindow == true)
        },
        activateApplication: { completion in
            let applicationURL = NSRunningApplication.current.bundleURL ?? Bundle.main.bundleURL
            guard applicationURL.pathExtension.lowercased() == "app" else { completion(false); return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            configuration.allowsRunningApplicationSubstitution = false
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in
                let succeeded = error == nil && application?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                Task { @MainActor in completion(succeeded) }
            }
        }))

    public func configure(model: YapModel, openMainWindow: @escaping () -> Void) {
        self.model = model
        self.openMainWindow = openMainWindow
        if sharingOverlayController == nil {
            sharingOverlayController = YapSharingOverlayController(model: model) { [weak self] in
                self?.presentMainWindow()
            }
        }
        if menuBarController == nil {
            menuBarController = YapMenuBarController(model: model,
                toggleMainWindow: { [weak self] in self?.toggleMainWindow() },
                openMainWindow: { [weak self] in self?.presentMainWindow() })
        }
        if !isObservingActions {
            NotificationCenter.default.addObserver(self, selector: #selector(systemActionRequested), name: YapSystemActions.notificationName, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(mainWindowAttached), name: yapMainWindowAttached, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(mainWindowWillHide), name: yapMainWindowWillHide, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(mainWindowDidMiniaturize), name: NSWindow.didMiniaturizeNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(mainWindowBecameAvailable), name: NSWindow.didBecomeKeyNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(mainWindowBecameAvailable), name: NSWindow.didDeminiaturizeNotification, object: nil)
            isObservingActions = true
        }
        incomingURLs.configure { [weak self, weak model] url in
            if YapDeepLink.isOpenAppURL(url) {
                self?.presentMainWindow()
                return
            }
            model?.receiveMeetingLink(url)
            self?.presentMainWindow()
        }
        drainActions()
    }

    @objc private func systemActionRequested() {
        presentMainWindow()
        drainActions()
    }

    private func presentMainWindow() {
        windowPresenter.request()
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        // Handle URL delivery at the application boundary, including cold launch
        // before SwiftUI attaches the main window and while Settings is in front.
        guard !urls.isEmpty else { return }
        YapSystemActions.discardPendingMeetingNavigation()
        incomingURLs.receive(urls)
    }

    func toggleMainWindow() {
        guard let window = model?.sharingPresentation.mainWindow,
              NSApplication.shared.isActive, !NSApplication.shared.isHidden,
              window.isVisible, !window.isMiniaturized, window.isOnActiveSpace,
              window.isKeyWindow || window.attachedSheet?.isKeyWindow == true else {
            presentMainWindow()
            return
        }
        model?.recordings.suspendPlayback()
        if let model { NotificationCenter.default.post(name: yapMainWindowWillHide, object: model) }
        window.attachedSheet?.orderOut(nil)
        window.orderOut(nil)
    }

    @objc private func mainWindowAttached(_ notification: Notification) {
        guard notification.object as? YapModel === model else { return }
        windowPresenter.windowOrActivationChanged()
    }

    @objc private func mainWindowWillHide(_ notification: Notification) {
        guard notification.object as? YapModel === model else { return }
        recordingsWindowReveal.windowWillHide()
        windowPresenter.cancel()
    }

    @objc private func mainWindowDidMiniaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === model?.sharingPresentation.mainWindow else { return }
        recordingsWindowReveal.windowWillHide()
    }

    @objc private func mainWindowBecameAvailable(_ notification: Notification) {
        guard notification.object as? NSWindow === model?.sharingPresentation.mainWindow else { return }
        if let recordings = model?.recordings, recordings.isPresented {
            recordings.prepareForPresentation()
        }
        windowPresenter.windowOrActivationChanged()
        refreshRecordingsAfterWindowReveal()
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        windowPresenter.windowOrActivationChanged()
        refreshRecordingsAfterWindowReveal()
    }

    public func applicationWillHide(_ notification: Notification) {
        guard model?.sharingPresentation.mainWindow != nil else { return }
        recordingsWindowReveal.windowWillHide()
    }

    public func applicationDidUnhide(_ notification: Notification) {
        refreshRecordingsAfterWindowReveal()
    }

    private func refreshRecordingsAfterWindowReveal() {
        guard let model, let window = model.sharingPresentation.mainWindow,
              recordingsWindowReveal.shouldRefresh(isVisible: window.isVisible,
                  isMiniaturized: window.isMiniaturized, isApplicationHidden: NSApplication.shared.isHidden,
                  recordingsPresented: model.recordings.isPresented, isPreview: model.isPreview,
                  isAccountBusy: model.zoomConnection.isBusy, hasActiveCall: model.activeCall) else { return }
        let accountRevision = model.zoomConnection.accountRevision
        Task { @MainActor [weak model] in
            guard let model, model.recordings.isPresented, !model.isPreview, !model.activeCall,
                  !model.zoomConnection.isBusy, model.zoomConnection.accountRevision == accountRevision,
                  let window = model.sharingPresentation.mainWindow, window.isVisible,
                  !window.isMiniaturized, !NSApplication.shared.isHidden else { return }
            await model.recordings.refreshForPresentation()
        }
    }

    private func drainActions() {
        guard routingTask == nil, let model else { return }
        routingTask = Task { [weak self] in
            defer { self?.routingTask = nil }
            await model.start()
            await model.handleSystemActions()
        }
    }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationWillTerminate(_ notification: Notification) {
        model?.recordings.stopPlayback()
        model?.recordings.closePlayerWindows()
        model?.recordings.chat.clear()
        windowPresenter.cancel()
        sharingOverlayController?.stop()
        menuBarController?.stop()
    }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.activeCall else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Leave the meeting and quit Yap?"
        alert.informativeText = "Your microphone, camera, and screen sharing will stop."
        alert.addButton(withTitle: "Leave and quit")
        alert.addButton(withTitle: "Stay in meeting")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            await model.leaveMeeting()
            let ended = await model.meeting.waitForMeetingEnd()
            if !ended { model.error = "Zoom hasn’t confirmed that the meeting ended. Yap is still open; try leaving again." }
            sender.reply(toApplicationShouldTerminate: ended)
        }
        return .terminateLater
    }
}

struct WindowBehavior: NSViewRepresentable {
    let model: YapModel
    let title: String
    let showsCloseButton: Bool
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onWindow = { [weak coordinator = context.coordinator] window in
            guard let window else { return }
            coordinator?.attach(to: window)
            configureAppearance(of: window)
            coordinator?.configureCloseButton(in: window, isVisible: showsCloseButton)
            window.tabbingMode = .disallowed
            window.isMovableByWindowBackground = false
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window {
            configureAppearance(of: window)
            context.coordinator.configureCloseButton(in: window, isVisible: showsCloseButton)
        }
    }

    private func configureAppearance(of window: NSWindow) {
        window.title = title
        window.titleVisibility = .hidden
        // Joining removes the agenda toolbar. Preserve a full-size content view
        // so the shared backdrop still reaches behind the standard traffic lights.
        // Transparency alone leaves a separate blank titlebar in that state.
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let model: YapModel
        private weak var window: NSWindow?
        private let closeButton = YapWindowCloseButton(frame: .zero)
        // NSObject's selector lookup is nonisolated; the weak reference is only
        // replaced during main-actor window attachment and never owns its target.
        nonisolated(unsafe) private weak var originalDelegate: (any NSWindowDelegate)?
        init(model: YapModel) {
            self.model = model
            super.init()
            closeButton.target = self
            closeButton.action = #selector(closeWindow)
            closeButton.keyEquivalent = "w"
            closeButton.keyEquivalentModifierMask = [.command]
        }
        func configureCloseButton(in window: NSWindow, isVisible: Bool) {
            guard let frameView = window.contentView?.superview else { return }
            if closeButton.superview !== frameView {
                closeButton.removeFromSuperview()
                frameView.addSubview(closeButton, positioned: .above, relativeTo: nil)
            }
            // Anchor to the full window frame. AppKit moves its hidden standard
            // buttons when an empty toolbar collapses, so their frames are not
            // stable positioning guides for this independent close control.
            closeButton.frame = NSRect(x: 12, y: frameView.isFlipped ? 12 : frameView.bounds.height - 36,
                                       width: 24, height: 24)
            closeButton.autoresizingMask = [.maxXMargin, frameView.isFlipped ? .maxYMargin : .minYMargin]
            let opacity: CGFloat = isVisible ? 1 : 0
            if closeButton.alphaValue != opacity {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
                    closeButton.animator().alphaValue = opacity
                }
            }
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = true
            }
        }
        @objc private func closeWindow() {
            guard let window else { return }
            _ = windowShouldClose(window)
        }
        func attach(to window: NSWindow) {
            guard window.delegate !== self else { return }
            detach()
            self.window = window
            model.sharingPresentation.mainWindow = window
            originalDelegate = window.delegate
            window.delegate = self
            NotificationCenter.default.post(name: yapMainWindowAttached, object: model)
        }
        func detach() {
            closeButton.removeFromSuperview()
            if model.sharingPresentation.mainWindow === window { model.sharingPresentation.mainWindow = nil }
            if window?.delegate === self { window?.delegate = originalDelegate }
            window = nil
            originalDelegate = nil
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if originalDelegate?.responds(to: selector) == true { return originalDelegate }
            return super.forwardingTarget(for: selector)
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if model.activeCall {
                model.showLeaveConfirmation = true
                return false
            }
            model.recordings.suspendPlayback()
            // The menu-bar app keeps one main window. Hiding it directly avoids
            // SwiftUI's close/recreation lifecycle and preserves the window to
            // reopen from the menu bar. Cancel an outstanding reveal first.
            NotificationCenter.default.post(name: yapMainWindowWillHide, object: model)
            sender.attachedSheet?.orderOut(nil)
            sender.orderOut(nil)
            return false
        }
    }
    @MainActor final class TrackingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow?(window) }
    }
}
