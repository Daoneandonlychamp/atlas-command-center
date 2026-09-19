import Foundation

// MARK: - Core Data Models

public struct CanonicalID: Hashable, Codable, Sendable {
    public enum MediaType: String, Codable, Sendable {
        case movie
        case tv
    }

    public let id: String
    public let type: MediaType
    public let season: Int?
    public let episode: Int?

    public init(id: String, type: MediaType, season: Int? = nil, episode: Int? = nil) {
        self.id = id
        self.type = type
        self.season = season
        self.episode = episode
    }
}

public enum StreamFormat: String, Codable, Sendable {
    case hls
    case dash
    case direct
}

public struct ResolvedStream: Equatable, Sendable {
    public let streamURL: URL
    public let format: StreamFormat
    public let headers: [String: String]
    public let providerID: String
    public let resolvedAt: Date

    public init(
        streamURL: URL,
        format: StreamFormat,
        headers: [String: String] = [:],
        providerID: String,
        resolvedAt: Date = Date()
    ) {
        self.streamURL = streamURL
        self.format = format
        self.headers = headers
        self.providerID = providerID
        self.resolvedAt = resolvedAt
    }
}

// MARK: - Errors

public enum ResolutionError: Error, LocalizedError, Equatable {
    case invalidEndpointTemplate(String)
    case unresolvableHost(String)
    case requestFailed(statusCode: Int, message: String)
    case parseFailed(String)
    case probeFailed(String)
    case allProvidersExhausted([String: String])

    public var errorDescription: String? {
        switch self {
        case .invalidEndpointTemplate(let msg):
            return "Invalid endpoint template: \(msg)"
        case .unresolvableHost(let host):
            return "Host unresolvable: \(host)"
        case .requestFailed(let code, let msg):
            return "Upstream request failed (HTTP \(code)): \(msg)"
        case .parseFailed(let msg):
            return "Failed to parse stream URL: \(msg)"
        case .probeFailed(let msg):
            return "Stream health probe failed: \(msg)"
        case .allProvidersExhausted(let failures):
            let summary = failures.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            return "All available providers exhausted: [\(summary)]"
        }
    }
}

// MARK: - Circuit Breaker

public final class CircuitBreaker: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case closed
        case open(until: Date)
        case halfOpen
    }

    public let failureThreshold: Int
    public let cooldownDuration: TimeInterval
    private(set) public var failureCount: Int = 0
    private(set) public var state: State = .closed
    private let lock = NSLock()

    public init(failureThreshold: Int = 3, cooldownDuration: TimeInterval = 300) {
        self.failureThreshold = failureThreshold
        self.cooldownDuration = cooldownDuration
    }

    public func canAttempt(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .closed:
            return true
        case .open(let until):
            if now >= until {
                state = .halfOpen
                return true
            }
            return false
        case .halfOpen:
            return true
        }
    }

    public func recordSuccess() {
        lock.lock()
        defer { lock.unlock() }
        failureCount = 0
        state = .closed
    }

    public func recordFailure(now: Date = Date(), isFatal: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        failureCount += 1
        if isFatal || failureCount >= failureThreshold {
            state = .open(until: now.addingTimeInterval(cooldownDuration))
        }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        failureCount = 0
        state = .closed
    }
}

// MARK: - Provider Configuration

public struct ProviderConfig: Sendable {
    public enum ResponseType: Sendable {
        case json(keyPath: String? = nil)
        case html
    }

    public let id: String
    public let priority: Int
    public let endpointTemplate: String
    public let requiredHeaders: [String: String]
    public let responseType: ResponseType

    public init(
        id: String,
        priority: Int,
        endpointTemplate: String,
        requiredHeaders: [String: String] = [:],
        responseType: ResponseType = .json()
    ) {
        self.id = id
        self.priority = priority
        self.endpointTemplate = endpointTemplate
        self.requiredHeaders = requiredHeaders
        self.responseType = responseType
    }

    public func makeEndpointURL(for canonical: CanonicalID) -> URL? {
        let str = endpointTemplate
            .replacingOccurrences(of: "{id}", with: canonical.id)
            .replacingOccurrences(of: "{type}", with: canonical.type.rawValue)
            .replacingOccurrences(of: "{season}", with: canonical.season.map(String.init) ?? "1")
            .replacingOccurrences(of: "{episode}", with: canonical.episode.map(String.init) ?? "1")
        return URL(string: str)
    }
}

// MARK: - Parser Helper

public struct StreamManifestParser {
    public static func parseJSON(_ data: Data, keyPath: String? = nil) -> (url: URL, format: StreamFormat)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        if let keyPath = keyPath, let str = extractValue(from: json, keyPath: keyPath) as? String,
           let url = URL(string: str) {
            return (url, detectFormat(from: url))
        }

