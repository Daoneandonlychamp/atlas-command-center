import XCTest
@testable import AtlasCore

// MARK: - Mock URL Protocol for Network Simulation

final class MockURLProtocol: URLProtocol {
    static var requestHandlers: [URL: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]
    static var lastHeaders: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lastHeaders = request.allHTTPHeaderFields ?? [:]

        // Check if there is an exact or prefix handler
        let handler = Self.requestHandlers[url] ?? Self.requestHandlers.first(where: { url.absoluteString.hasPrefix($0.key.absoluteString) })?.value

        guard let handler else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Unit Tests

final class ProviderResolutionEngineTests: XCTestCase {

    var session: URLSession!

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandlers = [:]
        MockURLProtocol.lastHeaders = [:]

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.requestHandlers = [:]
        MockURLProtocol.lastHeaders = [:]
        session = nil
        super.tearDown()
    }

    // MARK: - Template & Formatting

    func testCanonicalEndpointInterpolation() {
        let canonical = CanonicalID(id: "12345", type: .tv, season: 2, episode: 4)
        let config = ProviderConfig(
            id: "test",
            priority: 1,
            endpointTemplate: "https://api.example.com/{type}/{id}/{season}/{episode}"
        )
        let url = config.makeEndpointURL(for: canonical)
        XCTAssertEqual(url?.absoluteString, "https://api.example.com/tv/12345/2/4")
    }

    func testManifestFormatDetection() {
        let hlsURL = URL(string: "https://cdn.example.com/live/master.m3u8?token=xyz")!
        let dashURL = URL(string: "https://cdn.example.com/vod/manifest.mpd")!
        let directURL = URL(string: "https://cdn.example.com/file.mp4")!

        XCTAssertEqual(StreamManifestParser.detectFormat(from: hlsURL), .hls)
        XCTAssertEqual(StreamManifestParser.detectFormat(from: dashURL), .dash)
        XCTAssertEqual(StreamManifestParser.detectFormat(from: directURL), .direct)
    }

    // MARK: - Parsers

