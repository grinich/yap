import Foundation
import SwiftUI

@MainActor
enum ChatMessageLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Adds web destinations to literal chat text without interpreting Markdown or changing its characters.
    static func attributedText(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector else { return attributed }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard var url = match.url, var stringRange = Range(match.range, in: text) else { continue }
            // The detector can include a closing backtick around a pasted URL.
            // Keep those delimiters visible without sending one to the browser.
            if stringRange.lowerBound > text.startIndex,
               text[text.index(before: stringRange.lowerBound)] == "`",
               text[stringRange].last == "`" {
                stringRange = stringRange.lowerBound..<text.index(before: stringRange.upperBound)
                guard let trimmedURL = URL(string: String(text[stringRange])) else { continue }
                url = trimmedURL
            }
            guard
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let host = components.host, !host.isEmpty,
                  let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(stringRange.upperBound, within: attributed) else { continue }
            let range = lower..<upper
            attributed[range].link = url
            attributed[range].swiftUI.underlineStyle = .single
        }
        return attributed
    }
}
