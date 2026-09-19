import Foundation

// MARK: - Actions

/// Everything `assistant.html` is allowed to ask for.
///
/// The Assistant page fronts an uncensored model with no tools and no approval
/// step, so the narrowness of this list is what stands between the page and the
/// rest of the app. A fixed vocabulary means a bug in the page — or text a model
/// wrote that somehow reached it — can ask for a reply, not for a shell.
public enum AssistantActionKind: String, Decodable, CaseIterable, Sendable {
    /// Hand over the whole snapshot: transcript, conversations, settings, models.
    case load

    // Conversation flow.
    case send
    case stop
    case regenerate
    case continueReply
    case editAndResend

    // Conversation management.
    case newConversation
    case openConversation
    case renameConversation
    case deleteConversation
    case searchConversations

    // Which brain answers.
    case setMode

    // Model and sampling.
    case setModel
    case toggleFavourite
    /// Ask for the Featherless catalogue. Async, so it arrives separately.
    case refreshModels
    case setSampling
    case setPersona

    // Voice.
    case setSpeakReplies
    case stopSpeaking

    // Saved prompts.
    case savePrompt
    case deletePrompt

    // Sovereign context selection.
    case setContextProjects
    case setContextVaults

    case exportTranscript
}

/// One decoded message from the page.
///
/// Every field is optional because one struct serves twenty-odd actions; which
/// fields must be present is decided per action by the validator rather than by
/// the shape of the type.
public struct AssistantAction: Decodable, Sendable {
    public let action: AssistantActionKind

    /// Prompt text, a new conversation title, a persona, or a saved prompt —
    /// whichever the action calls for.
    public let text: String?
    /// A conversation id or a message id.
    public let id: String?
    public let query: String?
    public let mode: String?
    public let model: String?

    /// Sampling. Sent as text and parsed here, so the page never hands over a
    /// number a JSON float already rounded.
    public let temperature: String?
    public let maxTokens: String?
    public let contextTokens: String?

    public let enabled: Bool?
    public let ids: [String]?
}

/// Why a request was refused, in words the page can show as-is.
public enum AssistantRefusal: Error, Equatable, Sendable {
    case missing(String)
    case badNumber(String, String)
    case outOfRange(String, String)
    case unknownValue(String, String)
    case notFound(String)
    case unavailable(String)

    public var message: String {
        switch self {
        case .missing(let field):
            return "\(field) is required."
        case .badNumber(let field, let value):
            return "\"\(value)\" is not a valid \(field)."
        case .outOfRange(let field, let allowed):
            return "\(field) must be \(allowed)."
        case .unknownValue(let field, let value):
            return "\(value) is not a valid \(field)."
        case .notFound(let what):
            return "That \(what) no longer exists."
        case .unavailable(let why):
            return why
        }
    }
}

// MARK: - Validation

/// Checks what the page sent before any of it reaches a session.
///
/// Separate from the bridge so the rules can be tested without a web view.
public enum AssistantActionValidator {

    /// A prompt worth sending: non-empty once trimmed.
    public static func prompt(from action: AssistantAction) -> Result<String, AssistantRefusal> {
        let text = (action.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.missing("A message")) }
        return .success(text)
    }

    public static func identifier(_ value: String?,
                                  _ what: String) -> Result<String, AssistantRefusal> {
        let id = (value ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return .failure(.missing("\(what) id")) }
        return .success(id)
    }

    /// Temperature, top of the sampling controls. Outside 0…2 is not a slider
    /// position the page could have produced, so it is refused rather than
    /// clamped — clamping hides a page bug instead of surfacing it.
    public static func temperature(_ value: String?) -> Result<Double, AssistantRefusal> {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return .failure(.missing("Temperature"))
        }
        guard let number = Double(text) else {
            return .failure(.badNumber("temperature", text))
        }
        guard (0...2).contains(number) else {
            return .failure(.outOfRange("Temperature", "between 0 and 2"))
        }
        return .success(number)
    }

    /// A token count: a positive whole number inside what the models accept.
    public static func tokens(_ value: String?, field: String,
                              limit: Int) -> Result<Int, AssistantRefusal> {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return .failure(.missing(field))
        }
        guard let number = Int(text) else {
            return .failure(.badNumber(field.lowercased(), text))
        }
        guard number > 0, number <= limit else {
            return .failure(.outOfRange(field, "between 1 and \(limit)"))
        }
        return .success(number)
    }

    public static func mode(_ value: String?) -> Result<String, AssistantRefusal> {
        let text = (value ?? "").trimmingCharacters(in: .whitespaces)
        guard ["direct", "sovereign"].contains(text) else {
            return .failure(.unknownValue("mode", text))
        }
        return .success(text)
    }
}
