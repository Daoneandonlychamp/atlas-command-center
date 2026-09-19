import Foundation

/// Finding a film on the Internet Archive.
///
/// `ProviderResolutionEngine` resolves a *known* id through a URL template. The
/// Archive has no TMDB ids, so a film can only be reached by searching for its
/// name, judging the hits, and then reading the chosen item's file list. That
/// search-and-match step is what this adds, and it is the reason the engine sat
/// unused: there was never an id to hand it.
///
/// The network work lives here rather than in cinema.html so a stream can be
/// resolved without the page, and so failures are typed instead of being a
/// rejected promise inside a 3,700-line document.
public actor ArchiveSearchProvider {

    public struct Hit: Equatable, Sendable, Codable {
        public let identifier: String
        public let title: String
        public let streamURL: URL

        public init(identifier: String, title: String, streamURL: URL) {
            self.identifier = identifier
            self.title = title
            self.streamURL = streamURL
        }
    }

    public static let providerID = "archive.org"

    private let session: URLSession
    private let breaker: CircuitBreaker
    /// Resolutions already made this launch, including the misses. A miss is worth
    /// remembering: without it, every re-open of a film the Archive does not carry
    /// pays for the same two round trips again.
    private var memo: [String: Hit?] = [:]

    public init(session: URLSession = .shared, breaker: CircuitBreaker = CircuitBreaker()) {
        self.session = session
        self.breaker = breaker
    }

    /// The playable file for `title`, or nil when the Archive does not carry it.
    ///
    /// - Parameters:
    ///   - title: the work's name as TMDB gives it
    ///   - year: release year, used only to narrow the search
    ///   - key: cache identity, normally `"movie:<tmdbID>"`
    public func find(title: String, year: String?, key: String) async throws -> Hit? {
        if let remembered = memo[key] { return remembered }

        guard breaker.canAttempt() else {
            throw ResolutionError.requestFailed(
                statusCode: 0,
                message: "Archive requests are paused after repeated failures"
            )
        }

        do {
            let hit = try await search(title: title, year: year)
            breaker.recordSuccess()
            memo[key] = hit
            return hit
        } catch {
            breaker.recordFailure()
            throw error
        }
    }

    /// Drops the remembered answer for one title, so a fresh look is taken.
    public func forget(key: String) { memo[key] = nil }

    // MARK: - Search

    private func search(title: String, year: String?) async throws -> Hit? {
        // Quotes and backslashes would break out of the quoted term in the
        // Archive's query language, so they are spaces before they get there.
        let cleaned = title
            .replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: "\\", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var query = "title:(\"\(cleaned)\") AND mediatype:(movies) AND format:(MPEG4)"
        if let year, !year.isEmpty { query += " AND year:(\(year))" }

        var components = URLComponents(string: "https://archive.org/advancedsearch.php")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "fl[]", value: "title"),
            URLQueryItem(name: "fl[]", value: "year"),
            URLQueryItem(name: "rows", value: "8"),
            URLQueryItem(name: "output", value: "json"),
        ]
        guard let url = components?.url else {
            throw ResolutionError.invalidEndpointTemplate("archive advancedsearch")
        }

        let docs = try await fetchDocs(url)

        for doc in docs {
            guard TitleMatcher.matches(wanted: cleaned, candidate: doc.title) else { continue }
            guard let file = try await firstPlayableFile(identifier: doc.identifier) else { continue }
            guard let streamURL = downloadURL(identifier: doc.identifier, file: file) else { continue }
            return Hit(identifier: doc.identifier, title: doc.title, streamURL: streamURL)
        }
        return nil
    }

    private struct Doc { let identifier: String; let title: String }

    private func fetchDocs(_ url: URL) async throws -> [Doc] {
        let data = try await get(url, label: "Archive search")
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let response = root["response"] as? [String: Any],
            let raw = response["docs"] as? [[String: Any]]
        else { throw ResolutionError.parseFailed("Archive search returned no docs array") }

        return raw.compactMap { doc in
            guard let identifier = doc["identifier"] as? String else { return nil }
            // The Archive sometimes returns title as an array of alternates.
            let title = (doc["title"] as? String)
                ?? (doc["title"] as? [String])?.first
                ?? identifier
            return Doc(identifier: identifier, title: title)
        }
    }

    /// The first MP4 in an item, or nil if it holds none.
    private func firstPlayableFile(identifier: String) async throws -> String? {
        guard let url = URL(string: "https://archive.org/metadata/\(identifier)") else { return nil }
        let data = try await get(url, label: "Archive metadata")
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = root["files"] as? [[String: Any]]
        else { return nil }

        return files.compactMap { $0["name"] as? String }.first { name in
            let lower = name.lowercased()
            return lower.hasSuffix(".mp4") || lower.hasSuffix(".m4v")
        }
    }

    private func downloadURL(identifier: String, file: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "archive.org"
        // Set as a path rather than interpolated, so the file name is escaped once
        // and correctly — Archive file names carry spaces and brackets.
        components.path = "/download/\(identifier)/\(file)"
        return components.url
    }

    private func get(_ url: URL, label: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ResolutionError.requestFailed(statusCode: 0, message: "\(label): \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ResolutionError.requestFailed(statusCode: 0, message: "\(label): no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ResolutionError.requestFailed(statusCode: http.statusCode, message: label)
        }
        return data
    }
}
