import Foundation
import Combine
import WebKit
import AtlasCore

/// Sits between `assistant.html` and the chat sessions.
///
/// The page owns everything on screen; this owns everything that touches a
/// session, the store, or the voice service. The page posts a named action from
/// `AssistantActionKind` and nothing else decodes.
///
/// Streaming is the reason this is not shaped like `FinancesBridge`. Finances
/// sends a fresh snapshot after each write, which is fine at one write per
/// click. Here a reply arrives token by token, so the transcript is diffed and
/// only changed messages are patched — a full snapshot per token would rebuild
/// the DOM tens of times a second and lose the caret, the scroll position and
/// any text selected mid-reply.
@MainActor
final class AssistantBridge {
    private weak var webView: WKWebView?
    private var pageIsReady = false
    private var pending: [(function: String, json: String)] = []

    private let direct: DirectChatSession
    private let voice: SovereignVoiceService
    private var watchers: Set<AnyCancellable> = []

    /// Which brain answers. Sovereign's transcript lives in the app rather than
    /// in a session, so it is held here alongside.
    private var mode = "direct"
    private var sovereignMessages: [ChatMessage] = []
    /// The conversation-list filter the page last asked for, so a rename or a
    /// delete refreshes the same view rather than resetting it.
    private var conversationQuery = ""

    /// What the page currently shows, so streaming only sends real changes.
    private var sentMessages: [String: String] = [:]
    private var sentIDs: [String] = []

    /// Both singletons are main-actor isolated, so they are resolved here
    /// rather than as default arguments — a default is evaluated in the
    /// caller's context, which is not guaranteed to be the main actor.
    init(direct: DirectChatSession? = nil, voice: SovereignVoiceService? = nil) {
        self.direct = direct ?? .shared
        self.voice = voice ?? .shared
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        // A new web view means a fresh page: anything already sent is gone.
        pageIsReady = false
        sentMessages = [:]
        sentIDs = []
    }

    func pageDidLoad() {
        pageIsReady = true
        let queued = pending
        pending = []
        for call in queued { push(call.function, call.json) }
        observeSession()
        sendEverything()
    }

    // MARK: - Watching the session

    /// Mirrors the session into the page.
    ///
    /// Set up once the page is up rather than in `init`: a publisher that fires
    /// before there is anywhere to send to just fills the pending queue with
    /// snapshots nobody will read.
    private func observeSession() {
        guard watchers.isEmpty else { return }

        direct.$messages
            .sink { [weak self] messages in
                guard let self, self.mode == "direct" else { return }
                self.syncTranscript(messages)
            }
            .store(in: &watchers)

        direct.$isStreaming
            .removeDuplicates()
            .sink { [weak self] streaming in
                guard let self else { return }
                self.push("streaming", self.encode(["streaming": streaming]))
                // The last token and the end of the stream arrive together, so
                // the final text needs one more pass with the cursor removed.
                if !streaming, self.mode == "direct" {
                    self.syncTranscript(self.direct.messages)
                    self.sendStatus()
                }
            }
            .store(in: &watchers)

        direct.$progress
            .sink { [weak self] _ in self?.sendStatus() }
            .store(in: &watchers)

        direct.$lastError
            .removeDuplicates()
            .sink { [weak self] _ in self?.sendStatus() }
            .store(in: &watchers)

        direct.$settings
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.sendSettings()
                self?.sendConversations()
            }
            .store(in: &watchers)

