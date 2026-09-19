import Foundation
import Combine

/// Drives Direct mode: the uncensored model, no tools, no approvals.
///
/// Everything it says is written to the encrypted `ChatStore`. What reaches
/// `ActivityLedger` is metadata only — which model, how many messages — so usage
/// shows up on the Overview page without any of the content following it there.
@MainActor
public final class DirectChatSession: ObservableObject {
    public static let shared = DirectChatSession()

    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isStreaming = false
    @Published public private(set) var conversationID: String?
    @Published public private(set) var conversationTitle = ""
    /// Set when a send fails, so the transcript can show why instead of nothing.
    @Published public private(set) var lastError: String?
    /// Raised when history has been condensed, so the transcript can say so.
    @Published public private(set) var didSummarize = false
    /// Live progress of the request in flight, for the status line.
    @Published public private(set) var progress = DirectChatProgress()
    /// True when the last reply stopped at max_tokens rather than finishing.
    @Published public private(set) var lastReplyTruncated = false
    /// How full the context window is, 0–1, for the meter.
    @Published public private(set) var contextFill: Double = 0

    @Published public var settings: DirectChatSettings {
        didSet { settings.save() }
    }

    private let client: FeatherlessClient
    private let store: ChatStore
    private var streamTask: Task<Void, Never>?

    public init(client: FeatherlessClient = .shared, store: ChatStore = .shared) {
        self.client = client
        self.store = store
        self.settings = DirectChatSettings.load()
    }

    // MARK: - Conversations

    public func newConversation() {
        stop()
        messages = []
        conversationID = nil
        conversationTitle = ""
        lastError = nil
        didSummarize = false
    }

    public func load(_ conversation: ChatConversation) {
        stop()
        conversationID = conversation.id
        conversationTitle = conversation.title
        messages = store.messages(in: conversation.id)
        lastError = nil
        didSummarize = store.summary(for: conversation.id).through > 0
    }

    public func conversations(matching term: String = "") -> [ChatConversation] {
        term.isEmpty ? store.conversations() : store.search(term)
    }

    public func delete(_ conversation: ChatConversation) {
        store.deleteConversation(conversation.id)
        if conversation.id == conversationID { newConversation() }
    }

    public func rename(_ conversation: ChatConversation, to title: String) {
        store.renameConversation(conversation.id, to: title)
        if conversation.id == conversationID { conversationTitle = title }
    }

    // MARK: - Sending

    public func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        lastError = nil

        // First message names the conversation, so the rail is readable without
        // spending a model call on a title.
        let conversation = conversationID ?? {
            let title = Self.title(from: trimmed)
            let id = store.createConversation(title: title, model: settings.model)
            conversationID = id
            conversationTitle = title
            return id
        }()