    func testJSONParsingWithKeyPath() {
        let json = """
        {
            "status": "ok",
            "data": {
                "playback": "https://stream.example.com/playlist.m3u8"
            }
        }
        """.data(using: .utf8)!

        let parsed = StreamManifestParser.parseJSON(json, keyPath: "data.playback")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.url.absoluteString, "https://stream.example.com/playlist.m3u8")
        XCTAssertEqual(parsed?.format, .hls)
    }

    func testJSONParsingRecursiveSearch() {
        let json = """
        {
            "result": {
                "items": [
                    { "type": "meta" },
                    { "source": "https://stream.example.com/video.mpd" }
                ]
            }
        }
        """.data(using: .utf8)!

        let parsed = StreamManifestParser.parseJSON(json)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.url.absoluteString, "https://stream.example.com/video.mpd")
        XCTAssertEqual(parsed?.format, .dash)
    }

    func testHTMLSourceTagParsing() {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <video controls>
                <source src="https://media.example.com/stream/index.m3u8" type="application/x-mpegURL">
            </video>
        </body>
        </html>
        """

        let parsed = StreamManifestParser.parseHTML(html)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.url.absoluteString, "https://media.example.com/stream/index.m3u8")
        XCTAssertEqual(parsed?.format, .hls)
    }

    func testHTMLInlineScriptParsing() {
        let html = """
        <script>
            var playerConfig = { file: "https://secure.example.com/manifest.mpd?auth=123" };
        </script>
        """

        let parsed = StreamManifestParser.parseHTML(html)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.url.absoluteString, "https://secure.example.com/manifest.mpd?auth=123")
        XCTAssertEqual(parsed?.format, .dash)
    }

    // MARK: - Circuit Breaker

    func testCircuitBreakerTripsAndRecovers() {
        let breaker = CircuitBreaker(failureThreshold: 2, cooldownDuration: 10)
        let now = Date()

        XCTAssertTrue(breaker.canAttempt(now: now))
        XCTAssertEqual(breaker.state, .closed)

        // 1st failure: remains closed
        breaker.recordFailure(now: now)
        XCTAssertTrue(breaker.canAttempt(now: now))
        XCTAssertEqual(breaker.state, .closed)

        // 2nd failure: trips open
        breaker.recordFailure(now: now)
        XCTAssertFalse(breaker.canAttempt(now: now))
        if case .open = breaker.state {
            // expected
        } else {
            XCTFail("Circuit breaker expected to be in open state")
        }

        // Before cooldown: still blocked
        XCTAssertFalse(breaker.canAttempt(now: now.addingTimeInterval(5)))

        // After cooldown: moves to half-open
        XCTAssertTrue(breaker.canAttempt(now: now.addingTimeInterval(11)))
        XCTAssertEqual(breaker.state, .halfOpen)

        // Success resets to closed
        breaker.recordSuccess()
        XCTAssertEqual(breaker.state, .closed)
        XCTAssertEqual(breaker.failureCount, 0)
    }

    // MARK: - End-to-End Engine Resolution

    func testEngineResolvesSuccessfullyWithHeadersAndProbe() async throws {
        let endpointURL = URL(string: "https://api.source.test/movie/999/1/1")!
        let manifestURL = URL(string: "https://cdn.source.test/stream.m3u8")!

        // Mock API endpoint returning JSON
        MockURLProtocol.requestHandlers[endpointURL] = { request in
            let body = #"{"stream_url": "https://cdn.source.test/stream.m3u8"}"#.data(using: .utf8)!
            let res = HTTPURLResponse(url: endpointURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (res, body)
        }

        // Mock probe HEAD request
        MockURLProtocol.requestHandlers[manifestURL] = { request in
            let res = HTTPURLResponse(url: manifestURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "application/vnd.apple.mpegurl"
            ])!
            return (res, Data())
        }

        let provider = ProviderConfig(
            id: "source-a",
            priority: 1,
            endpointTemplate: "https://api.source.test/{type}/{id}/{season}/{episode}",
            requiredHeaders: [
                "User-Agent": "ATLAS-Cinema/1.0",
                "Referer": "https://api.source.test"
            ],
            responseType: .json(keyPath: "stream_url")
        )

        let engine = ProviderResolutionEngine(providers: [provider], session: session)
        let canonical = CanonicalID(id: "999", type: .movie)

        let resolved = try await engine.resolve(canonical: canonical)

        XCTAssertEqual(resolved.streamURL, manifestURL)
        XCTAssertEqual(resolved.format, .hls)
        XCTAssertEqual(resolved.providerID, "source-a")
        XCTAssertEqual(resolved.headers["User-Agent"], "ATLAS-Cinema/1.0")
        XCTAssertEqual(resolved.headers["Referer"], "https://api.source.test")
    }

    func testEngineFailsOverToSecondaryProviderWhenPrimaryFails() async throws {
        let primaryEndpoint = URL(string: "https://primary.test/movie/100/1/1")!
        let secondaryEndpoint = URL(string: "https://secondary.test/movie/100/1/1")!
        let secondaryManifest = URL(string: "https://cdn.secondary.test/live.m3u8")!

        // Primary fails with 500
        MockURLProtocol.requestHandlers[primaryEndpoint] = { _ in
            let res = HTTPURLResponse(url: primaryEndpoint, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (res, Data())
        }

        // Secondary succeeds with HTML
        MockURLProtocol.requestHandlers[secondaryEndpoint] = { _ in
            let html = #"<source src="https://cdn.secondary.test/live.m3u8">"#
            let res = HTTPURLResponse(url: secondaryEndpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (res, html.data(using: .utf8)!)
        }

        // Secondary probe succeeds
        MockURLProtocol.requestHandlers[secondaryManifest] = { _ in
            let res = HTTPURLResponse(url: secondaryManifest, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (res, Data())
        }

        let p1 = ProviderConfig(id: "p1", priority: 1, endpointTemplate: "https://primary.test/{type}/{id}/{season}/{episode}")
        let p2 = ProviderConfig(id: "p2", priority: 2, endpointTemplate: "https://secondary.test/{type}/{id}/{season}/{episode}", responseType: .html)

        let engine = ProviderResolutionEngine(providers: [p1, p2], session: session)
        let resolved = try await engine.resolve(canonical: CanonicalID(id: "100", type: .movie))

        XCTAssertEqual(resolved.providerID, "p2")
        XCTAssertEqual(resolved.streamURL, secondaryManifest)

        // Verify p1 circuit breaker registered a failure
        let p1Breaker = await engine.circuitBreaker(for: "p1")
        XCTAssertEqual(p1Breaker?.failureCount, 1)
    }

    func testEngineThrowsWhenAllProvidersExhausted() async {
        let p1 = ProviderConfig(id: "p1", priority: 1, endpointTemplate: "https://dead1.test/{id}")
        let p2 = ProviderConfig(id: "p2", priority: 2, endpointTemplate: "https://dead2.test/{id}")

        let engine = ProviderResolutionEngine(providers: [p1, p2], session: session)

        do {
            _ = try await engine.resolve(canonical: CanonicalID(id: "999", type: .movie))
            XCTFail("Expected allProvidersExhausted error")
        } catch let ResolutionError.allProvidersExhausted(failures) {
            XCTAssertEqual(failures.count, 2)
            XCTAssertTrue(failures.keys.contains("p1"))
            XCTAssertTrue(failures.keys.contains("p2"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
