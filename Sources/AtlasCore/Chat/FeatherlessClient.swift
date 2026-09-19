import Foundation

/// Talks to Featherless directly, for Direct mode.
///
/// There is no local proxy in front of this. `~/featherless-chat/server.py` existed
/// to keep the API key out of browser JavaScript; ATLAS's transcript renderer is a
/// web view whose CSP denies every network destination and which never sees the key,
/// so the proxy guarded nothing once ATLAS became the front end.
public final class FeatherlessClient {
    public static let shared = FeatherlessClient()

    private let base = URL(string: "https://api.featherless.ai/v1")!
    /// Where Hermes keeps the key; read once, then it lives in the Keychain.
    private let hermesEnv = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".hermes/.env")
    private static let keychainAccount = "atlas.featherless.api.key"

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            // A long generation on a 27B can sit quiet for a while before the
            // first token; the default 60s timeout would kill it mid-thought.
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 900
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Key

    /// The API key, migrating it out of `~/.hermes/.env` on first use.
    ///
    /// After the first read the Keychain copy is authoritative, so rotating the
    /// key means updating it in Settings — the env file is a seed, not a mirror.
    public func apiKey() -> String? {
        if let stored = KeychainManager.shared.get(key: Self.keychainAccount), !stored.isEmpty {
            return stored
        }
        guard let seeded = keyFromHermesEnv(), !seeded.isEmpty else { return nil }
        _ = KeychainManager.shared.save(key: Self.keychainAccount, value: seeded)
        return seeded
    }

    public func setAPIKey(_ key: String) -> Bool {
        KeychainManager.shared.save(key: Self.keychainAccount, value: key)
    }

    public var hasKey: Bool { apiKey()?.isEmpty == false }

    private func keyFromHermesEnv() -> String? {
        guard let contents = try? String(contentsOf: hermesEnv, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") {
            guard line.hasPrefix("FEATHERLESS_API_KEY=") else { continue }
            return line.dropFirst("FEATHERLESS_API_KEY=".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    // MARK: - Catalog

    /// Every model Featherless serves. The catalogue is ~22,000 entries and a few
    /// megabytes, so it is fetched once and cached; searching happens locally.
    public func catalog(forceRefresh: Bool = false) async throws -> [FeatherlessModel] {
        if !forceRefresh, let cached = Self.cachedCatalog() { return cached }
        guard let key = apiKey() else { throw FeatherlessError.missingKey }

        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)

        let decoded = try JSONDecoder().decode(FeatherlessModelList.self, from: data)
        Self.writeCatalogCache(data)
        return decoded.data
    }

    private static var catalogCacheURL: URL {
        let support = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ATLAS", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("featherless-models.json")
    }

    /// Cached catalogue, if it is less than a day old. Models are added often
    /// enough to want a refresh button, rarely enough that a day is plenty.
    private static func cachedCatalog() -> [FeatherlessModel]? {
        let url = catalogCacheURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 86_400,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(FeatherlessModelList.self, from: data)
        else { return nil }
        return decoded.data
    }

    private static func writeCatalogCache(_ data: Data) {
        try? data.write(to: catalogCacheURL, options: .atomic)
    }

    // MARK: - Completion

    /// Streams a reply. Yields deltas as they arrive; the caller accumulates.
    ///
    /// Cancelling the task cancels the HTTP request, which is what the Stop
    /// button does — no half-request left running up tokens in the background.
    public func stream(
        model: String,
        messages: [FeatherlessMessage],
        temperature: Double,
        maxTokens: Int
    ) -> AsyncThrowingStream<FeatherlessDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(model: model, messages: messages,
                                                   temperature: temperature,
                                                   maxTokens: maxTokens, stream: true)
                    let (bytes, response) = try await session.bytes(for: request)
                    try await Self.checkStreaming(response, bytes)

                    // Featherless answers immediately with `: FEATHERLESS PROCESSING`
                    // heartbeat comments while the model loads — sometimes for half a
                    // minute on a cold 27B. Saying so beats a cursor that never moves.
                    continuation.yield(.opened)

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(FeatherlessChunk.self, from: data),
                              let choice = chunk.choices.first
                        else { continue }
                        let delta = choice.delta
                        let hasText = delta?.content?.isEmpty == false || delta?.reasoning?.isEmpty == false
                        if hasText || choice.finish_reason != nil {
                            continuation.yield(FeatherlessDelta(content: delta?.content ?? "",
                                                                reasoning: delta?.reasoning ?? "",
                                                                finishReason: choice.finish_reason))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One-shot completion, used for context summaries rather than for chat.
    public func complete(
        model: String,
        messages: [FeatherlessMessage],
        temperature: Double = 0.3,
        maxTokens: Int = 1024
    ) async throws -> String {
        let request = try buildRequest(model: model, messages: messages,
                                       temperature: temperature, maxTokens: maxTokens, stream: false)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        let decoded = try JSONDecoder().decode(FeatherlessCompletion.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    private func buildRequest(
        model: String,
        messages: [FeatherlessMessage],
        temperature: Double,
        maxTokens: Int,
        stream: Bool
    ) throws -> URLRequest {
        guard let key = apiKey() else { throw FeatherlessError.missingKey }
        guard !model.isEmpty else { throw FeatherlessError.noModelSelected }

        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json",
                         forHTTPHeaderField: "Accept")
        request.setValue("ATLAS-Direct/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(FeatherlessRequest(
            model: model,
            messages: messages,
            temperature: temperature,
            max_tokens: maxTokens,
            stream: stream
        ))
        return request
    }

    // MARK: - Errors

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw FeatherlessError.http(http.statusCode, message(from: data))
        }
    }

    /// The streaming variant, which has to drain the body to see the error text.
    private static func checkStreaming(_ response: URLResponse, _ bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode) else { return }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > 8192 { break }
        }
        throw FeatherlessError.http(http.statusCode, message(from: body))
    }

    /// Pulls the human-readable part out of an error body, falling back to the raw text.
    private static func message(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let detail = error["message"] as? String {
                return detail
            }
            if let error = object["error"] as? String { return error }
            if let detail = object["detail"] as? String { return detail }
        }
        let raw = String(data: data.prefix(500), encoding: .utf8) ?? ""
        return raw.isEmpty ? "No detail returned." : raw
    }
}

