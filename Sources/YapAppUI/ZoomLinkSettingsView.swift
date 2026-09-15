import AppKit
import SwiftUI
import YapSystem

struct ZoomLinkSettingsView: View {
    @State private var service: ZoomLinkHandlerService
    @State private var status: ZoomLinkHandlerStatus
    @State private var isChanging = false
    @State private var errorMessage: String?
    @State private var requestedChoice: ZoomLinkHandlerChoice?

    init() {
        let service = ZoomLinkHandlerService()
        _service = State(initialValue: service)
        _status = State(initialValue: service.status())
    }

    var body: some View {
        Section("Meeting links") {
            HStack(spacing: 20) {
                SettingsLabel(title: "Open Zoom links with", detail: "The app your browser opens when you join a Zoom meeting.")
                Spacer(minLength: 0)
                SettingsChoiceMenu(title: "Open Zoom links with", selection: Binding(
                    get: { selection },
                    set: { if let choice = $0 { select(choice) } }
                ), choices: choices)
                .frame(width: 190)
                .disabled(isChanging)
                .accessibilityIdentifier("zoomLinkHandlerPicker")
            }
            if isChanging {
                ProgressView("Updating your Mac’s setting…").controlSize(.small)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .task { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !isChanging { refresh() }
        }
    }

    private var choices: [SettingsChoice<ZoomLinkHandlerChoice?>] {
        var items: [SettingsChoice<ZoomLinkHandlerChoice?>] = []
        if selection == nil {
            items.append(SettingsChoice(value: nil, title: currentLabel, isEnabled: false))
        }
        items += ZoomLinkHandlerChoice.allCases.map { choice in
            let installed = status.applicationURL(for: choice) != nil
            return SettingsChoice(value: Optional(choice), title: installed ? choice.displayName : "\(choice.displayName) (not installed)", isEnabled: installed)
        }
        return items
    }

    private var selection: ZoomLinkHandlerChoice? {
        switch status.current {
        case .yap: .yap
        case .zoom: .zoom
        default: nil
        }
    }

    private var currentLabel: String {
        switch status.current {
        case .mixed: "Multiple apps"
        case .other: "Another app"
        case .unset: "No app selected"
        case .yap: "Yap"
        case .zoom: "Zoom Workplace"
        }
    }

    private func refresh() {
        status = service.status()
        if let requestedChoice, status.isApplied(requestedChoice) { errorMessage = nil }
    }

    private func select(_ choice: ZoomLinkHandlerChoice) {
        guard !isChanging else { return }
        isChanging = true
        requestedChoice = choice
        errorMessage = nil
        Task {
            defer { refresh(); isChanging = false }
            do { status = try await service.select(choice) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
