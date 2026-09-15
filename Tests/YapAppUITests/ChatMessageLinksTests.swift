import Foundation
import SwiftUI
import Testing
@testable import YapAppUI

@Suite("Chat web links") @MainActor
struct ChatMessageLinksTests {
    @Test func multipleLinksExcludeSurroundingPunctuation() {
        let text = "Read (https://example.com/guide), then visit https://example.org/notes."
        let attributed = ChatMessageLinks.attributedText(text)
        let links = links(in: attributed)
        #expect(String(attributed.characters) == text)
        #expect(links.map(\.text) == ["https://example.com/guide", "https://example.org/notes"])
        #expect(links.map { $0.url.absoluteString } == ["https://example.com/guide", "https://example.org/notes"])
        #expect(links.allSatisfy { $0.underlined })
        #expect(attributed.runs.filter { $0.link == nil }.allSatisfy { $0.swiftUI.underlineStyle == nil })
    }

    @Test func linkRangesRemainCorrectAfterEmojiAndCombiningCharacters() {
        let text = "👩🏽‍💻 Cafe\u{301} — https://example.com/one\n再见🙂 https://example.org/two 🎉"
        let attributed = ChatMessageLinks.attributedText(text)
        #expect(String(attributed.characters) == text)
        #expect(links(in: attributed).map(\.text) == ["https://example.com/one", "https://example.org/two"])
        #expect(links(in: attributed).allSatisfy { $0.underlined })
    }

    @Test func preservesLongQueryParametersAndFragmentsInDestinationsAndLabels() {
        let url = "https://example.com/document?code=" + String(repeating: "abc123", count: 80)
            + "&redirect=https%3A%2F%2Fexample.org%2Fa%3Fb%3Dc&label=caf%C3%A9#section-42"
        let text = "The full link:\n" + url + "\nThanks!"
        let attributed = ChatMessageLinks.attributedText(text)
        let links = links(in: attributed)
        #expect(String(attributed.characters) == text)
        #expect(links.count == 1)
        #expect(links.first?.text == url)
        #expect(links.first?.url.absoluteString == url)
        #expect(links.first?.url.query?.contains("redirect=https%3A%2F%2Fexample.org%2Fa%3Fb%3Dc") == true)
        #expect(links.first?.url.fragment == "section-42")
    }

    @Test func plainTextRemainsLiteralWithoutLinkAttributes() {
        for text in ["", "Hello, everyone! 👋\nSee you next week.", "**Important** _notes_ `code` [reference]"] {
            let attributed = ChatMessageLinks.attributedText(text)
            #expect(String(attributed.characters) == text)
            #expect(links(in: attributed).isEmpty)
        }
    }

    @Test func markdownSyntaxIsPreservedAndOnlyTheVisibleURLBecomesALink() {
        let text = "**Read** [our notes](https://example.com/notes) and `https://example.org/code`."
        let attributed = ChatMessageLinks.attributedText(text)
        #expect(String(attributed.characters) == text)
        #expect(links(in: attributed).map(\.text) == ["https://example.com/notes", "https://example.org/code"])
        #expect(attributed.runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }

    @Test func detectorCompletedWWWAddressKeepsItsOriginalVisibleText() {
        let text = "Try www.example.com/help today."
        let attributed = ChatMessageLinks.attributedText(text)
        let links = links(in: attributed)
        #expect(String(attributed.characters) == text)
        #expect(links.count == 1)
        #expect(links.first?.text == "www.example.com/help")
        #expect(links.first?.url.host == "www.example.com")
        #expect(["http", "https"].contains(links.first?.url.scheme ?? ""))
    }

    @Test func nonWebSchemesAreNeverMadeActionable() {
        let text = "mailto:person@example.com ftp://example.com/file file:///tmp/notes.txt "
            + "tel:+14155550123 javascript:alert(1) zoommtg://zoom.us/join?action=join&confno=123456789"
        let attributed = ChatMessageLinks.attributedText(text)
        #expect(String(attributed.characters) == text)
        #expect(links(in: attributed).isEmpty)
    }

    private func links(in attributed: AttributedString) -> [(text: String, url: URL, underlined: Bool)] {
        attributed.runs.compactMap { run in
            guard let url = run.link else { return nil }
            return (String(attributed[run.range].characters), url, run.swiftUI.underlineStyle == .single)
        }
    }
}
