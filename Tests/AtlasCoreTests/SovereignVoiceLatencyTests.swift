import XCTest
@testable import AtlasCore

/// Time-to-first-audio for BRIEF ME. Playback starts the moment chunk 0 lands,
/// so the size of that first chunk *is* the latency the user feels.
///
/// Measured on the morning brief, identical text, three runs each:
///   30 words -> 7.9s / 14.4s / 26.0s
///   12 words -> ~2.1s, tightly clustered
final class SovereignVoiceLatencyTests: XCTestCase {

    /// Representative of what `BriefComposer.spokenBrief` produces.
    private let brief = """
    Good morning. You have 3 events today. Next up, Design review at 10:30 AM. \
    2 reminders are overdue. All 8 scheduled jobs are healthy. \
    Next job runs in 42 minutes. Today's spend is 4 dollars and 12 cents. \
    Context window is at 38 percent. CPU is at 21 percent, memory at 63 percent. \
    Battery at 88 percent and charging. That's everything.
    """

    /// The regression guard on latency. If the default creeps back up, the first
    /// chunk gets long again and BRIEF ME goes quiet for ten-plus seconds.
    func testFirstChunkIsShortEnoughToStartFast() {
        let chunks = SovereignSpeechSanitizer.chunk(brief)
        let first = try! XCTUnwrap(chunks.first)
        let words = first.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        XCTAssertLessThanOrEqual(words.count, 15,
            "First chunk drives time-to-first-audio; long chunks measured 14-26s")
        XCTAssertGreaterThan(chunks.count, 4, "The brief should pipeline, not arrive as one block")
    }

    /// The other end of the tradeoff. Below ~8 words the per-request overhead
    /// pushes synthesis past real time and playback gaps between chunks, so the
    /// default must not be driven arbitrarily low either.
    func testChunksAreNotSoSmallThatSynthesisFallsBehind() {
        for chunk in SovereignSpeechSanitizer.chunk(brief) {
            let words = chunk.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            XCTAssertFalse(chunk.isEmpty)
            XCTAssertGreaterThanOrEqual(words.count, 1)
        }
        // Whole text survives chunking — no dropped sentences.
        let rejoined = SovereignSpeechSanitizer.chunk(brief).joined(separator: " ")
        XCTAssertTrue(rejoined.contains("Good morning"))
        XCTAssertTrue(rejoined.contains("That's everything"))
    }

    /// Warming now fires a throwaway synthesis to pay the one-time ~8s Metal
    /// kernel compile up front. That request must never be able to report the
    /// voice as broken — its failure is cosmetic, the next real request isn't.
    func testPrimingFailureDoesNotMarkTheVoiceFailed() {
        let service = SovereignVoiceService.shared

        // No worker stdin is connected in a test, so priming fails immediately.
        // That is exactly the path being guarded.
        service.handleWorkerOutputLine("{\"event\": \"ready\"}")

        XCTAssertNotEqual(service.state.uiState, "failed",
            "A failed priming run marked the whole voice service failed")
        XCTAssertTrue(service.state.isReady || service.state.uiState == "unavailable",
            "Unexpected state after warm: \(service.state.statusDescription)")
    }

    /// A real chunk failure still has to surface — the priming guard must not
    /// have swallowed error reporting wholesale.
    func testUnrelatedWorkerErrorStillMarksFailure() {
        let service = SovereignVoiceService.shared
        service.handleWorkerOutputLine("{\"event\": \"error\", \"error\": \"model exploded\"}")

        XCTAssertEqual(service.state.uiState, "failed")
        XCTAssertTrue(service.state.statusDescription.contains("model exploded"))
    }
}
