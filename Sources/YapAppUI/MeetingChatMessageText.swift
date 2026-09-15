import AppKit
import SwiftUI
import YapMeetings

/// Each bubble owns its text view. SwiftUI's shared selectable-Text field editor
/// merges adjacent bubbles, including their context menus and accessibility.
struct MeetingChatMessageText: NSViewRepresentable {
    let message: MeetingChatMessage
    let actions: [Action]

    struct Action {
        let title: String
        let perform: () -> Void
    }

    func makeNSView(context: Context) -> MessageTextView {
        let view = MessageTextView()
        view.isEditable = false; view.isSelectable = true; view.isRichText = true
        view.drawsBackground = false; view.importsGraphics = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isContinuousSpellCheckingEnabled = false; view.isGrammarCheckingEnabled = false
        view.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        return view
    }

    func updateNSView(_ view: MessageTextView, context: Context) {
        view.messageActions = actions
        view.setAccessibilityIdentifier("meeting-chat-text-\(message.id)")
        view.setAccessibilityLabel("\(message.isFromSelf ? "You" : message.senderName) to \(message.recipient.label)")
        view.setAccessibilityCustomActions(actions.map { action in
            NSAccessibilityCustomAction(name: action.title) { action.perform(); return true }
        })
        let attributed = NSMutableAttributedString(attributedString: MeetingChatRichText.attributed(message.runs, fallback: message.text))
        let detectedLinks = NSAttributedString(ChatMessageLinks.attributedText(message.text))
        detectedLinks.enumerateAttribute(.link, in: NSRange(location: 0, length: detectedLinks.length)) { value, range, _ in
            if let value, attributed.attribute(.link, at: range.location, effectiveRange: nil) == nil {
                attributed.addAttribute(.link, value: value, range: range)
            }
        }
        if !view.attributedString().isEqual(to: attributed) {
            view.textStorage?.setAttributedString(attributed)
            view.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTextView, context: Context) -> CGSize? {
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        let available = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 300
        let natural = ceil(nsView.attributedString().size().width)
        let width = max(1, min(available, natural))
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return NSSize(width: width, height: max(16, ceil(layout.usedRect(for: container).height)))
    }

    final class MessageTextView: NSTextView {
        var messageActions: [Action] = []

        func messageMenu() -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false
            for action in messageActions {
                let item = NSMenuItem(title: action.title, action: #selector(performMessageAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = CapturedAction(action.perform)
                menu.addItem(item)
            }
            return menu
        }

        override func menu(for event: NSEvent) -> NSMenu? { messageMenu() }

        @objc func performMessageAction(_ item: NSMenuItem) {
            (item.representedObject as? CapturedAction)?.perform()
        }

        /// An open menu keeps the action it displayed, even when a new policy
        /// snapshot adds/removes buttons from the underlying message row.
        private final class CapturedAction: NSObject {
            let perform: () -> Void
            init(_ perform: @escaping () -> Void) { self.perform = perform }
        }
    }
}