        direct.$conversationTitle
            .removeDuplicates()
            .sink { [weak self] _ in self?.sendConversations() }
            .store(in: &watchers)
    }

    // MARK: - Actions

    func handle(_ action: AssistantAction) {
        switch action.action {
        case .load:
            sendEverything()

        // MARK: Conversation flow

        case .send:
            guard mode == "direct" else {
                // Sovereign missions still run through the SwiftUI path; the
                // page is told rather than left waiting for a reply.
                return refuse(.unavailable("Sovereign missions are not wired to this page yet."))
            }
            guard FeatherlessClient.shared.hasKey else {
                return refuse(.unavailable(
                    "No Featherless API key. Set FEATHERLESS_API_KEY in ~/.hermes/.env, or add one in Settings."))
            }
            switch AssistantActionValidator.prompt(from: action) {
            case .success(let prompt): direct.send(prompt)
            case .failure(let refusal): refuse(refusal)
            }

        case .stop:
            direct.stop()

        case .regenerate:
            // A model id here means "try that one instead", which is how the
            // page offers a retry with a different brain.
            direct.regenerate(using: action.model?.isEmpty == false ? action.model : nil)

        case .continueReply:
            direct.continueReply()

        case .editAndResend:
            switch AssistantActionValidator.identifier(action.id, "message") {
            case .failure(let refusal): refuse(refusal)
            case .success(let id):
                switch AssistantActionValidator.prompt(from: action) {
                case .success(let text): direct.editAndResend(id, to: text)
                case .failure(let refusal): refuse(refusal)
                }
            }

        // MARK: Conversations

        case .newConversation:
            direct.newConversation()
            sendEverything()

        case .openConversation:
            switch AssistantActionValidator.identifier(action.id, "conversation") {
            case .failure(let refusal): refuse(refusal)
            case .success(let id):
                guard let conversation = direct.conversations(matching: "").first(where: { $0.id == id })
                else { return refuse(.notFound("conversation")) }
                direct.load(conversation)
                sendEverything()
            }

        case .renameConversation:
            switch AssistantActionValidator.identifier(action.id, "conversation") {
            case .failure(let refusal): refuse(refusal)
            case .success(let id):
                let title = (action.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return refuse(.missing("A title")) }
                guard let conversation = direct.conversations(matching: "").first(where: { $0.id == id })
                else { return refuse(.notFound("conversation")) }
                direct.rename(conversation, to: title)
                sendConversations()
            }

        case .deleteConversation:
            switch AssistantActionValidator.identifier(action.id, "conversation") {
            case .failure(let refusal): refuse(refusal)
            case .success(let id):
                guard let conversation = direct.conversations(matching: "").first(where: { $0.id == id })
                else { return refuse(.notFound("conversation")) }
                direct.delete(conversation)
                sendEverything()
            }

        case .searchConversations:
            conversationQuery = action.query ?? ""
            sendConversations()

        // MARK: Mode

        case .setMode:
            switch AssistantActionValidator.mode(action.mode) {
            case .failure(let refusal): refuse(refusal)
            case .success(let next):
                mode = next
                // The other mode is a different conversation entirely, so the
                // page is replaced rather than patched.
                setTranscript(mode == "direct" ? direct.messages : sovereignMessages)
                sendStatus()
            }

        // MARK: Model and sampling

        case .setModel:
            let model = (action.model ?? "").trimmingCharacters(in: .whitespaces)
            guard !model.isEmpty else { return refuse(.missing("A model")) }
            direct.settings.model = model

        case .refreshModels:
            loadCatalogue()

        case .toggleFavourite:
            let model = (action.model ?? "").trimmingCharacters(in: .whitespaces)
            guard !model.isEmpty else { return refuse(.missing("A model")) }
            if let index = direct.settings.favorites.firstIndex(of: model) {
                direct.settings.favorites.remove(at: index)
            } else {
                direct.settings.favorites.append(model)
            }

        case .setSampling:
            switch AssistantActionValidator.temperature(action.temperature) {
            case .failure(let refusal): return refuse(refusal)
            case .success(let value): direct.settings.temperature = value
            }
            switch AssistantActionValidator.tokens(action.maxTokens, field: "Max tokens", limit: 32_000) {
            case .failure(let refusal): return refuse(refusal)
            case .success(let value): direct.settings.maxTokens = value
            }
            switch AssistantActionValidator.tokens(action.contextTokens, field: "Context", limit: 200_000) {
            case .failure(let refusal): return refuse(refusal)
            case .success(let value): direct.settings.contextTokens = value
            }

        case .setPersona:
            let persona = action.text ?? ""
            // A model id scopes the persona to that model; without one it is the
            // default every model falls back to.
            if let model = action.model, !model.isEmpty {
                if persona.isEmpty { direct.settings.modelPersonas.removeValue(forKey: model) }
                else { direct.settings.modelPersonas[model] = persona }
            } else {
                direct.settings.defaultPersona = persona
            }

        // MARK: Voice

        case .setSpeakReplies:
            direct.settings.speakReplies = action.enabled ?? false

        case .stopSpeaking:
            voice.stop()
            // Presence tracks whether it is mid-utterance, so silence is not
            // enough — it has to be told the utterance ended or the HUD stays
            // in its speaking state.
            SovereignPresenceStateManager.shared.setRestingState(.idle)

        // MARK: Saved prompts

        case .savePrompt:
            let prompt = (action.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return refuse(.missing("A prompt")) }
            guard !direct.settings.savedPrompts.contains(prompt) else { return }
            direct.settings.savedPrompts.append(prompt)

        case .deletePrompt:
            let prompt = action.text ?? ""
            direct.settings.savedPrompts.removeAll { $0 == prompt }

        // MARK: Sovereign context

        case .setContextProjects, .setContextVaults:
            // Held for the Sovereign path, which still runs through SwiftUI.
            break

        case .exportTranscript:
            exportTranscript()
        }
    }

    // MARK: - Sending state

    private func sendEverything() {
        setTranscript(mode == "direct" ? direct.messages : sovereignMessages)
        sendConversations()
        sendSettings()
        sendStatus()
    }

    /// Replaces the whole transcript. Used on load and when the conversation
    /// changes underneath.
    private func setTranscript(_ messages: [ChatMessage]) {
        let streamingID = direct.isStreaming ? messages.last?.id : nil
        let payload = messages.map { encodeMessage($0, streaming: $0.id == streamingID) }
        sentIDs = messages.map(\.id)
        sentMessages = Dictionary(uniqueKeysWithValues: zip(sentIDs, payload.map { encode($0) }))
        push("setAll", encode(payload))
    }

    /// Pushes whatever actually changed.
    ///
    /// Called on every token while a reply streams, so it must not rebuild the
    /// page: as long as the transcript only grew at the end, each changed
    /// message is patched in place. Anything else — loading another
    /// conversation, deleting, editing an earlier turn — is a full replace.
    private func syncTranscript(_ messages: [ChatMessage]) {
        guard messages.map(\.id).starts(with: sentIDs) else {
            setTranscript(messages)
            return
        }
        let streamingID = direct.isStreaming ? messages.last?.id : nil
        sentIDs = messages.map(\.id)
        for message in messages {
            let payload = encodeMessage(message, streaming: message.id == streamingID)
            let json = encode(payload)
            guard sentMessages[message.id] != json else { continue }
            sentMessages[message.id] = json
            push("update", json)
        }
    }

    private func sendConversations() {
        let rows = direct.conversations(matching: conversationQuery).map { conversation -> [String: Any] in
            [
                "id": conversation.id,
                "title": conversation.title,
                "model": conversation.model,
                "updated": Self.stamp.string(from: conversation.updatedAt),
                "current": conversation.id == direct.conversationID
            ]
        }
        push("conversations", encode([
            "query": conversationQuery,
            "rows": rows,
            "currentTitle": direct.conversationTitle
        ]))
    }

    /// The Featherless catalogue, so the picker can show what each model is
    /// rather than a 70-character id the user has to decode.
    ///
    /// Fetched rather than guessed: context length and whether a model is on the
    /// current plan are facts only the API has, and picking a gated model is a
    /// failure that only shows up as a refused reply.
    private func loadCatalogue() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await FeatherlessClient.shared.catalog()
                await MainActor.run { self.sendModels(models) }
            } catch {
                await MainActor.run {
                    self.push("models", self.encode([
                        "error": "Could not reach Featherless: \(error.localizedDescription)",
                        "rows": []
                    ]))
                }
            }
        }
    }

    private func sendModels(_ models: [FeatherlessModel]) {
        let favourites = Set(direct.settings.favorites)
        let rows = models.map { model -> [String: Any] in
            var row: [String: Any] = [
                "id": model.id,
                "name": FeatherlessModel.displayName(model.id),
                "author": FeatherlessModel.author(model.id),
                "uncensored": model.looksUncensored,
                "favourite": favourites.contains(model.id),
                "current": model.id == direct.settings.model
            ]
            if let context = model.context_length {
                row["context"] = context
                // Rounded for reading: "32K" is the useful fact, 32768 is noise.
                row["contextLabel"] = context >= 1000 ? "\(context / 1000)K" : "\(context)"
            }
            if let klass = model.model_class { row["class"] = klass }
            // A model you cannot run is worth showing and worth marking, so the
            // picker explains a refusal before it happens rather than after.
            row["available"] = model.available_on_current_plan ?? true
            row["gated"] = model.is_gated ?? false
            return row
        }
        push("models", encode(["rows": rows]))
    }

    private func sendSettings() {
        let s = direct.settings
        push("settings", encode([
            "model": s.model,
            // Sampling goes out as text for the same reason it comes back as
            // text: the page never has to render a float it might round.
            "temperature": String(format: "%.2f", s.temperature),
            "maxTokens": String(s.maxTokens),
            "contextTokens": String(s.contextTokens),
            "defaultPersona": s.defaultPersona,
            "persona": s.persona(forModel: s.model),
            "speakReplies": s.speakReplies,
            "savedPrompts": s.savedPrompts,
            "favourites": s.favorites
        ]))
    }

    private func sendStatus() {
        push("status", encode([
            "mode": mode,
            "streaming": direct.isStreaming,
            "hasKey": FeatherlessClient.shared.hasKey,
            "error": direct.lastError as Any,
            "didSummarize": direct.didSummarize,
            "truncated": direct.lastReplyTruncated,
            "contextFill": direct.contextFill,
            "speaking": voice.state.isPlaying,
            "tokens": direct.progress.tokenCount,
            // Queued means the request is out but nothing has come back yet,
            // which reads very differently from a slow reply.
            "queued": direct.progress.isQueued,
            "elapsed": direct.progress.startedAt.map { Date().timeIntervalSince($0) } as Any
        ]))
    }

    private func exportTranscript() {
        let messages = mode == "direct" ? direct.messages : sovereignMessages
        let text = messages.map { "\($0.role.rawValue.uppercased())\n\($0.text)" }
            .joined(separator: "\n\n---\n\n")
        // The page cannot reach the pasteboard, and should not be able to.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        push("note", encode(["message": "Transcript copied (\(messages.count) messages)"]))
    }

    // MARK: - Encoding

    /// The shape the page expects. Separate from `ChatMessage` so the contract
    /// is explicit and the model stays free of view concerns.
    private func encodeMessage(_ message: ChatMessage, streaming: Bool) -> [String: Any] {
        // `ChatRole.assistant` is spelled "Sovereign" in the model — a leftover
        // from when Sovereign was the only assistant. In Direct mode the reply
        // comes from a Featherless model with no tools and no approvals, and
        // calling that Sovereign is simply wrong.
        let speaker: String
        switch message.role {
        case .user: speaker = "You"
        case .assistant: speaker = mode == "direct" ? "Model" : "Sovereign"
        default: speaker = message.role.rawValue
        }

        return [
            "id": message.id,
            "role": message.role.rawValue,
            "speaker": speaker,
            "subtitle": message.executionLocation.rawValue,
            "text": message.text,
            "streaming": streaming,
            "files": message.touchedFiles,
            "tools": message.toolCalls,
            "reasoning": message.reasoning,
            "pendingApproval": message.isPendingApproval,
            "at": Self.stamp.string(from: message.timestamp)
        ]
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private func refuse(_ refusal: AssistantRefusal) {
        push("error", encode(["message": refusal.message]))
    }

    /// Calls a function on the page, queueing until it has loaded.
    ///
    /// The payload travels as a bound argument, never spliced into script text —
    /// this page renders output from an uncensored model, so no amount of
    /// quoting in that output can reach the interpreter.
    private func push(_ function: String, _ json: String) {
        guard let webView, pageIsReady else {
            pending.append((function, json))
            return
        }
        webView.callAsyncJavaScript("window.atlasAssistant.\(function)(json)",
                                    arguments: ["json": json], in: nil, in: .page) { result in
            if case .failure(let error) = result {
                NSLog("[ATLAS Assistant] %@ failed: %@", function, error.localizedDescription)
            }
        }
    }

    private func encode(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8)
        else {
            NSLog("[ATLAS Assistant] could not encode a payload for the page")
            return "null"
        }
        return text
    }
}
