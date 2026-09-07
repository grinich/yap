import Foundation
import WhooshMeetings

/// Parse once per search, then match the same local dates shown in the library.
struct RecordingSearch {
    private enum DateMatch {
        case year(Int), shortYear(Int), month(Int), day(Int), weekday(Int), interval(DateInterval), invalid

        func matches(_ date: Date, components: DateComponents) -> Bool {
            switch self {
            case .year(let value): components.year == value
            case .shortYear(let value): components.year.map { $0 % 100 == value } ?? false
            case .month(let value): components.month == value
            case .day(let value): components.day == value
            case .weekday(let value): components.weekday == value
            case .interval(let interval): date >= interval.start && date < interval.end
            case .invalid: false
            }
        }
    }

    private let query: String
    private let terms: [String]
    private let dates: [DateMatch]
    private let calendar: Calendar
    private let locale: Locale

    init(query: String, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.calendar = calendar
        self.locale = locale
        var consumed = Set<Int>()
        var dates: [DateMatch] = []
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        let english = DateFormatter()
        english.locale = Locale(identifier: "en_US_POSIX")
        let months = Self.aliases([formatter.monthSymbols, formatter.shortMonthSymbols,
                                   formatter.standaloneMonthSymbols, formatter.shortStandaloneMonthSymbols,
                                   english.monthSymbols, english.shortMonthSymbols], locale: locale)
        let weekdays = Self.aliases([formatter.weekdaySymbols, formatter.shortWeekdaySymbols,
                                     english.weekdaySymbols, english.shortWeekdaySymbols], locale: locale)
        let words = Self.words(query, locale: locale).flatMap { Self.expandCompactDate($0, months: months) }

        func dayInterval(_ day: Date) -> DateMatch {
            calendar.dateInterval(of: .day, for: day).map(DateMatch.interval) ?? .invalid
        }

        // Relative phrases take precedence over individual weekday/month tokens.
        for index in words.indices where !consumed.contains(index) {
            let word = words[index]
            if word == "today" || word == "yesterday" {
                let day = calendar.date(byAdding: .day, value: word == "today" ? 0 : -1, to: now)
                dates.append(day.map(dayInterval) ?? .invalid)
                consumed.insert(index)
            } else if (word == "this" || word == "last"), index + 1 < words.count {
                let next = words[index + 1]
                let component: Calendar.Component? = switch next {
                case "week": .weekOfYear
                case "month": .month
                case "year": .year
                default: nil
                }
                if let component {
                    let anchor = calendar.date(byAdding: component, value: word == "last" ? -1 : 0, to: now)
                    dates.append(anchor.flatMap { calendar.dateInterval(of: component, for: $0) }
                        .map(DateMatch.interval) ?? .invalid)
                    consumed.formUnion([index, index + 1])
                } else if word == "last", let weekday = Self.symbol(next, in: weekdays, allowTypo: false) {
                    let today = calendar.startOfDay(for: now)
                    let difference = (calendar.component(.weekday, from: today) - weekday + 7) % 7
                    let day = calendar.date(byAdding: .day, value: -(difference == 0 ? 7 : difference), to: today)
                    dates.append(day.map(dayInterval) ?? .invalid)
                    consumed.formUnion([index, index + 1])
                }
            }
        }

        for index in words.indices where !consumed.contains(index) {
            let word = words[index]
            let allowsMonthTypo = words.count == 1 || [index - 1, index + 1].contains { neighbor in
                guard words.indices.contains(neighbor), let number = Int(words[neighbor]) else { return false }
                return (words[neighbor].count <= 2 && (1...31).contains(number))
                    || (words[neighbor].count == 4 && number > 0)
            }
            if let month = Self.symbol(word, in: months, allowTypo: allowsMonthTypo) {
                dates.append(.month(month))
                consumed.insert(index)
            } else if let weekday = Self.symbol(word, in: weekdays, allowTypo: false) {
                dates.append(.weekday(weekday))
                consumed.insert(index)
            } else if word.contains("/") || word.contains("-") || word.contains(".") {
                let parts = word.split(whereSeparator: { "/-.".contains($0) }).map(String.init)
                if parts.count >= 2, parts.allSatisfy({ Int($0) != nil }) {
                    dates += Self.numericDate(parts, locale: locale)
                    consumed.insert(index)
                }
            } else if word.count == 4, let year = Int(word), year > 0 {
                dates.append(.year(year))
                consumed.insert(index)
            }
        }

        // A short number is a day beside a date, or when searched by itself.
        // Numbers in ordinary titles ("Design 2") retain their title meaning.
        if !dates.isEmpty || words.count == 1 {
            for index in words.indices where !consumed.contains(index) {
                if let day = Int(words[index]), words[index].count <= 2 {
                    dates.append((1...31).contains(day) ? .day(day) : .invalid)
                    consumed.insert(index)
                }
            }
        }
        let dateFillers: Set<String> = dates.isEmpty ? [] : ["on", "in", "the", "of"]
        self.terms = words.indices.filter { !consumed.contains($0) && !dateFillers.contains(words[$0]) }
            .map { words[$0] }
        self.dates = dates
    }

