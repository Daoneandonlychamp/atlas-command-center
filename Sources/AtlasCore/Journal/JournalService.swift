import Foundation

/// Daily journal entries, written into the Obsidian vault.
///
/// The entry is a plain markdown note living beside everything else the user writes,
/// not a private store — that was a deliberate choice, unlike the Direct-mode
/// transcripts which are encrypted. What makes it worth opening is that ATLAS
/// already knows most of the day: the events that happened, what got finished,
/// what was committed. That gets assembled for you; you write on top of it.
///
/// The assembled part is rewritten every time; anything below the marker is
/// yours and is never touched.
public final class JournalService {
    public static let shared = JournalService()

    /// Everything above this line is regenerated. Everything below is the user's.
    public static let marker = "<!-- atlas:assembled-above -->"

    private let calendar = CalendarManager.shared
    private let fileManager = FileManager.default

    public init() {}

    /// Where entries live. One note per day, named by date so Obsidian's own
    /// daily-note conventions and links line up.
    public var folder: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Obsidian/MYTHOS Context/Journal", isDirectory: true)
    }

    public func url(for day: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return folder.appendingPathComponent("\(formatter.string(from: day)).md")
    }

    public func exists(_ day: Date) -> Bool {
        fileManager.fileExists(atPath: url(for: day).path)
    }

    // MARK: - Reading and writing

    /// The whole note, or an assembled starting point if it does not exist yet.
    public func entry(for day: Date, projects: [AtlasProject] = []) -> JournalEntry {
        let location = url(for: day)
        let existing = try? String(contentsOf: location, encoding: .utf8)
        let assembled = assemble(day, projects: projects)

        guard let existing else {
            return JournalEntry(day: day, url: location, assembled: assembled, written: "", isNew: true)
        }
        // Split on the marker so a regenerated header never eats what was typed.
        if let range = existing.range(of: Self.marker) {
            let written = String(existing[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return JournalEntry(day: day, url: location, assembled: assembled, written: written, isNew: false)
        }
        // A note written before ATLAS touched it: keep all of it as the user's.
        return JournalEntry(day: day, url: location, assembled: assembled,
                            written: existing.trimmingCharacters(in: .whitespacesAndNewlines),
                            isNew: false)
    }

    @discardableResult
    public func save(_ entry: JournalEntry) throws -> URL {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let body = """
        \(entry.assembled)

        \(Self.marker)

        \(entry.written)
        """
        try body.write(to: entry.url, atomically: true, encoding: .utf8)
        return entry.url
    }

    /// Days that already have an entry, newest first.
    public func recentDays(limit: Int = 60) -> [Date] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.hasSuffix(".md") }
            .compactMap { formatter.date(from: String($0.dropLast(3))) }
            .sorted(by: >)
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Assembling the day

    /// Builds the part ATLAS knows: what was scheduled, what got finished, what
    /// was committed. Written as frontmatter plus prose so the note is useful in
    /// Obsidian on its own, whether or not it is ever opened in ATLAS again.
    public func assemble(_ day: Date, projects: [AtlasProject] = []) -> String {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!

        let heading = DateFormatter()
        heading.dateFormat = "EEEE, d MMMM yyyy"
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"

        var out = """
        ---
        date: \(stamp.string(from: dayStart))
        type: journal
        source: ATLAS
        ---

        # \(heading.string(from: dayStart))

        """

        let events = calendar.fetchEvents(from: dayStart, to: dayEnd)
        if !events.isEmpty {
            let time = DateFormatter()
            time.dateFormat = "HH:mm"
            out += "\n## Scheduled\n\n"
            for event in events {
                let when = event.isAllDay ? "all day" : time.string(from: event.startDate)
                out += "- **\(when)** \(event.title)"
                if let location = event.location, !location.isEmpty { out += " · \(location)" }
                out += "\n"
            }
        }

        let commits = Self.commits(on: dayStart, in: projects)
        if !commits.isEmpty {
            out += "\n## Committed\n\n"
            for commit in commits { out += "- \(commit)\n" }
        }

        out += "\n## Notes\n"
        return out
    }

    /// Today's commits by this user, across the projects ATLAS tracks.
    ///
    /// Read-only and shelled out rather than using a git library: `git log` is
    /// already on the machine and this is one call per repository.
    /// ponytail: one process per repo, batch it if the project list gets long.
    static func commits(on day: Date, in projects: [AtlasProject]) -> [String] {
        // The times are not decoration. Git's approxidate resolves a bare
        // "2026-09-06" to the *current* time on that date, so --since=<today>
        // silently drops everything committed earlier in the day.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 00:00:00"
        let since = formatter.string(from: day)
        let until = formatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: day)!)

        var found: [String] = []
        for project in projects.prefix(20) where project.isGitRepository {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", project.path, "log",
                                 "--since=\(since)", "--until=\(until)",
                                 "--author-date-order", "--pretty=format:%s"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where !line.isEmpty {
                found.append("`\(project.name)` — \(line)")
            }
        }
        return found
    }
}

/// One day's note, split into the part ATLAS writes and the part you write.
public struct JournalEntry {
    public let day: Date
    public let url: URL
    /// Regenerated every time the entry is opened.
    public var assembled: String
    /// Yours. Never rewritten.
    public var written: String
    public let isNew: Bool

    public init(day: Date, url: URL, assembled: String, written: String, isNew: Bool) {
        self.day = day
        self.url = url
        self.assembled = assembled
        self.written = written
        self.isNew = isNew
    }
}


/// Day words shared by the ⌘K verbs and anything else that takes a date from
/// typed text. In AtlasCore so it can be tested and reused, rather than buried
/// in a view.
public enum PaletteDayParsing {
    /// "today", "yesterday", "tomorrow", a weekday name, or an ISO date.
    ///
    /// A weekday means the most recent one: these are used for journal entries,
    /// which are about days that already happened. The board's quick add looks
    /// forward instead, because a task is scheduled, not recorded.
    public static func parse(_ text: String) -> Date? {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        switch word {
        case "today": return today
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today)
        default: break
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        if let exact = formatter.date(from: word) { return exact }

        let days = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if word.count >= 3, let index = days.firstIndex(where: { $0.hasPrefix(word) }) {
            var back = (calendar.component(.weekday, from: today) - 1 - index + 7) % 7
            if back == 0 { back = 7 }
            return calendar.date(byAdding: .day, value: -back, to: today)
        }
        return nil
    }
}
