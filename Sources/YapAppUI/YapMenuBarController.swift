import AppKit
import Observation
import YapCalendar
import YapSystem

let yapShowScheduleMenu = Notification.Name("com.grinich.yap.show-schedule-menu")

enum YapMenuBarPrimaryAction: Equatable {
    case openYap, joinMeeting, returnToMeeting, stopSharing
    var title: String {
        switch self {
        case .openYap: "Yap"
        case .joinMeeting: "Join meeting"
        case .returnToMeeting: "Return to meeting"
        case .stopSharing: "Stop sharing"
        }
    }
}

/// Explicit meeting actions share the agenda's refresh, ambiguity, and media-default rules.
@MainActor @Observable
final class YapMenuBarActionHandler {
    private let model: YapModel
    private let openMainWindow: () -> Void
    private let toggleMainWindow: () -> Void
    @ObservationIgnored private let now: () -> Date
    private var eligibilityRevision = 0
    private(set) var isPerforming = false

    init(model: YapModel, now: @escaping () -> Date = { .now },
         toggleMainWindow: (() -> Void)? = nil, openMainWindow: @escaping () -> Void) {
        self.model = model
        self.now = now
        self.openMainWindow = openMainWindow
        self.toggleMainWindow = toggleMainWindow ?? openMainWindow
    }

    var primaryAction: YapMenuBarPrimaryAction {
        if model.meeting.sharing.isSharing { return .stopSharing }
        if model.activeCall { return .returnToMeeting }
        return eligibleMeeting == nil ? .openYap : .joinMeeting
    }

    private var eligibleMeeting: CalendarEvent? {
        _ = eligibilityRevision
        let currentTime = now()
        guard let event = AgendaRules.upcoming(model.events, now: currentTime).first,
              AgendaRules.showsJoinButton(for: event, now: currentTime) else { return nil }
        return event
    }

    var displayedMeetingID: String? { primaryAction == .joinMeeting ? eligibleMeeting?.id : nil }
    var primaryActionTitle: String {
        if primaryAction == .joinMeeting, let event = eligibleMeeting { return "Join \(event.title)" }
        if primaryAction == .returnToMeeting { return model.meeting.displayTitle }
        return primaryAction.title
    }
    var primaryActionSymbolName: String? { primaryAction == .returnToMeeting ? "video.fill" : nil }
    var nextEligibilityChange: Date? {
        let currentTime = now()
        guard !model.activeCall, let event = AgendaRules.upcoming(model.events, now: currentTime).first else { return nil }
        let opensAt = event.startDate.addingTimeInterval(-5 * 60)
        return opensAt > currentTime ? opensAt : event.endDate
    }
    func refreshEligibility() { eligibilityRevision += 1 }

    var canPerformPrimaryAction: Bool {
        if primaryAction == .stopSharing {
            return model.meeting.isConnected && !model.meeting.isApplyingControl && !isPerforming
        }
        return primaryAction == .openYap || model.activeCall || !isPerforming
    }

    func performPrimaryAction(expectedAction: YapMenuBarPrimaryAction? = nil, expectedMeetingID: String? = nil,
                              expectedSessionID: UUID? = nil) async {
        guard !Task.isCancelled else { return }
        // A queued Stop click must never become Join if the session ends before
        // its task runs. Likewise, an old Join click cannot become Stop sharing.
        if let expectedAction, expectedAction != primaryAction { return }
        if let expectedSessionID, expectedSessionID != model.meeting.sessionID { return }
        if primaryAction == .stopSharing {
            guard canPerformPrimaryAction else { return }
            isPerforming = true
            defer { isPerforming = false }
            // The confirmed sharing callback alone changes this button back.
            await model.meeting.stopShare()
            return
        }
        if primaryAction == .openYap { toggleMainWindow(); return }
        if primaryAction == .returnToMeeting { openMainWindow(); return }
        guard let event = eligibleMeeting, !isPerforming else { return }
        let requestedEventID = expectedMeetingID ?? event.id
        guard event.id == requestedEventID else { return }
        openMainWindow()
        isPerforming = true
        defer { isPerforming = false }
        await model.joinNextCalendarMeeting(expectedEventID: requestedEventID)
    }

    func joinScheduleEvent(id: String) async {
        guard !Task.isCancelled, !model.activeCall, !isPerforming else { return }
        isPerforming = true
        defer { isPerforming = false }
        openMainWindow()
        // The model refreshes and finds this exact occurrence again; a stale
        // menu cannot redirect the click to a different event or account.
        await model.joinNextCalendarMeeting(expectedEventID: id)
    }

    func openSettings() {
        openMainWindow()
        model.showSettings = true
    }

    func connectCalendar() async {
        guard !Task.isCancelled, !model.isConnecting else { return }
        openMainWindow()
        await model.connectGoogle()
    }