    func matches(_ meeting: ZoomRecordingMeeting) -> Bool {
        guard !query.isEmpty else { return true }
        // Preserve literal title search even when the title itself names a date.
        if meeting.topic.localizedStandardContains(query) { return true }
        guard !terms.isEmpty || !dates.isEmpty else { return false }
        let title = Self.normalize(meeting.topic, locale: locale)
        guard terms.allSatisfy({ title.contains($0) }) else { return false }
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: meeting.startTime)
        return dates.allSatisfy { $0.matches(meeting.startTime, components: components) }
    }

    private static func numericDate(_ parts: [String], locale: Locale) -> [DateMatch] {
        guard (2...3).contains(parts.count) else { return [.invalid] }
        let values = parts.compactMap(Int.init)
        guard values.count == parts.count else { return [.invalid] }
        if parts[0].count == 4 {
            guard values[0] > 0, (1...12).contains(values[1]) else { return [.invalid] }
            var result: [DateMatch] = [.year(values[0]), .month(values[1])]
            if values.count == 3 {
                guard (1...31).contains(values[2]) else { return [.invalid] }
                result.append(.day(values[2]))
            }
            return result
        }
        if parts.count == 2, parts[1].count == 4 {
            return (1...12).contains(values[0]) && values[1] > 0
                ? [.month(values[0]), .year(values[1])] : [.invalid]
        }
        let pattern = DateFormatter.dateFormat(fromTemplate: "Md", options: 0, locale: locale) ?? "M/d"
        let localDayFirst: Bool
        if let dayIndex = pattern.firstIndex(of: "d"),
           let monthIndex = pattern.firstIndex(of: "M") ?? pattern.firstIndex(of: "L") {
            localDayFirst = dayIndex < monthIndex
        } else { localDayFirst = false }
        let dayFirst = values[0] > 12 || (values[1] <= 12 && localDayFirst)
        let month = values[dayFirst ? 1 : 0]
        let day = values[dayFirst ? 0 : 1]
        guard (1...12).contains(month), (1...31).contains(day) else { return [.invalid] }
        var result: [DateMatch] = [.month(month), .day(day)]
        if parts.count == 3 {
            if parts[2].count == 2 { result.append(.shortYear(values[2])) }
            else if parts[2].count == 4, values[2] > 0 { result.append(.year(values[2])) }
            else { return [.invalid] }
        }
        return result
    }

    private static func normalize(_ text: String, locale: Locale) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .lowercased(with: locale)
    }

    private static func words(_ text: String, locale: Locale) -> [String] {
        let normalized = normalize(text, locale: locale)
            .replacingOccurrences(of: #"\b(\d{1,2})(st|nd|rd|th)\b"#, with: "$1", options: .regularExpression)
        let pattern = #"\d+(?:[/.-]\d+)+|[\p{L}\p{N}]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
            .compactMap { Range($0.range, in: normalized).map { String(normalized[$0]) } }
    }

    private static func expandCompactDate(_ word: String, months: [(String, Int)]) -> [String] {
        // Split Aug31 and 31Aug, while keeping title terms such as SOC2 and Q3 intact.
        if word.first?.isLetter == true, let digit = word.firstIndex(where: \.isNumber) {
            let month = String(word[..<digit])
            let day = String(word[digit...]).replacingOccurrences(of: #"(st|nd|rd|th)$"#, with: "", options: .regularExpression)
            if day.count <= 2, Int(day) != nil, symbol(month, in: months, allowTypo: true) != nil {
                return [month, day]
            }
        } else if word.first?.isNumber == true, let letter = word.firstIndex(where: \.isLetter) {
            let day = String(word[..<letter]), month = String(word[letter...])
            if day.count <= 2, Int(day) != nil, symbol(month, in: months, allowTypo: true) != nil {
                return [day, month]
            }
        }
        return [word]
    }

    private static func aliases(_ lists: [[String]], locale: Locale) -> [(String, Int)] {
        lists.flatMap { list in list.enumerated().map { index, name in
            (normalize(name, locale: locale).trimmingCharacters(in: .punctuationCharacters), index + 1)
        } }
    }

    private static func symbol(_ word: String, in aliases: [(String, Int)], allowTypo: Bool) -> Int? {
        if let exact = aliases.first(where: { $0.0 == word }) { return exact.1 }
        guard word.count >= 3 else { return nil }
        let prefixes = Set(aliases.filter { $0.0.hasPrefix(word) }.map(\.1))
        if prefixes.count == 1 { return prefixes.first }
        guard allowTypo, word.count >= 4 else { return nil }
        let similar = Set(aliases.filter { oneEditApart(word, $0.0) }.map(\.1))
        return similar.count == 1 ? similar.first : nil
    }

    private static func oneEditApart(_ left: String, _ right: String) -> Bool {
        let a = Array(left), b = Array(right)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count <= b.count { j += 1 }
            if a.count >= b.count { i += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }
}
