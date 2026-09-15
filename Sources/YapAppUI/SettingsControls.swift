import SwiftUI
import AppKit

/// Keeps explanatory copy attached to its control rather than in a separate form row.
struct SettingsLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

struct SettingsChoice<Value: Hashable> {
    let value: Value
    let title: String
    var isEnabled = true
}

/// A native popup control keeps the full field clickable and supports keyboard selection.
struct SettingsChoiceMenu<Selection: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Selection
    let choices: [SettingsChoice<Selection>]
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.removeAllItems()
        button.autoenablesItems = false
        for (index, choice) in choices.enumerated() {
            button.addItem(withTitle: choice.title)
            button.lastItem?.tag = index
            button.lastItem?.isEnabled = choice.isEnabled
        }
        if let index = choices.firstIndex(where: { $0.value == selection }) {
            button.selectItem(at: index)
        }
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(title)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let size = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject {
        var parent: SettingsChoiceMenu
        init(_ parent: SettingsChoiceMenu) { self.parent = parent }
        @objc func select(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard parent.choices.indices.contains(index), parent.choices[index].isEnabled else { return }
            parent.selection = parent.choices[index].value
        }
    }
}