        let userMessage = ChatMessage(role: .user, text: trimmed)
        messages.append(userMessage)
        store.save(userMessage, in: conversation, model: settings.model)

        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(reply)
        beginStream(reply: reply, in: conversation)
    }

    /// Runs one request against whatever is currently in `messages`, writing into
    /// `reply`. Send, Continue, Regenerate and Edit all funnel through here so
    /// there is one streaming path to get right.
    private func beginStream(reply initial: ChatMessage, in conversation: String, appending: Bool = false) {
        var reply = initial
        let replyID = reply.id
        let alreadyWritten = appending ? reply.text : ""
        isStreaming = true
        lastReplyTruncated = false
        progress = DirectChatProgress(startedAt: Date())

        streamTask = Task { [settings] in
            do {
                let payload = try await self.payloadMessages(for: conversation)
                let stream = self.client.stream(
                    model: settings.model,
                    messages: payload,
                    temperature: settings.temperature,
                    maxTokens: settings.maxTokens
                )
                for try await delta in stream {
                    if delta.finishReason == "length" { self.lastReplyTruncated = true }
                    guard !delta.content.isEmpty || !delta.reasoning.isEmpty else {
                        // The open signal: still queued at Featherless, no tokens yet.
                        continue
                    }
                    reply.text += delta.content
                    reply.reasoning += delta.reasoning
                    self.progress.recordToken()
                    self.replace(replyID, with: reply)
                }
                if reply.text == alreadyWritten && reply.reasoning.isEmpty {
                    reply.text += "_The model returned nothing._"
                    self.replace(replyID, with: reply)
                }
            } catch {
                self.lastError = error.localizedDescription
            }
            self.finish(reply: reply, id: replyID, in: conversation)
        }
    }

    /// Picks up a reply that stopped at max_tokens, appending rather than
    /// restarting. A 27B hits the 4096 ceiling mid-sentence often enough that
    /// starting over would waste both the tokens and the thought.
    public func continueReply() {
        guard !isStreaming, lastReplyTruncated,
              let conversation = conversationID,
              let last = messages.last, last.role == .assistant
        else { return }
        beginStream(reply: last, in: conversation, appending: true)
    }

    /// Same prompt, new roll — optionally against a different model, so two
    /// models can be compared on the same question.
    public func regenerate(using model: String? = nil) {
        guard !isStreaming,
              let conversation = conversationID,
              let last = messages.last, last.role == .assistant
        else { return }
        if let model { settings.model = model }
        store.deleteFrom(last.id, in: conversation)
        messages.removeLast()
        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(reply)
        beginStream(reply: reply, in: conversation)
    }

    /// Rewrites one of your own messages and re-runs from there. Everything that
    /// followed described a conversation that no longer exists, so it goes.
    public func editAndResend(_ messageID: String, to newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !trimmed.isEmpty,
              let conversation = conversationID,
              let index = messages.firstIndex(where: { $0.id == messageID })
        else { return }

        store.deleteFrom(messageID, in: conversation)
        messages.removeSubrange(index...)

        let edited = ChatMessage(id: messageID, role: .user, text: trimmed)
        messages.append(edited)
        store.save(edited, in: conversation, model: settings.model)

        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(reply)
        beginStream(reply: reply, in: conversation)
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    private func replace(_ id: String, with message: ChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index] = message
    }

    private func finish(reply: ChatMessage, id: String, in conversation: String) {
        replace(id, with: reply)
        isStreaming = false
        progress.finish()
        streamTask = nil
        store.save(reply, in: conversation, model: settings.model)
        logMetadata(for: conversation)
    }

    // MARK: - Context window

    /// Builds what actually gets sent: persona, any carried summary, then as much
    /// recent history as fits under the model's context cap.
    ///
    /// Featherless caps at 32K — the limit that killed the full Hermes integration,
    /// since Hermes needs 64K+. Rather than let old turns fall off silently, the
    /// overflow is condensed into a summary that rides along in every later request.
    private func payloadMessages(for conversation: String) async throws -> [FeatherlessMessage] {
        let budget = settings.contextTokens - settings.maxTokens - 512 // headroom for the reply
        var carried = store.summary(for: conversation)

        let overhead = Self.estimateTokens(settings.persona(forModel: settings.model))
            + Self.estimateTokens(carried.text)
        let split = Self.split(messages, budget: budget - overhead)

        // Anything that did not fit gets condensed, and the condensed form is what
        // later turns carry instead. Re-summarising every single turn would spend a
        // model call per message, so it only re-runs once a few more have fallen off.
        if split.dropped.count >= carried.through + Self.resummarizeEvery {
            do {
                carried.text = try await summarize(split.dropped, previous: carried.text)
                store.setSummary(carried.text, through: split.dropped.count, for: conversation)
                didSummarize = !carried.text.isEmpty
            } catch {
                // A failed summary must not fail the message the user actually sent.
                // The older turns just stay dropped this time round.
                NSLog("[ATLAS Chat] summary failed: %@", error.localizedDescription)
            }
        }
        let recent = split.recent

        // How full the window is after this request is assembled, for the meter.
        contextFill = min(1, Double(used(recent) + overhead + settings.maxTokens)
                             / Double(max(1, settings.contextTokens)))

        var payload: [FeatherlessMessage] = []
        let persona = settings.persona(forModel: settings.model)
        if !persona.isEmpty {
            payload.append(FeatherlessMessage(role: "system", content: persona))
        }
        if !carried.text.isEmpty {
            payload.append(FeatherlessMessage(
                role: "system",
                content: "Earlier in this conversation:\n\(carried.text)"
            ))
        }
        payload.append(contentsOf: recent.map {
            FeatherlessMessage(role: $0.role == .user ? "user" : "assistant", content: $0.text)
        })
        return payload
    }

    private func used(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + Self.estimateTokens($1.text) }
    }

    /// How many further messages must fall out of context before the summary is
    /// rebuilt. Small enough that the notes stay current, big enough that a long
    /// conversation is not paying for a summary on every turn.
    static let resummarizeEvery = 4

    /// Splits history into what fits in `budget` and what does not, newest first
    /// so the most recent turns are the ones that survive. Empty messages — the
    /// in-flight reply — belong to neither side.
    static func split(_ history: [ChatMessage], budget: Int) -> (recent: [ChatMessage], dropped: [ChatMessage]) {
        var recent: [ChatMessage] = []
        var used = 0
        var index = history.count - 1
        while index >= 0 {
            let message = history[index]
            index -= 1
            guard !message.text.isEmpty else { continue }
            let cost = estimateTokens(message.text)
            if used + cost > budget { break }
            used += cost
            recent.insert(message, at: 0)
        }
        let kept = Set(recent.map(\.id))
        let dropped = history.filter { !kept.contains($0.id) && !$0.text.isEmpty }
        return (recent, dropped)
    }

    /// Condenses the turns that fell out of the window. Uses the same model, at a
    /// low temperature — this is bookkeeping, not creative work.
    private func summarize(_ dropped: [ChatMessage], previous: String) async throws -> String {
        let transcript = dropped.suffix(40).map {
            "\($0.role == .user ? "User" : "Assistant"): \($0.text)"
        }.joined(separator: "\n\n")
        guard !transcript.isEmpty else { return previous }

        let instruction = """
        Condense the conversation below into notes that let it continue without the \
        original text: decisions made, facts established, names, and the current thread \
        of discussion. No preamble, no commentary, no more than 400 words.
        """
        var content = transcript
        if !previous.isEmpty {
            content = "Notes so far:\n\(previous)\n\nNewly dropped turns:\n\(transcript)"
        }
        return try await client.complete(
            model: settings.model,
            messages: [
                FeatherlessMessage(role: "system", content: instruction),
                FeatherlessMessage(role: "user", content: content)
            ]
        )
    }

    /// Four characters per token is the usual English rule of thumb. It is an
    /// estimate on purpose: Featherless exposes no tokenizer, and the cost of
    /// being a little conservative is one fewer old turn in context.
    /// ponytail: char heuristic, swap for a real tokenizer if trimming misjudges.
    static func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    static func title(from prompt: String) -> String {
        let line = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        return line.count <= 60 ? line : String(line.prefix(57)) + "…"
    }

    // MARK: - Activity

    /// Metadata only. The prompt and the reply never leave the encrypted store —
    /// what lands in the ledger is enough to see usage on the Overview page and
    /// nothing anybody could read over your shoulder.
    private func logMetadata(for conversation: String) {
        let count = store.messages(in: conversation).count
        ActivityLedger.shared.logActivity(AtlasActivity(
            initiator: "Direct Chat",
            toolName: "DirectChat",
            target: FeatherlessModel.displayName(settings.model),
            actionDescription: "Direct chat · \(count) message\(count == 1 ? "" : "s")",
            riskTier: .readOnly,
            result: "Success"
        ))
    }
}

