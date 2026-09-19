import Foundation

/// Turns a pasted invoice list into expense rows.
///
/// Billing consoles all render the same three things — a description, an
/// amount, and a date — just in different orders and with different noise
/// around them. Rather than write a parser per provider, this pulls the amount
/// and the date out of each line wherever they sit and treats the rest as the
/// description.
///
/// Nothing here writes. It returns candidates for a person to look at, because
/// the failure mode of a misread amount is a wrong number in someone's
/// finances, and that is worth one glance before it lands.
public enum InvoiceImport {

    /// One line that looked like a charge.
    public struct Candidate: Identifiable, Equatable, Sendable {
        public var id = UUID().uuidString
        public var description: String
        public var amountMinorUnits: Int
        public var date: Date
        /// Set when the line parsed but something about it wants a second look.
        public var warning: String?
        /// Off for rows the person unticked in the review sheet.
        public var include: Bool = true

        public init(id: String = UUID().uuidString, description: String,
                    amountMinorUnits: Int, date: Date,
                    warning: String? = nil, include: Bool = true) {
            self.id = id
            self.description = description
            self.amountMinorUnits = amountMinorUnits
            self.date = date
            self.warning = warning
            self.include = include
        }
    }

    /// Parses pasted text into candidates, newest first.
    ///
    /// A line needs both an amount and a date to count. Lines that have one but
    /// not the other are dropped rather than guessed at — a charge with an
    /// invented date is worse than a charge that did not import.
    public static func parse(_ text: String, calendar: Calendar = .current) -> [Candidate] {
        var out: [Candidate] = []
        var seen = Set<String>()

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let amount = amountMinorUnits(in: line) else { continue }
            guard let date = date(in: line, calendar: calendar) else { continue }

            let description = describe(line)
            guard !description.isEmpty else { continue }

            // The same charge often appears twice in a console — once as the
            // period it covers and once as the day it was billed.
            let fingerprint = "\(description.lowercased())|\(amount)|\(date.timeIntervalSince1970)"
            guard seen.insert(fingerprint).inserted else { continue }

            out.append(Candidate(description: description,
                                 amountMinorUnits: amount,
                                 date: date,
                                 warning: amount == 0 ? "Zero amount" : nil))
        }
        return out.sorted { $0.date > $1.date }
    }

    /// The last money-looking figure on the line, in minor units.
    ///
    /// The last one, because a line usually reads "description … total", and a
    /// description can carry its own numbers ("5 TB", "for 7/1 - 8/1").
    static func amountMinorUnits(in line: String) -> Int? {
        let pattern = #"\$\s*(\d{1,3}(?:,\d{3})*|\d+)(?:\.(\d{2}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        let matches = regex.matches(in: line, range: range)
        guard let match = matches.last else { return nil }

        guard let whole = Range(match.range(at: 1), in: line) else { return nil }
        let units = Int(line[whole].replacingOccurrences(of: ",", with: "")) ?? 0
        var cents = 0
        if match.range(at: 2).location != NSNotFound,
           let fraction = Range(match.range(at: 2), in: line) {
            cents = Int(line[fraction]) ?? 0
        }
        return units * 100 + cents
    }

    /// A full date on the line — "Aug 8, 2026" or "8/1/2026".
    ///
    /// A bare "August 2026" is the period a charge covers, not the day it was
    /// billed, so it is deliberately not matched: it would put every row on the
    /// first of the month.
    static func date(in line: String, calendar: Calendar = .current) -> Date? {
        if let named = namedDate(in: line, calendar: calendar) { return named }
        return numericDate(in: line, calendar: calendar)
    }

    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                 "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    private static func namedDate(in line: String, calendar: Calendar) -> Date? {
        let pattern = #"([A-Za-z]{3,9})\s+(\d{1,2}),?\s+(\d{4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let nameRange = Range(match.range(at: 1), in: line),
              let dayRange = Range(match.range(at: 2), in: line),
              let yearRange = Range(match.range(at: 3), in: line)
        else { return nil }

        let key = String(line[nameRange]).lowercased().prefix(3)
        guard let month = months[String(key)],
              let day = Int(line[dayRange]), let year = Int(line[yearRange])
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func numericDate(in line: String, calendar: Calendar) -> Date? {
        let pattern = #"(\d{1,2})/(\d{1,2})/(\d{4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        // The last one: a line describing a period ends with the date it was
        // billed rather than the date the period opened.
        guard let match = regex.matches(in: line, range: range).last,
              let m = Range(match.range(at: 1), in: line),
              let d = Range(match.range(at: 2), in: line),
              let y = Range(match.range(at: 3), in: line),
              let month = Int(line[m]), let day = Int(line[d]), let year = Int(line[y]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// The line with the amounts, dates and console chrome taken out.
    static func describe(_ line: String) -> String {
        var text = line

        for pattern in [#"\$\s*\d[\d,]*(?:\.\d{2})?"#,          // amounts
                        #"[A-Za-z]{3,9}\s+\d{1,2},?\s+\d{4}"#,  // Aug 8, 2026
                        #"\d{1,2}/\d{1,2}/\d{4}"#,              // 8/1/2026
                        #"(?i)\b(invoiced|total due|paid|upcoming|estimated total)\b"#] {
            text = text.replacingOccurrences(of: pattern, with: " ",
                                             options: .regularExpression)
        }

        return text
            .replacingOccurrences(of: #"[\s\-–—·|,]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—·|,:"))
    }

    /// Guesses a category from the words in the description, so an import of
    /// thirty rows does not mean thirty dropdowns.
    public static func category(for description: String) -> ExpenseCategory {
        let text = description.lowercased()
        let infra = ["vercel", "railway", "neon", "aws", "cloudflare", "supabase",
                     "hosting", "infrastructure", "usage", "marketplace", "database"]
        if infra.contains(where: text.contains) { return .infrastructure }
        let software = ["pro", "plus", "plan", "seat", "licence", "license", "subscription"]
        if software.contains(where: text.contains) { return .software }
        return .other
    }

    /// Rows that repeat monthly at a steady amount, which is what a fixed plan
    /// looks like in a list of invoices.
    ///
    /// Only offered, never acted on: the difference between a plan and a
    /// coincidence is a judgement the person has to make.
    public static func recurringSuggestions(_ candidates: [Candidate],
                                            calendar: Calendar = .current) -> [String] {
        var byDescription: [String: [Candidate]] = [:]
        for candidate in candidates {
            byDescription[candidate.description.lowercased(), default: []].append(candidate)
        }
        return byDescription
            .filter { _, rows in
                guard rows.count >= 3 else { return false }
                let amounts = Set(rows.map(\.amountMinorUnits))
                return amounts.count == 1 && amounts.first != 0
            }
            .keys
            .sorted()
    }
}
