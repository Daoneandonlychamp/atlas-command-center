import SwiftUI
import WebKit
import AppKit
import AtlasCore

struct CinemaWebView: NSViewRepresentable {
    let bridge: CinemaBridge

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.websiteDataStore = .default()
        config.allowsAirPlayForMediaPlayback = true
        // Off by default in WKWebView, which leaves the player's fullscreen button
        // present and inert — it calls requestFullscreen() and nothing happens.
        config.preferences.isElementFullscreenEnabled = true

        config.userContentController.add(context.coordinator, name: "atlasBridge")

        // The key has to exist before the page's own script runs: cinema.html boots
        // with `switchTab('home')` at parse time, which reaches TMDB immediately.
        // Handing it over in the state message is too late — that arrives on
        // navigation-finish, by which point the first request has already 401'd.
        if let key = CinemaBridge.tmdbKey(), !key.isEmpty,
           let encoded = try? JSONSerialization.data(withJSONObject: [key]),
           let literal = String(data: encoded, encoding: .utf8) {
            // Passed as a one-element JSON array so the value is escaped by the
            // serialiser rather than spliced into source as a bare string.
            let source = "window.__ATLAS_TMDB_KEY__ = \(literal)[0];"
            config.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .black

        let override = ProcessInfo.processInfo.environment["ATLAS_CINEMA_PAGE"]
            .map { URL(fileURLWithPath: $0) }
        if let page = override ?? AtlasResources.cinemaPage {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            NSLog("[ATLAS Cinema] cinema.html NOT FOUND in AtlasCore bundle")
            webView.loadHTMLString(Self.missingPage, baseURL: nil)
        }

        // Development only: `override` is nil unless the ATLAS_*_PAGE variable
        // points at the repo copy, so a normal launch watches nothing.
        context.coordinator.liveReload = PageLiveReload.watch(override, reloading: webView)

        bridge.attach(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private let bridge: CinemaBridge
        /// Held here so it outlives makeNSView; a watcher nobody retains
        /// is deallocated at once and silently never fires.
        var liveReload: PageLiveReload?

        init(bridge: CinemaBridge) { self.bridge = bridge }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "atlasBridge", let dict = message.body as? [String: Any] {
                bridge.handleMessage(dict)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            bridge.pageDidLoad()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               url.host?.contains("youtube.com") == true,
               url.path == "/watch" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    static let missingPage = """
    <body style="background:#06070a;color:#ff3b30;font:13px -apple-system;padding:24px">
    Cinema page not found — cinema.html did not ship with AtlasCore resources.
    </body>
    """
}
