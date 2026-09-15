import AppKit
import SwiftUI
import YapMeetings

@MainActor enum MeetingChatRichText {
    static let baseFont = NSFont.systemFont(ofSize: 13)

    static func attributed(_ runs: [MeetingChatTextRun], fallback: String) -> NSAttributedString {
        let valid = !runs.isEmpty && runs.map(\.text).joined() == fallback
        let result = NSMutableAttributedString(string: "")
        for run in valid ? runs : [MeetingChatTextRun(text: fallback)] {
            var font = baseFont
            if run.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link, let url = safeLink(link) { attributes[.link] = url }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    static func runs(from text: NSAttributedString) -> [MeetingChatTextRun] {
        var runs: [MeetingChatTextRun] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let font = attributes[.font] as? NSFont ?? baseFont
            let traits = NSFontManager.shared.traits(of: font)
            let link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
            runs.append(MeetingChatTextRun(text: (text.string as NSString).substring(with: range),
                bold: traits.contains(.boldFontMask), italic: traits.contains(.italicFontMask),
                underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                strikethrough: (attributes[.strikethroughStyle] as? Int ?? 0) != 0,
                link: link.flatMap { safeLink($0)?.absoluteString }))
        }
        // Plain messages retain the existing plain-chat fallback for simple drivers.
        return runs.contains { $0.bold || $0.italic || $0.underline || $0.strikethrough || $0.link != nil } ? runs : []
    }

    static func safeLink(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    static func display(_ message: MeetingChatMessage) -> AttributedString {
        guard !message.runs.isEmpty, message.runs.map(\.text).joined() == message.text else {
            return ChatMessageLinks.attributedText(message.text)
        }
        return AttributedString(attributed(message.runs, fallback: message.text))
    }
}

@MainActor final class MeetingChatEditorState {
    weak var textView: NSTextView?
    enum Style: Equatable { case bold, italic, underline, strikethrough }

    func toggle(_ style: Style) {
        guard let view = textView, view.isEditable else { return }
        let range = view.selectedRange()
        let attributes = range.length == 0 ? view.typingAttributes : view.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? [:]
        var changed = attributes
        switch style {
        case .bold, .italic:
            let font = attributes[.font] as? NSFont ?? MeetingChatRichText.baseFont
            let trait: NSFontTraitMask = style == .bold ? .boldFontMask : .italicFontMask
            changed[.font] = NSFontManager.shared.traits(of: font).contains(trait)
                ? NSFontManager.shared.convert(font, toNotHaveTrait: trait) : NSFontManager.shared.convert(font, toHaveTrait: trait)
        case .underline, .strikethrough:
            let key: NSAttributedString.Key = style == .underline ? .underlineStyle : .strikethroughStyle
            changed[key] = (attributes[key] as? Int ?? 0) == 0 ? NSUnderlineStyle.single.rawValue : 0
        }
        if range.length == 0 { view.typingAttributes = changed }
        else {
            let key: NSAttributedString.Key = style == .bold || style == .italic ? .font : style == .underline ? .underlineStyle : .strikethroughStyle
            guard view.shouldChangeText(in: range, replacementString: nil), let value = changed[key] else { return }
            if key == .font, let storage = view.textStorage {
                let trait: NSFontTraitMask = style == .bold ? .boldFontMask : .italicFontMask
                let adding = NSFontManager.shared.traits(of: value as! NSFont).contains(trait)
                var fonts: [(NSRange, NSFont)] = []
                storage.enumerateAttribute(.font, in: range) { existing, subrange, _ in
                    let font = existing as? NSFont ?? MeetingChatRichText.baseFont
                    fonts.append((subrange, adding ? NSFontManager.shared.convert(font, toHaveTrait: trait) : NSFontManager.shared.convert(font, toNotHaveTrait: trait)))
                }
                for (subrange, font) in fonts { storage.addAttribute(.font, value: font, range: subrange) }
            } else { view.textStorage?.addAttribute(key, value: value, range: range) }
            view.didChangeText()
        }
        view.window?.makeFirstResponder(view)
    }

    func insertLink(_ url: URL) {
        guard let view = textView, view.isEditable else { return }
        let selection = view.selectedRange()
        if selection.length == 0 {
            var attrs = view.typingAttributes; attrs[.link] = url
            view.insertText(NSAttributedString(string: url.absoluteString, attributes: attrs), replacementRange: selection)
        } else if view.shouldChangeText(in: selection, replacementString: nil) {
            view.textStorage?.addAttribute(.link, value: url, range: selection)
            view.didChangeText()
        }
        view.window?.makeFirstResponder(view)
    }
}

struct MeetingChatRichEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var runs: [MeetingChatTextRun]
    let state: MeetingChatEditorState
    let isEnabled: Bool
    let placeholder: String
    let focusRequest: UUID
    let onFocusChange: (Bool) -> Void
    let send: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let view = ChatTextView()
        view.isRichText = true; view.importsGraphics = false; view.allowsUndo = true
        view.drawsBackground = false; view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 3, height: 5)
        view.font = MeetingChatRichText.baseFont; view.textColor = .labelColor
        view.typingAttributes = [.font: MeetingChatRichText.baseFont, .foregroundColor: NSColor.labelColor]
        view.delegate = context.coordinator; view.send = send
        view.focusChanged = { [weak coordinator = context.coordinator] focused in
            DispatchQueue.main.async { [weak coordinator] in coordinator?.parent.onFocusChange(focused) }
        }
        view.setAccessibilityLabel(placeholder)
        scroll.documentView = view; state.textView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ChatTextView else { return }
        state.textView = view; view.isEditable = isEnabled; view.send = send
        view.placeholder = placeholder; view.needsDisplay = true
        view.setAccessibilityLabel(placeholder)
        if view.string != text || MeetingChatRichText.runs(from: view.attributedString()) != runs {
            let selection = view.selectedRange()
            view.textStorage?.setAttributedString(MeetingChatRichText.attributed(runs, fallback: text))
            view.setSelectedRange(NSRange(location: min(selection.location, view.string.utf16.count), length: 0))
        }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak view] in
                if let view, view.isEditable { view.window?.makeFirstResponder(view) }
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MeetingChatRichEditor
        var focusRequest: UUID?
        init(_ parent: MeetingChatRichEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            parent.runs = MeetingChatRichText.runs(from: view.attributedString())
            view.needsDisplay = true
        }
    }

    final class ChatTextView: NSTextView {
        var send: (() -> Void)?
        var focusChanged: ((Bool) -> Void)?
        var placeholder = ""
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { focusChanged?(true) }
            return accepted
        }
        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { focusChanged?(false) }
            return accepted
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if string.isEmpty {
                (placeholder as NSString).draw(in: NSRect(x: textContainerInset.width + 5, y: textContainerInset.height,
                    width: max(0, bounds.width - 16), height: 20), withAttributes: [
                        .font: MeetingChatRichText.baseFont, .foregroundColor: NSColor.placeholderTextColor])
            }
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36, !hasMarkedText(), !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option) {
                send?(); return
            }
            if event.modifierFlags.contains(.command), let letter = event.charactersIgnoringModifiers?.lowercased() {
                let state = MeetingChatEditorState(); state.textView = self
                if letter == "b" { state.toggle(.bold); return }
                if letter == "i" { state.toggle(.italic); return }
                if letter == "u" { state.toggle(.underline); return }
            }
            super.keyDown(with: event)
        }
        override func paste(_ sender: Any?) {
            // Keep text and supported styles, but never import attachments or remote images.
            if let data = NSPasteboard.general.data(forType: .rtf),
               let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                let plain = value.string.replacingOccurrences(of: "\u{FFFC}", with: "")
                let runs = MeetingChatRichText.runs(from: value)
                insertText(MeetingChatRichText.attributed(runs, fallback: plain), replacementRange: selectedRange())
            } else { super.pasteAsPlainText(sender) }
        }
    }
}
