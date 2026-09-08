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
            Picker("Open Zoom links with", selection: Binding(
                get: { selection },
                set: { if let choice = $0 { select(choice) } }
            )) {
                if selection == nil {
                    Text(currentLabel).tag(Optional<ZoomLinkHandlerChoice>.none).disabled(true)
                }
                ForEach(ZoomLinkHandlerChoice.allCases, id: \.self) { choice in
                    Text(status.applicationURL(for: choice) == nil ? "\(choice.displayName) (not installed)" : choice.displayName)
                        .tag(Optional(choice))
                        .disabled(status.applicationURL(for: choice) == nil)
                }
            }
            .disabled(isChanging)
            .accessibilityIdentifier("zoomLinkHandlerPicker")
            if isChanging {
                ProgressView("Updating your Mac’s setting…").controlSize(.small)
            }
            Text("Meeting links opened in your browser launch the selected app when you choose “Open Zoom”.")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .task { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !isChanging { refresh() }
        }
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
