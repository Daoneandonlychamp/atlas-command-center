import XCTest
@testable import AtlasCore

/// Covers the part of Direct mode that decides what the model actually sees.
/// Featherless caps context at 32K, so getting this wrong either wastes the
/// window or silently drops the turn the user just typed.
@MainActor
final class DirectChatContextTests: XCTestCase {
    private func message(_ text: String, role: ChatMessage.ChatRole = .user) -> ChatMessage {
        ChatMessage(role: role, text: text)
    }

    func testEverythingFitsWhenBudgetIsLarge() {
        let history = [message("one"), message("two"), message("three")]
        let split = DirectChatSession.split(history, budget: 10_000)
        XCTAssertEqual(split.recent.map(\.text), ["one", "two", "three"])
        XCTAssertTrue(split.dropped.isEmpty)
    }

    func testNewestTurnsSurviveAndOrderIsPreserved() {
        // Each message is 100 "x" plus its number, so 25 tokens at four
        // characters per token. A budget of 75 fits exactly three of them.
        let history = (1...10).map { message(String(repeating: "x", count: 100) + " \($0)") }
        let split = DirectChatSession.split(history, budget: 75)

        XCTAssertEqual(split.recent.count, 3, "only what fits in the budget is kept")
        XCTAssertEqual(split.recent.map(\.text), Array(history.suffix(3)).map(\.text),
                       "the surviving turns are the newest, still in order")
        XCTAssertEqual(split.dropped.count, 7)
        XCTAssertEqual(split.dropped.first?.text, history.first?.text,
                       "dropped turns stay in order for the summariser")
    }

    func testInFlightEmptyReplyBelongsToNeitherSide() {
        let history = [message("real"), message("", role: .assistant)]
        let split = DirectChatSession.split(history, budget: 10_000)
        XCTAssertEqual(split.recent.map(\.text), ["real"])
        XCTAssertTrue(split.dropped.isEmpty, "the empty streaming placeholder must not be summarised")
    }

    func testATinyBudgetDropsEverythingRatherThanCrashing() {
        let history = [message(String(repeating: "y", count: 400))]
        let split = DirectChatSession.split(history, budget: 1)
        XCTAssertTrue(split.recent.isEmpty)
        XCTAssertEqual(split.dropped.count, 1)
    }

    func testTitleFromPromptTakesTheFirstLine() {
        XCTAssertEqual(DirectChatSession.title(from: "First line\nsecond line"), "First line")
        let long = String(repeating: "z", count: 200)
        XCTAssertEqual(DirectChatSession.title(from: long).count, 58, "long titles are truncated with an ellipsis")
    }

    func testTokenEstimateNeverReturnsZero() {
        XCTAssertEqual(DirectChatSession.estimateTokens(""), 1)
        XCTAssertEqual(DirectChatSession.estimateTokens(String(repeating: "a", count: 400)), 100)
    }

    func testDefaultsAreTheVerifiedUncensoredModels() {
        let settings = DirectChatSettings()
        XCTAssertTrue(FeatherlessModel.looksUncensored(settings.model),
                      "the default model must be flagged so the badge shows")
        XCTAssertEqual(settings.favorites.count, 3)
        XCTAssertEqual(settings.contextTokens, 32_768, "Featherless caps here")
    }

    func testUncensoredDetectionReadsTheModelName() {
        XCTAssertTrue(FeatherlessModel.looksUncensored("JonathanColetti/Qwen3.8-27B-Uncensored"))
        XCTAssertTrue(FeatherlessModel.looksUncensored("Naphula/Goetia-26B-A4B-v1.3-Absolute-Heretic-ARA"))
        XCTAssertFalse(FeatherlessModel.looksUncensored("meta-llama/Llama-3.1-70B-Instruct"))
        XCTAssertEqual(FeatherlessModel.displayName("JonathanColetti/Qwen3.8-27B-Uncensored"),
                       "Qwen3.8 27B Uncensored")
        XCTAssertEqual(FeatherlessModel.author("JonathanColetti/Qwen3.8-27B-Uncensored"), "JonathanColetti")
    }
}

extension DirectChatContextTests {
    func testProgressSeparatesQueuedFromGenerating() {
        var progress = DirectChatProgress(startedAt: Date().addingTimeInterval(-3))
        XCTAssertTrue(progress.isQueued, "no tokens yet means still queued at Featherless")
        XCTAssertNil(progress.tokensPerSecond)

        progress.recordToken()
        XCTAssertFalse(progress.isQueued)
        XCTAssertNotNil(progress.timeToFirstToken)
        XCTAssertEqual(progress.timeToFirstToken ?? 0, 3, accuracy: 0.5,
                       "time to first token measures the queue wait")
    }

    func testTokenRateNeedsMoreThanOneToken() {
        var progress = DirectChatProgress(startedAt: Date())
        progress.recordToken()
        XCTAssertNil(progress.tokensPerSecond, "one token is not a rate")
    }

    func testEmptyProgressSaysNothing() {
        let progress = DirectChatProgress()
        XCTAssertFalse(progress.isQueued, "nothing has been sent yet")
        XCTAssertNil(progress.timeToFirstToken)
    }

    func testPersonaFallsBackToTheDefault() {
        var settings = DirectChatSettings()
        XCTAssertEqual(settings.persona(forModel: "any/model"), settings.defaultPersona)

        settings.modelPersonas["roleplay/model"] = "You are a narrator."
        XCTAssertEqual(settings.persona(forModel: "roleplay/model"), "You are a narrator.")
        XCTAssertEqual(settings.persona(forModel: "other/model"), settings.defaultPersona,
                       "an override applies to its own model only")
    }

    func testSettingsSavedByAnEarlierBuildStillLoad() throws {
        // The shape before per-model personas and saved prompts existed.
        let old = """
        {"model":"a/b","temperature":0.5,"maxTokens":2048,"contextTokens":32768,
         "defaultPersona":"stay short","favorites":["a/b"]}
        """
        let decoded = try JSONDecoder().decode(DirectChatSettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.model, "a/b")
        XCTAssertEqual(decoded.defaultPersona, "stay short")
        XCTAssertTrue(decoded.savedPrompts.isEmpty, "a missing key takes its default")
        XCTAssertTrue(decoded.modelPersonas.isEmpty)
        XCTAssertFalse(decoded.speakReplies)
    }
}