        if let found = findManifestInJSON(json) {
            return found
        }
        return nil
    }

    private static func extractValue(from json: Any, keyPath: String) -> Any? {
        let parts = keyPath.split(separator: ".").map(String.init)
        var current: Any? = json
        for part in parts {
            if let dict = current as? [String: Any] {
                current = dict[part]
            } else {
                return nil
            }
        }
        return current
    }

    private static func findManifestInJSON(_ object: Any) -> (url: URL, format: StreamFormat)? {
        if let dict = object as? [String: Any] {
            for (_, val) in dict {
                if let found = findManifestInJSON(val) { return found }
            }
        } else if let arr = object as? [Any] {
            for item in arr {
                if let found = findManifestInJSON(item) { return found }
            }
        } else if let str = object as? String, let url = URL(string: str) {
            if str.contains(".m3u8") || str.contains(".mpd") {
                return (url, detectFormat(from: url))
            }
        }
        return nil
    }

    public static func parseHTML(_ html: String, baseURL: URL? = nil) -> (url: URL, format: StreamFormat)? {
        let sourcePattern = #"<source[^>]+src=["']([^"']+\.(m3u8|mpd)[^"']*)["']"#
        if let regex = try? NSRegularExpression(pattern: sourcePattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            let path = String(html[range])
            if let url = URL(string: path, relativeTo: baseURL)?.absoluteURL {
                return (url, detectFormat(from: url))
            }
        }

        let generalPattern = #"(https?:\/\/[^\s"'<>]+\.(m3u8|mpd)(\?[^\s"'<>]*)?)"#
        if let regex = try? NSRegularExpression(pattern: generalPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            let path = String(html[range])
            if let url = URL(string: path) {
                return (url, detectFormat(from: url))
            }
        }

        return nil
    }

    public static func detectFormat(from url: URL) -> StreamFormat {
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" || url.absoluteString.contains(".m3u8") {
            return .hls
        } else if ext == "mpd" || url.absoluteString.contains(".mpd") {
            return .dash
        }
        return .direct
    }
}

// MARK: - Resolution Engine

public actor ProviderResolutionEngine {
    private var providers: [ProviderConfig]
    private var breakers: [String: CircuitBreaker] = [:]
    private let session: URLSession

    public init(
        providers: [ProviderConfig] = [],
        session: URLSession = .shared
    ) {
        self.providers = providers.sorted(by: { $0.priority < $1.priority })
        self.session = session
        for p in providers {
            self.breakers[p.id] = CircuitBreaker()
        }
    }

    public func register(provider: ProviderConfig) {
        providers.removeAll(where: { $0.id == provider.id })
        providers.append(provider)
        providers.sort(by: { $0.priority < $1.priority })
        if breakers[provider.id] == nil {
            breakers[provider.id] = CircuitBreaker()
        }
    }

    public func remove(providerID: String) {
        providers.removeAll(where: { $0.id == providerID })
        breakers.removeValue(forKey: providerID)
    }

    public func circuitBreaker(for providerID: String) -> CircuitBreaker? {
        breakers[providerID]
    }

    public func resolve(canonical: CanonicalID) async throws -> ResolvedStream {
        var failures: [String: String] = [:]

        for provider in providers {
            guard let breaker = breakers[provider.id], breaker.canAttempt() else {
                failures[provider.id] = "Circuit breaker open / skipped"
                continue
            }

            do {
                let resolved = try await resolveSingle(provider: provider, canonical: canonical)
                breaker.recordSuccess()
                return resolved
            } catch {
                let errorMsg = error.localizedDescription
                failures[provider.id] = errorMsg
                let isFatal = (error as? ResolutionError) == .unresolvableHost(provider.id)
                breaker.recordFailure(isFatal: isFatal)
            }
        }

        throw ResolutionError.allProvidersExhausted(failures)
    }

    private func resolveSingle(provider: ProviderConfig, canonical: CanonicalID) async throws -> ResolvedStream {
        guard let url = provider.makeEndpointURL(for: canonical) else {
            throw ResolutionError.invalidEndpointTemplate(provider.endpointTemplate)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4.0
        for (k, v) in provider.requiredHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ResolutionError.requestFailed(statusCode: 0, message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ResolutionError.requestFailed(statusCode: 0, message: "Non-HTTP response received")
        }

        guard (200...299).contains(http.statusCode) else {
            throw ResolutionError.requestFailed(statusCode: http.statusCode, message: "Upstream returned status \(http.statusCode)")
        }

        let candidate: (url: URL, format: StreamFormat)?
        switch provider.responseType {
        case .json(let keyPath):
            candidate = StreamManifestParser.parseJSON(data, keyPath: keyPath)
        case .html:
            let htmlStr = String(decoding: data, as: UTF8.self)
            candidate = StreamManifestParser.parseHTML(htmlStr, baseURL: url)
        }

        guard let parsed = candidate else {
            throw ResolutionError.parseFailed("No valid manifest URL found in payload for provider \(provider.id)")
        }

        try await probeStreamHealth(url: parsed.url, headers: provider.requiredHeaders)

        return ResolvedStream(
            streamURL: parsed.url,
            format: parsed.format,
            headers: provider.requiredHeaders,
            providerID: provider.id
        )
    }

    private func probeStreamHealth(url: URL, headers: [String: String]) async throws {
        // Step 1: HEAD request
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        headRequest.timeoutInterval = 2.5
        for (k, v) in headers {
            headRequest.setValue(v, forHTTPHeaderField: k)
        }

        if let (_, response) = try? await session.data(for: headRequest),
           let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
            return
        }

        // Step 2: Fallback to byte range GET request (bytes 0-512)
        var rangeRequest = URLRequest(url: url)
        rangeRequest.httpMethod = "GET"
        rangeRequest.setValue("bytes=0-512", forHTTPHeaderField: "Range")
        rangeRequest.timeoutInterval = 2.5
        for (k, v) in headers {
            rangeRequest.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: rangeRequest)
        } catch {
            throw ResolutionError.probeFailed("Probe GET request failed: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) || http.statusCode == 206 else {
            throw ResolutionError.probeFailed("Probe returned non-success HTTP status")
        }

        let headerBytes = String(decoding: data.prefix(64), as: UTF8.self)
        if url.absoluteString.contains(".m3u8") && !headerBytes.contains("#EXTM3U") {
            throw ResolutionError.probeFailed("HLS manifest did not begin with #EXTM3U")
        }
        if url.absoluteString.contains(".mpd") && !headerBytes.contains("<MPD") {
            throw ResolutionError.probeFailed("DASH manifest missing <MPD root element")
        }
    }
}
