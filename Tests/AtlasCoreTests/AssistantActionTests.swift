import XCTest

@testable import AtlasCore

/// The boundary between `assistant.html` and the chat sessions.
///
/// This page fronts an uncensored model with no tools and no approval step, so
/// the vocabulary being fixed is what keeps a page bug — or text a model wrote
/// that reached the page — from asking for anything but a reply.
final class AssistantActionTests: XCTestCase {

    private func decode(_ json: String) -> AssistantAction? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AssistantAction.self, from: data)
    }

    // MARK: - The allowlist

    func testEveryAllowlistedActionDecodes() {
        for kind in AssistantActionKind.allCases {
            XCTAssertNotNil(decode(#"{"action":"\#(kind.rawValue)"}"#),
                            "\(kind.rawValue) is in the allowlist and must decode")
        }
    }

    func testMessagesOutsideTheAllowlistAreRejected() {
        let hostile = [
            #"{"action":"eval","code":"fetch('https://example.com')"}"#,
            #"{"action":"runShell","cmd":"rm -rf /"}"#,
            #"{"action":"revealDatabaseKey"}"#,
            #"{"action":"readFile","path":"/etc/passwd"}"#,
            #"{"action":"sendMessage"}"#,
            #"{"action":""}"#,
            #"{}"#
        ]
        for message in hostile {
            XCTAssertNil(decode(message), "\(message) must not decode into an action")
        }
    }

    // MARK: - Prompts

    func testPromptMustHaveContent() {
        let blank = decode(#"{"action":"send","text":"   \n  "}"#)!
        XCTAssertThrowsError(try AssistantActionValidator.prompt(from: blank).get())

        let missing = decode(#"{"action":"send"}"#)!
        XCTAssertThrowsError(try AssistantActionValidator.prompt(from: missing).get())
    }

    func testPromptIsTrimmed() throws {
        let action = decode(#"{"action":"send","text":"  write me a poem  "}"#)!
        let prompt = try AssistantActionValidator.prompt(from: action).get()
        XCTAssertEqual(prompt, "write me a poem")
    }

    /// The page must be able to send anything the user typed. This is an
    /// uncensored model by design; refusing content here would be the wrong
    /// layer and would silently break the feature.
    func testPromptContentIsNotFiltered() throws {
        for text in ["</script><img src=x>", "DROP TABLE messages;", "🙂 ünïcøde"] {
            let action = decode("{\"action\":\"send\",\"text\":\(jsonString(text))}")!
            XCTAssertEqual(try AssistantActionValidator.prompt(from: action).get(), text)
        }
    }

    private func jsonString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let array = String(data: data, encoding: .utf8)!
        return String(array.dropFirst().dropLast())
    }

    // MARK: - Identifiers

    func testIdentifiersMustBePresent() {
        XCTAssertThrowsError(try AssistantActionValidator.identifier("", "conversation").get())
        XCTAssertThrowsError(try AssistantActionValidator.identifier(nil, "conversation").get())
        XCTAssertEqual(try? AssistantActionValidator.identifier(" abc ", "conversation").get(), "abc")
    }

    // MARK: - Sampling

    func testTemperatureAcceptsTheSliderRange() throws {
        for value in ["0", "0.7", "1", "2"] {
            XCTAssertNoThrow(try AssistantActionValidator.temperature(value).get(),
                             "\(value) is inside 0...2")
        }
    }

    /// Outside 0…2 is not a position the slider can produce, so it is refused
    /// rather than clamped — clamping would hide a page bug instead of showing it.
    func testTemperatureOutsideTheRangeIsRefused() {
        for value in ["-0.1", "2.1", "99"] {
            XCTAssertThrowsError(try AssistantActionValidator.temperature(value).get(),
                                 "\(value) is outside 0...2")
        }
    }

    func testTemperatureRejectsNonsense() {
        for value in ["hot", "", "0.7.1"] {
            XCTAssertThrowsError(try AssistantActionValidator.temperature(value).get())
        }
    }

    func testTokenCountsMustBePositiveAndBounded() {
        XCTAssertEqual(try? AssistantActionValidator.tokens("4096", field: "Max tokens",
                                                            limit: 32_000).get(), 4096)
        for bad in ["0", "-1", "40000", "lots", ""] {
            XCTAssertThrowsError(
                try AssistantActionValidator.tokens(bad, field: "Max tokens", limit: 32_000).get(),
                "\(bad) must be refused")
        }
    }

    // MARK: - Mode

    func testOnlyTheTwoModesAreAccepted() {
        XCTAssertEqual(try? AssistantActionValidator.mode("direct").get(), "direct")
        XCTAssertEqual(try? AssistantActionValidator.mode("sovereign").get(), "sovereign")
        for bad in ["", "Direct", "admin", "root"] {
            XCTAssertThrowsError(try AssistantActionValidator.mode(bad).get())
        }
    }

    // MARK: - Shape

    func testActionsCarryTheFieldsTheyNeed() throws {
        let edit = decode(#"{"action":"editAndResend","id":"m1","text":"rewritten"}"#)!
        XCTAssertEqual(edit.id, "m1")
        XCTAssertEqual(edit.text, "rewritten")

        let context = decode(#"{"action":"setContextProjects","ids":["p1","p2"]}"#)!
        XCTAssertEqual(context.ids, ["p1", "p2"])

        let voice = decode(#"{"action":"setSpeakReplies","enabled":true}"#)!
        XCTAssertEqual(voice.enabled, true)
    }
}
