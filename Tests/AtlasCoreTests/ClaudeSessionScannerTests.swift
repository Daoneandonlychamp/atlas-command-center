import XCTest
@testable import AtlasCore

final class ClaudeSessionScannerTests: XCTestCase {

    private var root: URL!
    private var cacheURL: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("proj-a"), withIntermediateDirectories: true)
        cacheURL = root.appendingPathComponent("cache.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func today() -> String { ClaudeSessionScanner.dayFormatter.string(from: Date()) }

    private func write(_ name: String, _ lines: [String]) throws {
        let url = root.appendingPathComponent("proj-a").appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func assistantLine(model: String, input: Int, cacheWrite: Int, cacheRead: Int, output: Int) -> String {
        """
        {"type":"assistant","timestamp":"\(today())T12:00:00.000Z","message":{"model":"\(model)","usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(cacheWrite),"cache_read_input_tokens":\(cacheRead),"output_tokens":\(output)}}}
        """
    }

    private func scan(_ scanner: ClaudeSessionScanner) {
        let done = expectation(description: "scan")
        scanner.refresh { done.fulfill() }
        wait(for: [done], timeout: 30)
    }

    func testCostMatchesPublishedRates() throws {
        // 1M output on Opus 5 is exactly $25; 1M cache reads exactly $0.50.
        try write("a.jsonl", [
            assistantLine(model: "claude-opus-5", input: 0, cacheWrite: 0, cacheRead: 0, output: 1_000_000),
            assistantLine(model: "claude-opus-5", input: 0, cacheWrite: 0, cacheRead: 1_000_000, output: 0),
        ])
        let scanner = ClaudeSessionScanner(projectsDir: root, cacheFile: cacheURL)
        scan(scanner)

        XCTAssertEqual(scanner.totalCost, 25.50, accuracy: 0.0001)
        XCTAssertEqual(scanner.tokens.output, 1_000_000)
        XCTAssertEqual(scanner.tokens.cacheRead, 1_000_000)
        XCTAssertEqual(scanner.messagesByModel["claude-opus-5"], 2)
    }

    func testUnpricedModelIsCountedNotGuessed() throws {
        try write("a.jsonl", [
            assistantLine(model: "claude-opus-5", input: 0, cacheWrite: 0, cacheRead: 0, output: 1_000_000),
            assistantLine(model: "minimax-m3", input: 0, cacheWrite: 0, cacheRead: 0, output: 9_000_000),
        ])
        let scanner = ClaudeSessionScanner(projectsDir: root, cacheFile: cacheURL)
        scan(scanner)

        // The unpriced model must not invent a rate and inflate the total.
        XCTAssertEqual(scanner.totalCost, 25.0, accuracy: 0.0001)
        XCTAssertEqual(scanner.unpricedModels["minimax-m3"], 1)
        XCTAssertNil(scanner.messagesByModel["minimax-m3"])
    }

    func testIgnoresNonAssistantLinesAndSurvivesGarbage() throws {
        try write("a.jsonl", [
            "{\"type\":\"user\",\"message\":{\"usage\":{\"output_tokens\":999999999}}}",
            "not json at all",
            "",
            assistantLine(model: "claude-opus-5", input: 0, cacheWrite: 0, cacheRead: 0, output: 1_000_000),
        ])
        let scanner = ClaudeSessionScanner(projectsDir: root, cacheFile: cacheURL)
        scan(scanner)

        XCTAssertEqual(scanner.totalCost, 25.0, accuracy: 0.0001)
    }

    /// A line split across two 4 MB reads must still parse — the parser keeps a
    /// partial buffer between chunks, and getting that wrong silently drops usage.
    func testHandlesLinesLargerThanOneReadChunk() throws {
        let filler = String(repeating: "x", count: 5 << 20)
        let padded = """
        {"type":"assistant","timestamp":"\(today())T12:00:00.000Z","pad":"\(filler)","message":{"model":"claude-opus-5","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1000000}}}
        """
        try write("big.jsonl", [padded, assistantLine(model: "claude-opus-5", input: 0, cacheWrite: 0, cacheRead: 0, output: 1_000_000)])
        let scanner = ClaudeSessionScanner(projectsDir: root, cacheFile: cacheURL)
        scan(scanner)

        XCTAssertEqual(scanner.totalCost, 50.0, accuracy: 0.0001, "a line spanning chunk boundaries was dropped")
    }

    func testDailySeriesCoversWholeWindowIncludingEmptyDays() throws {
        try write("a.jsonl", [assistantLine(model: "claude-opus-5", input: 0, cacheWrite: 0, cacheRead: 0, output: 1_000_000)])
        let scanner = ClaudeSessionScanner(projectsDir: root, cacheFile: cacheURL, windowDays: 7)
        scan(scanner)

        let series = scanner.dailySeries
        XCTAssertEqual(series.count, 7)
        XCTAssertEqual(series.last?.day, today())
        XCTAssertEqual(series.last?.cost ?? 0, 25.0, accuracy: 0.0001)
        XCTAssertEqual(series.first?.cost ?? -1, 0, "days with no traffic must report zero, not be missing")
    }

    func testSecondScanReusesCacheForUnchangedFiles() throws {
        try write("a.jsonl", [assistantLine(model: "claude-opus-5", input: 0, cacheWrite: 0, cacheRead: 0, output: 1_000_000)])
        let scanner = ClaudeSessionScanner(projectsDir: root, cacheFile: cacheURL)
        scan(scanner)
        let first = scanner.totalCost

        // A fresh scanner reading the same cache file must reach the same total.
        let reopened = ClaudeSessionScanner(projectsDir: root, cacheFile: cacheURL)
        scan(reopened)
        XCTAssertEqual(reopened.totalCost, first, accuracy: 0.0001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
    }
}
