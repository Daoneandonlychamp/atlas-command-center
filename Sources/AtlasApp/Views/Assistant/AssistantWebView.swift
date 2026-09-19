import SwiftUI
import WebKit
import AtlasCore

/// Hosts `assistant.html` — the whole Assistant page, not just its transcript.
///
/// SECURITY — this is the most exposed page in the app. It renders text written
/// by an uncensored model with no tools and no approval step, and that text is
/// untrusted input in the strictest sense: it is chosen by a system that will
/// say anything, including a string crafted to break out of a page.
///
/// Three things hold the line, and all three matter:
///
/// 1. **The page never sees raw model bytes as markup.** Everything goes through
///    `escapeHtml` or `textContent` in `assistant.html`.
/// 2. **Payloads cross as bound arguments**, never spliced into script text, so
///    no amount of quoting in a reply can reach the interpreter.
/// 3. **The page can only ask for what `AssistantActionKind` names.** It can ask
///    for a reply; it cannot ask to read a file or run a command.
///
/// Everything else stays shut: no file access beyond the page itself, no popups,
/// non-persistent storage, and every navigation but the initial load cancelled —
/// a model that emits a link cannot make the view follow it.
struct AssistantWebView: NSViewRepresentable {
    let bridge: AssistantBridge
    /// The menu-bar window loads the same page and strips the chrome, so there
    /// is one renderer rather than two that drift apart.
    var compact: Bool = false

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // A persistent store keeps serving the previous build's copy of the page.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "atlas")

        // Markdown rendering, injected rather than fetched: the page runs from
        // file:// under a CSP with no 'self', so a sibling script cannot load.
        if let markdown = AtlasResources.markdownScript {
            config.userContentController.addUserScript(
                WKUserScript(source: markdown, injectionTime: .atDocumentStart,
                             forMainFrameOnly: true))
        }
        config.userContentController.addAtlasSharedStyles()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .atlasAdaptive(light: 0xF0ECE4, dark: 0x06070A)

        context.coordinator.compact = compact

        // Dev escape hatch: point ATLAS_ASSISTANT_PAGE at the file in the repo
        // and edits show up without a rebuild.
        let override = ProcessInfo.processInfo.environment["ATLAS_ASSISTANT_PAGE"]
            .map { URL(fileURLWithPath: $0) }
        if let page = override ?? AtlasResources.assistantPage {
            webView.loadFileURL(page, allowingReadAccessTo: page)
        } else {
            NSLog("[ATLAS Assistant] assistant.html NOT FOUND in AtlasCore bundle")
            webView.loadHTMLString(Self.missingPage, baseURL: nil)
        }

        context.coordinator.liveReload = PageLiveReload.watch(override, reloading: webView)

        bridge.attach(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private let bridge: AssistantBridge
        var compact = false
        /// Held here so it outlives makeNSView; a watcher nobody retains
        /// is deallocated at once and silently never fires.
        var liveReload: PageLiveReload?

        init(bridge: AssistantBridge) { self.bridge = bridge }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "atlas",
                  let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let action = try? JSONDecoder().decode(AssistantAction.self, from: data)
            else {
                // Anything outside the allowlist never reaches a session.
                NSLog("[ATLAS Assistant] dropped an unrecognised message from the page")
                return
            }
            Task { @MainActor in bridge.handle(action) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if compact {
                webView.evaluateJavaScript(
                    "window.atlasAssistant && window.atlasAssistant.compact()")
            }
            Task { @MainActor in bridge.pageDidLoad() }
        }

        /// Only the initial file load may proceed. A model that emits a link
        /// cannot make this view follow it.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .other,
               navigationAction.request.url?.isFileURL == true {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        /// No popups. Returning nil means `window.open` does nothing at all.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[ATLAS Assistant] nav failed: %@", error.localizedDescription)
        }
    }

    /// Shown when the bundle is missing the page, so a packaging mistake is
    /// visible rather than a silent black rectangle.
    private static let missingPage = """
    <!doctype html><meta charset="utf-8">
    <style>body{background:#06070a;color:rgba(255,255,255,.42);
    font:13px -apple-system,BlinkMacSystemFont,sans-serif;display:grid;
    place-items:center;height:100vh;margin:0;text-align:center}</style>
    <div>assistant.html is missing from the AtlasCore bundle.<br>Rebuild the app.</div>
    """
}