/// Direct-mode preferences. Model, sampling, persona, and whether replies get read
/// aloud — the voice switch is deliberately separate from the Hermes one.
public struct DirectChatSettings: Codable, Equatable {
    public var model: String
    public var temperature: Double
    public var maxTokens: Int
    public var contextTokens: Int
    /// Applies unless the chosen model has its own; see `persona(forModel:)`.
    public var defaultPersona: String
    public var speakReplies: Bool
    /// Per-model overrides. A model without an entry uses `defaultPersona`.
    public var modelPersonas: [String: String]
    /// Prompts worth keeping around, offered from the composer.
    public var savedPrompts: [String]
    /// Model ids pinned to the front of the picker.
    public var favorites: [String]

    /// The persona a given model actually runs with.
    public func persona(forModel model: String) -> String {
        modelPersonas[model] ?? defaultPersona
    }

    public static let defaultModel = "JonathanColetti/Qwen3.8-27B-Uncensored"

    /// The starting persona. Short on purpose: an unaligned model is worth having
    /// because little stands between you and it, and every line here is one more
    /// thing standing there. Editable in Settings.
    public static let seedPersona = """
    You are the Sovereign, the resident intelligence of ATLAS, a personal command centre.
    Speak plainly and directly. Answer the question that was asked, at the length it \
    deserves. No disclaimers, no moralising, no hedging, and no offers to help further.
    If you don't know, say so.
    """