    func openYap() { openMainWindow() }

    func joinWithLink() {
        openMainWindow()
        guard !model.activeCall, !isPerforming else { return }
        showJoinSheet()
    }

    var sharingChatIsVisible: Bool? {
        guard model.meeting.sharing.isSharing else { return nil }
        return model.sidebar == .chat
    }

    func setSharingChatVisible(_ visible: Bool, expectedSessionID: UUID? = nil) {
        guard model.meeting.sharing.isSharing else { return }
        if let expectedSessionID, expectedSessionID != model.meeting.sessionID { return }
        if visible {
            model.sidebar = .chat
        } else if model.sidebar == .chat {
            model.sidebar = nil
        }
    }

    private func showJoinSheet() {
        // A second click must not erase a link already being edited.
        guard !model.showJoinSheet else { return }
        model.selectedEvent = nil
        model.joinLink = ""
        model.showJoinSheet = true
    }
}

/// Uses the supported NSStatusItem.button target/action API. The decorative
/// child draws only the requested blue appearance; the standard AppKit button
/// owns mouse tracking, accessibility, and the menu bar's native highlight.
@MainActor
final class YapMenuBarController: NSObject {
    private let model: YapModel
    private let openMainWindow: () -> Void
    private let actions: YapMenuBarActionHandler
    private let statusItem: NSStatusItem
    private let pill = YapMenuBarPill(frame: .zero)
    private var actionTask: Task<Void, Never>?
    private var eligibilityTimer: Timer?
    private var calendarRefreshError: String?
    private var failedRefreshSnapshot: Date?
    private var stopped = false

    init(model: YapModel, toggleMainWindow: (() -> Void)? = nil, openMainWindow: @escaping () -> Void) {
        self.model = model
        self.openMainWindow = openMainWindow
        actions = YapMenuBarActionHandler(model: model, toggleMainWindow: toggleMainWindow,
                                            openMainWindow: openMainWindow)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.autosaveName = "YapJoinMeeting"
        NotificationCenter.default.addObserver(self, selector: #selector(showScheduleFromCommand), name: yapShowScheduleMenu, object: nil)
        if let button = statusItem.button {
            button.title = ""
            button.target = self
            button.action = #selector(buttonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityRole(.button)
            button.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "Show schedule", target: self, selector: #selector(showAccessibleMenu))
            ])
            pill.frame = button.bounds
            pill.autoresizingMask = [.width, .height]
            button.addSubview(pill)
        }
        renderAndObserve()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        NotificationCenter.default.removeObserver(self, name: yapShowScheduleMenu, object: nil)
        actionTask?.cancel()
        actionTask = nil
        eligibilityTimer?.invalidate()
        eligibilityTimer = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func renderAndObserve() {
        guard !stopped else { return }
        withObservationTracking {
            let action = actions.primaryAction
            let summary = MenuBarSchedule(events: model.events).summary
            let title: String
            if action == .stopSharing || action == .returnToMeeting { title = actions.primaryActionTitle }
            else if let summary {
                title = "\(MenuBarSchedule.compactTitle(summary.event.title, limit: 25)) · \(summary.isCurrent ? "Now" : summary.relativeTime.lowercased())"
            } else { title = "Yap" }
            let tooltip: String
            if action == .stopSharing { tooltip = "Stop sharing your screen · Right-click for your schedule and meeting controls" }
            else if action == .returnToMeeting { tooltip = "\(actions.primaryActionTitle) · Show your schedule and meeting controls" }
            else if let summary { tooltip = "\(summary.event.title) · \(summary.relativeTime) · Click for your schedule" }
            else { tooltip = "Show your schedule" }
            let recordingStatus = MeetingCloudRecordingControlsState(meeting: model.meeting).statusLabel
            let fullTooltip = recordingStatus.map { tooltip + " · " + $0 } ?? tooltip
            pill.title = title
            pill.symbolName = actions.primaryActionSymbolName
            pill.isDestructive = action == .stopSharing
            pill.isEnabled = action != .stopSharing || actions.canPerformPrimaryAction
            statusItem.length = pill.preferredWidth
            statusItem.button?.isEnabled = pill.isEnabled
            statusItem.button?.toolTip = fullTooltip
            statusItem.button?.setAccessibilityLabel(title)
            statusItem.button?.setAccessibilityHelp(fullTooltip)
        } onChange: { [weak self] in
            // Observation's notification precedes the mutation. Render on the
            // next main-actor turn and re-arm this one-shot observation.
            Task { @MainActor [weak self] in self?.renderAndObserve() }
        }
        scheduleEligibilityRefresh()
    }