// MARK: - Types

public struct FeatherlessDelta: Sendable {
    public let content: String
    public let reasoning: String
    /// Featherless sends this on the last chunk. "length" means the reply was cut
    /// off at max_tokens rather than finished — the Continue button keys off it.
    public let finishReason: String?

    public init(content: String, reasoning: String, finishReason: String? = nil) {
        self.content = content
        self.reasoning = reasoning
        self.finishReason = finishReason
    }

    /// Sent once, before any tokens, so the UI can say "queued" honestly rather
    /// than showing a cursor that has not started moving.
    public static let opened = FeatherlessDelta(content: "", reasoning: "", finishReason: nil)
}

public enum FeatherlessError: LocalizedError {
    case missingKey
    case noModelSelected
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No Featherless API key. Add one in Settings, or set FEATHERLESS_API_KEY in ~/.hermes/.env."
        case .noModelSelected:
            return "No model selected."
        case .http(let code, let detail):
            switch code {
            case 401, 403: return "Featherless rejected the API key (\(code)). \(detail)"
            case 429: return "Rate limited by Featherless. \(detail)"
            default: return "Featherless returned \(code). \(detail)"
            }
        }
    }
}

public struct FeatherlessMessage: Codable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// One entry from the catalogue.
public struct FeatherlessModel: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let model_class: String?
    public let context_length: Int?
    public let available_on_current_plan: Bool?
    public let is_gated: Bool?

    public init(id: String, model_class: String? = nil, context_length: Int? = nil,
                available_on_current_plan: Bool? = nil, is_gated: Bool? = nil) {
        self.id = id
        self.model_class = model_class
        self.context_length = context_length
        self.available_on_current_plan = available_on_current_plan
        self.is_gated = is_gated
    }

    public var looksUncensored: Bool { Self.looksUncensored(id) }
    public var displayName: String { Self.displayName(id) }
    public var author: String { Self.author(id) }

    /// Featherless publishes no alignment flag, so this reads the name — which is
    /// how these models are actually labelled by the people who make them. Static
    /// so the UI can label a bare model id without fabricating a catalogue entry.
    public static func looksUncensored(_ id: String) -> Bool {
        let name = id.lowercased()
        return uncensoredMarkers.contains { name.contains($0) }
    }

    private static let uncensoredMarkers = [
        "uncensored", "abliterated", "unaligned", "unfiltered", "unrestricted",
        "heretic", "goetia", "dolphin", "unhinged", "amoral", "nsfw", "defiant"
    ]

    /// "JonathanColetti/Qwen3.8-27B-Uncensored" → "Qwen3.8 27B Uncensored"
    public static func displayName(_ id: String) -> String {
        let tail = id.split(separator: "/").last.map(String.init) ?? id
        return tail.replacingOccurrences(of: "-", with: " ")
    }

    public static func author(_ id: String) -> String {
        let parts = id.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : ""
    }
}

private struct FeatherlessModelList: Codable {
    let data: [FeatherlessModel]
}

private struct FeatherlessRequest: Codable {
    let model: String
    let messages: [FeatherlessMessage]
    let temperature: Double
    let max_tokens: Int
    let stream: Bool
}

private struct FeatherlessChunk: Codable {
    struct Choice: Codable {
        struct Delta: Codable {
            let content: String?
            let reasoning: String?
        }
        let delta: Delta?
        let finish_reason: String?
    }
    let choices: [Choice]
}

private struct FeatherlessCompletion: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}