    public init(
        model: String = DirectChatSettings.defaultModel,
        temperature: Double = 0.8,
        maxTokens: Int = 4096,
        contextTokens: Int = 32_768,
        defaultPersona: String = DirectChatSettings.seedPersona,
        modelPersonas: [String: String] = [:],
        savedPrompts: [String] = [],
        speakReplies: Bool = false,
        favorites: [String] = [
            DirectChatSettings.defaultModel,
            "DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-MTP",
            "Naphula/Goetia-26B-A4B-v1.3-Absolute-Heretic-ARA"
        ]
    ) {
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.contextTokens = contextTokens
        self.defaultPersona = defaultPersona
        self.modelPersonas = modelPersonas
        self.savedPrompts = savedPrompts
        self.speakReplies = speakReplies
        self.favorites = favorites
    }

    private static let defaultsKey = "atlas.directChat.settings"

    public static func load() -> DirectChatSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(DirectChatSettings.self, from: data)
        else { return DirectChatSettings() }
        return decoded
    }

    public init(from decoder: Decoder) throws {
        // Hand-written so settings saved by an earlier build still load: a missing
        // key takes the default instead of throwing the whole object away.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DirectChatSettings()
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? fallback.model
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? fallback.temperature
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? fallback.maxTokens
        contextTokens = try container.decodeIfPresent(Int.self, forKey: .contextTokens) ?? fallback.contextTokens
        defaultPersona = try container.decodeIfPresent(String.self, forKey: .defaultPersona) ?? fallback.defaultPersona
        speakReplies = try container.decodeIfPresent(Bool.self, forKey: .speakReplies) ?? false
        modelPersonas = try container.decodeIfPresent([String: String].self, forKey: .modelPersonas) ?? [:]
        savedPrompts = try container.decodeIfPresent([String].self, forKey: .savedPrompts) ?? []
        favorites = try container.decodeIfPresent([String].self, forKey: .favorites) ?? fallback.favorites
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}


/// Live numbers for the status line.
///
/// Featherless holds a request on `: FEATHERLESS PROCESSING` heartbeats while the
/// model loads — up to half a minute on a cold 27B — so "queued" and "generating"
/// are genuinely different states and the UI says which one it is in.
public struct DirectChatProgress: Equatable {
    public var startedAt: Date?
    public var firstTokenAt: Date?
    public var finishedAt: Date?
    public var tokenCount: Int = 0

    public init(startedAt: Date? = nil) { self.startedAt = startedAt }

    public var isQueued: Bool { startedAt != nil && firstTokenAt == nil }

    /// Seconds waited before the first token arrived, or so far if none has.
    public var timeToFirstToken: TimeInterval? {
        guard let startedAt else { return nil }
        return (firstTokenAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// Deltas per second since the first token. Featherless streams roughly one
    /// token per delta, so this is a close-enough tokens/sec.
    /// ponytail: delta count, swap for usage totals if Featherless ever sends them.
    public var tokensPerSecond: Double? {
        guard let firstTokenAt, tokenCount > 1 else { return nil }
        let elapsed = (finishedAt ?? Date()).timeIntervalSince(firstTokenAt)
        guard elapsed > 0.2 else { return nil }
        return Double(tokenCount) / elapsed
    }

    public mutating func recordToken() {
        if firstTokenAt == nil { firstTokenAt = Date() }
        tokenCount += 1
    }

    public mutating func finish() { finishedAt = Date() }
}

public extension DirectChatSession {
    /// Writes the open conversation into the Obsidian vault as markdown.
    ///
    /// The encrypted store stays the system of record — this is for the threads
    /// worth keeping alongside everything else in the vault. It is deliberately
    /// per-conversation and manual: mirroring every transcript into a synced
    /// plaintext vault would undo the encrypted store.
    @discardableResult
    func exportToVault() throws -> URL {
        guard let conversationID else { throw DirectChatExportError.nothingToExport }
        let saved = store.messages(in: conversationID)
        guard !saved.isEmpty else { throw DirectChatExportError.nothingToExport }

        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Obsidian/MYTHOS Context/Direct Chats", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let title = conversationTitle.isEmpty ? "Direct chat" : conversationTitle
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("\(stamp.string(from: Date())) \(safeTitle).md")

        var out = """
        ---
        title: "\(safeTitle.replacingOccurrences(of: "\"", with: "'"))"
        model: \(settings.model)
        exported: \(ISO8601DateFormatter().string(from: Date()))
        messages: \(saved.count)
        source: ATLAS Direct chat
        ---

        # \(safeTitle)

        """
        for message in saved {
            out += "\n## \(message.role == .user ? "You" : "Sovereign")\n\n\(message.text)\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

public enum DirectChatExportError: LocalizedError {
    case nothingToExport
    public var errorDescription: String? { "There is no conversation to export yet." }
}
