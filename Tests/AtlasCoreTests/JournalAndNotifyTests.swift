import XCTest
@testable import AtlasCore

/// The journal's one rule that matters: regenerating the assembled half must
/// never touch what the user wrote.
final class JournalServiceTests: XCTestCase {
    private var directory: URL!
    private var service: JournalService!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AtlasJournalTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        service = JournalService()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Builds an entry pointed at the temp directory rather than the real vault.
    private func entry(assembled: String, written: String, day: Date = Date()) -> JournalEntry {
        JournalEntry(day: day, url: directory.appendingPathComponent("test.md"),
                     assembled: assembled, written: written, isNew: true)
    }

    func testSavedNoteKeepsBothHalvesSeparatedByTheMarker() throws {
        let saved = try service.save(entry(assembled: "# Monday\n\n## Scheduled\n\n- standup",
                                           written: "Felt slow today."))
        let text = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertTrue(text.contains(JournalService.marker))
        XCTAssertTrue(text.contains("standup"))
        XCTAssertTrue(text.contains("Felt slow today."))

        let markerAt = text.range(of: JournalService.marker)!
        XCTAssertTrue(text[..<markerAt.lowerBound].contains("standup"),
                      "assembled content belongs above the marker")
        XCTAssertTrue(text[markerAt.upperBound...].contains("Felt slow today."),
                      "what the user wrote belongs below it")
    }

    func testWrittenHalfSurvivesAReassembledHeader() throws {
        let url = directory.appendingPathComponent("test.md")
        let first = JournalEntry(day: Date(), url: url, assembled: "# Monday\n\n- one event",
                                 written: "My private thoughts.", isNew: true)
        try service.save(first)

        // The day gains an event, so the assembled half is rebuilt and re-saved.
        var second = first
        second.assembled = "# Monday\n\n- one event\n- a second event"
        try service.save(second)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("a second event"), "the header updates")
        XCTAssertEqual(text.components(separatedBy: "My private thoughts.").count - 1, 1,
                       "the written half is kept exactly once, not duplicated or lost")
    }

    func testAssembledDayCarriesFrontmatterAndHeading() {
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 9))!
        let text = service.assemble(day)
        XCTAssertTrue(text.hasPrefix("---\n"), "Obsidian wants frontmatter first")
        XCTAssertTrue(text.contains("date: 2026-09-09"))
        XCTAssertTrue(text.contains("type: journal"))
        XCTAssertTrue(text.contains("# Wednesday, 9 September 2026"))
    }

    func testFileNameIsTheDateSoObsidianDailyNotesLineUp() {
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 5))!
        XCTAssertEqual(service.url(for: day).lastPathComponent, "2026-12-05.md")
    }
}

/// The scheduler's date maths. Everything else in it talks to EventKit.
final class NotificationSchedulerTests: XCTestCase {
    func testDigestsLandAtNineTheNextMorning() throws {
        let afternoon = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 16, minute: 40))!
        let fire = try XCTUnwrap(NotificationScheduler.nextMorning(after: afternoon))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        XCTAssertEqual(parts.day, 10, "tomorrow, not today")
        XCTAssertEqual(parts.hour, 9)
        XCTAssertEqual(parts.minute, 0)
    }

    func testLateNightStillRollsToTheNextMorning() throws {
        let lateNight = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 23, minute: 55))!
        let fire = try XCTUnwrap(NotificationScheduler.nextMorning(after: lateNight))
        XCTAssertEqual(Calendar.current.component(.day, from: fire), 10)
        XCTAssertEqual(Calendar.current.component(.hour, from: fire), 9)
    }

    func testDefaultsAreConservative() {
        let settings = NotificationScheduler.Settings()
        XCTAssertEqual(settings.eventLeadMinutes, 10)
        XCTAssertEqual(settings.staleAfterDays, 7, "matches the board's amber threshold")
    }

    func testSettingsRoundTripThroughJSON() throws {
        var settings = NotificationScheduler.Settings()
        settings.events = false
        settings.eventLeadMinutes = 25
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(NotificationScheduler.Settings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }
}

/// Guards the git date bug: a bare `--since=<date>` resolves to the current time
/// on that date, so commits made earlier the same day vanish from the journal.
final class JournalCommitTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AtlasJournalRepo_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try run("git", "init", "-q")
        try run("git", "config", "user.email", "test@example.com")
        try run("git", "config", "user.name", "Test")
        try "hello".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try run("git", "add", ".")
        try run("git", "commit", "-q", "-m", "a commit from earlier today")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    @discardableResult
    private func run(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repo.path] + arguments.dropFirst()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func testTodaysCommitsAreFoundEvenLateInTheDay() {
        let project = AtlasProject(name: "Temp", path: repo.path, isGitRepository: true)
        let found = JournalService.commits(on: Date(), in: [project])
        XCTAssertEqual(found.count, 1, "a commit made today must appear in today's journal")
        XCTAssertTrue(found[0].contains("a commit from earlier today"))
        XCTAssertTrue(found[0].contains("Temp"), "the project is named so several repos read clearly")
    }

    func testYesterdayHasNoCommits() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let project = AtlasProject(name: "Temp", path: repo.path, isGitRepository: true)
        XCTAssertTrue(JournalService.commits(on: yesterday, in: [project]).isEmpty,
                      "the day window must not leak into neighbouring days")
    }

    func testNonGitProjectsAreSkippedRatherThanErroring() {
        let project = AtlasProject(name: "Plain", path: repo.path, isGitRepository: false)
        XCTAssertTrue(JournalService.commits(on: Date(), in: [project]).isEmpty)
    }
}

/// The ⌘K verbs' date vocabulary. It deliberately mirrors the board's quick-add
/// syntax so one set of words works everywhere.
final class PaletteDayTests: XCTestCase {
    private func day(_ text: String) -> Date? { PaletteDayParsing.parse(text) }

    func testRelativeWords() {
        let today = Calendar.current.startOfDay(for: Date())
        XCTAssertEqual(day("today"), today)
        XCTAssertEqual(day("yesterday"), Calendar.current.date(byAdding: .day, value: -1, to: today))
        XCTAssertEqual(day("tomorrow"), Calendar.current.date(byAdding: .day, value: 1, to: today))
    }

    func testISODate() {
        let parsed = day("2026-09-09")
        XCTAssertEqual(Calendar.current.component(.year, from: parsed!), 2026)
        XCTAssertEqual(Calendar.current.component(.day, from: parsed!), 9)
    }

    func testWeekdayLooksBackwards() throws {
        // A journal entry is usually about a day that already happened, the
        // opposite of the board's "next Friday".
        let parsed = try XCTUnwrap(day("monday"))
        XCTAssertLessThan(parsed, Date(), "must be the most recent Monday, not the coming one")
        XCTAssertEqual(Calendar.current.component(.weekday, from: parsed), 2)
    }

    func testNonsenseIsRejected() {
        XCTAssertNil(day("banana"))
        XCTAssertNil(day(""))
        XCTAssertNil(day("  "))
    }
}