    private func scheduleEligibilityRefresh() {
        eligibilityTimer?.invalidate()
        eligibilityTimer = nil
        // Refresh countdowns even when no model mutation occurs, including midnight.
        let nextMinute = Date(timeIntervalSince1970: (floor(Date.now.timeIntervalSince1970 / 60) + 1) * 60)
        let boundary = min(actions.nextEligibilityChange ?? nextMinute, nextMinute)
        let timer = Timer(fire: boundary, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.actions.refreshEligibility() }
        }
        eligibilityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func buttonClicked() {
        if let event = NSApplication.shared.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
            return
        }
        // Opening the schedule is read-only. Screen sharing retains its immediate stop button.
        guard actions.primaryAction == .stopSharing else {
            showContextMenu()
            return
        }
        guard actionTask == nil else { return }
        let requestedAction = actions.primaryAction
        let requestedMeetingID = actions.displayedMeetingID
        let requestedSessionID = model.meeting.sessionID
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.actionTask = nil }
            await self.actions.performPrimaryAction(expectedAction: requestedAction, expectedMeetingID: requestedMeetingID,
                                                    expectedSessionID: requestedSessionID)
        }
    }

    @objc private func showScheduleFromCommand() {
        // End application-menu tracking before opening the status-item menu.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.showContextMenu()
            }
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        if lastSuccessfulRefreshChanged { calendarRefreshError = nil }
        let schedule = MenuBarSchedule(events: model.events)
        let builder = MenuBarScheduleMenu(schedule: schedule, calendars: model.calendars,
            state: calendarState, isRefreshing: model.isRefreshing, refreshError: calendarRefreshError,
            allowsJoining: !model.activeCall && !actions.isPerforming) { [weak self] request in
                self?.performScheduleRequest(request)
            }
        let menu = builder.menu
        menu.addItem(.separator())
        if model.meeting.sharing.isSharing, let sessionID = model.meeting.sessionID {
            let stop = NSMenuItem(title: "Stop sharing", action: #selector(stopSharingFromMenu(_:)), keyEquivalent: "")
            stop.target = self
            stop.representedObject = sessionID
            stop.isEnabled = actions.canPerformPrimaryAction
            stop.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            menu.insertItem(stop, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        if let visible = actions.sharingChatIsVisible, let sessionID = model.meeting.sessionID {
            let chat = NSMenuItem(title: visible ? "Hide Chat" : "Show Chat", action: #selector(setSharingChatVisibility), keyEquivalent: "")
            chat.target = self
            chat.representedObject = SharingChatMenuAction(visible: !visible, sessionID: sessionID)
            menu.addItem(chat)
            menu.addItem(.separator())
        }
        if model.activeCall {
            addCloudRecordingItems(to: menu)
            menu.addItem(.separator())
        }
        let open = NSMenuItem(title: model.activeCall ? "Return to meeting" : "Open Yap", action: #selector(openYap), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let join = NSMenuItem(title: "Join with a link…", action: #selector(joinWithLink), keyEquivalent: "")
        join.target = self
        join.isEnabled = !model.activeCall && !actions.isPerforming
        menu.addItem(join)
        let refresh = NSMenuItem(title: model.isRefreshing ? "Refreshing calendar…" : "Refresh calendar", action: #selector(refreshCalendar), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = model.isCalendarConnected && !model.isPreview && !model.isRefreshing
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        if let date = model.lastRefreshed { refresh.toolTip = "Last updated \(date.formatted(date: .abbreviated, time: .shortened))" }
        menu.addItem(refresh)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Yap", action: #selector(quitYap), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        _ = withExtendedLifetime(builder) {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        }
    }

    private var lastSuccessfulRefreshChanged: Bool {
        calendarRefreshError != nil && model.lastRefreshed != failedRefreshSnapshot
    }

    private var calendarState: MenuBarScheduleState {
        if model.isPreview { return .ready }
        if model.googleConfigurationLoadState == .pending || model.googleConfigurationLoadState == .loading || model.isConnecting { return .loading }
        if model.googleConfigurationLoadState == .failed { return .unavailable }
        if !model.isCalendarConnected { return .disconnected }
        if model.selectedCalendarIDs.isEmpty { return .noCalendars }
        if model.events.isEmpty && model.isRefreshing { return .loading }
        return .ready
    }

    private func performScheduleRequest(_ request: MenuBarScheduleRequest) {
        switch request {
        case .join(let eventID):
            guard actionTask == nil else { return }
            actionTask = Task { [weak self] in
                guard let self else { return }
                defer { self.actionTask = nil }
                await self.actions.joinScheduleEvent(id: eventID)
            }
        case .openCalendar(let url): NSWorkspace.shared.open(url)
        case .connectCalendar:
            Task { [weak self] in await self?.actions.connectCalendar() }
        case .settings: openSettings()
        }
    }

    @objc private func stopSharingFromMenu(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? UUID, actionTask == nil else { return }
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.actionTask = nil }
            await self.actions.performPrimaryAction(expectedAction: .stopSharing, expectedSessionID: sessionID)
        }
    }

    @objc private func refreshCalendar() {
        guard model.isCalendarConnected, !model.isRefreshing else { return }
        Task { [weak self] in
            guard let self else { return }
            if await self.model.refresh() { self.calendarRefreshError = nil }
            else {
                self.calendarRefreshError = "Your saved schedule may be out of date. Try refreshing again."
                self.failedRefreshSnapshot = self.model.lastRefreshed
            }
        }
    }

    private func addCloudRecordingItems(to menu: NSMenu) {
        let state = MeetingCloudRecordingControlsState(meeting: model.meeting)
        let header = NSMenuItem(title: state.statusLabel ?? "Cloud Recording", action: nil, keyEquivalent: "")
        header.isEnabled = false
        if state.recording.status.isActive {
            header.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: state.statusLabel)?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        }
        menu.addItem(header)
        for action in state.actions {
            let item = NSMenuItem(title: action.title, action: #selector(performCloudRecordingAction), keyEquivalent: "")
            item.target = self
            item.isEnabled = state.canPerform(action)
            item.toolTip = state.disabledReason ?? action.title
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            if let sessionID = model.meeting.sessionID {
                item.representedObject = CloudRecordingMenuAction(action: action, sessionID: sessionID)
            } else { item.isEnabled = false }
            menu.addItem(item)
        }
    }

    @objc private func performCloudRecordingAction(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? CloudRecordingMenuAction else { return }
        let meeting = model.meeting
        Task { await MeetingCloudRecordingRouting.perform(request.action, sessionID: request.sessionID, in: meeting) }
    }

    @objc private func showAccessibleMenu() -> Bool {
        guard !stopped, statusItem.button != nil else { return false }
        showContextMenu()
        return true
    }
    @objc private func setSharingChatVisibility(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? SharingChatMenuAction else { return }
        actions.setSharingChatVisible(action.visible, expectedSessionID: action.sessionID)
    }
    @objc private func openYap() {
        DispatchQueue.main.async { [weak self] in self?.actions.openYap() }
    }
    @objc private func joinWithLink() {
        DispatchQueue.main.async { [weak self] in self?.actions.joinWithLink() }
    }
    @objc private func openSettings() {
        DispatchQueue.main.async { [weak self] in self?.actions.openSettings() }
    }
    @objc private func quitYap() { NSApplication.shared.terminate(nil) }
}

private struct SharingChatMenuAction {
    let visible: Bool
    let sessionID: UUID
}

private struct CloudRecordingMenuAction {
    let action: MeetingCloudRecordingAction
    let sessionID: UUID
}

@MainActor
private final class YapMenuBarPill: NSView {
    var title = "Join meeting" { didSet { if title != oldValue { needsDisplay = true } } }
    var symbolName: String? {
        didSet {
            guard symbolName != oldValue else { return }
            symbol = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)
                    .applying(.init(paletteColors: [.white])))
            symbol?.isTemplate = false
            needsDisplay = true
        }
    }
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }
    var isDestructive = false { didSet { if isDestructive != oldValue { needsDisplay = true } } }
    private var symbol: NSImage?
    private let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private var displayTitle: String { title.split(whereSeparator: \.isNewline).joined(separator: " ") }
    private var symbolLeadingWidth: CGFloat { symbol == nil ? 0 : 19 }
    var preferredWidth: CGFloat { min(240, ceil((displayTitle as NSString).size(withAttributes: [.font: font]).width) + 26 + symbolLeadingWidth) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 4, dy: max(2, (bounds.height - 20) / 2))
        guard rect.width > 0, rect.height > 0 else { return }
        // A semantic system blue, resolved by AppKit for the current appearance.
        let color = isDestructive ? NSColor.systemRed : NSColor.systemBlue
        color.withAlphaComponent(isEnabled ? 1 : 0.55).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
        let height = ceil(font.ascender - font.descender + font.leading)
        if let symbol, symbol.size.width > 0, symbol.size.height > 0 {
            let scale = min(14 / symbol.size.width, 14 / symbol.size.height)
            let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            symbol.draw(in: NSRect(x: rect.minX + 9 + (14 - size.width) / 2, y: rect.midY - size.height / 2,
                                  width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }
        let textRect = NSRect(x: rect.minX + 9 + symbolLeadingWidth, y: round(rect.midY - height / 2),
                             width: max(0, rect.width - 18 - symbolLeadingWidth), height: height)
        (displayTitle as NSString).draw(in: textRect, withAttributes: attributes)
    }
}
