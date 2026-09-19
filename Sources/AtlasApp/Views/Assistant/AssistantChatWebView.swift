import SwiftUI
import WebKit
import AtlasCore

/// Hosts the Assistant transcript page (`chat.html`) so model output renders as
/// real markdown — headings, fenced code with copy buttons, tables — instead of
/// the flat `Text` the transcript used before.
///
/// SECURITY — this view renders text written by a language model, including
/// uncensored ones, so its web view is deliberately weaker than `HUDView`'s:
///
///   * No `allowFileAccessFromFileURLs` / `allowUniversalAccessFromFileURLs`.
///     HUDView sets both so its bundled three.js modules load; granting them
///     here would let injected script read the user's files.
///   * No script message handler. The page has no channel into native code.
///   * No `WKUIDelegate` dialog methods, so a stray `alert()` cannot wedge the
///     app; `createWebViewWith` returns nil, so nothing can open a popup.
///   * Every navigation other than the initial file:// load is cancelled and
///     handed to the real browser, so a link can never replace the transcript.
///
/// The page's own defences (escapeHtml on every model byte, a CSP that denies
/// all network destinations) live in `chat.html`. Renderer tests are in
/// `Tests/chat_render_test.js` — run them after editing that file.
struct AssistantChatWebView: NSViewRepresentable {
    let bridge: AssistantChatBridge

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Same reason as the HUD: a persistent store keeps serving the previous
        // build's copy of the page after an update, so edits appear to do nothing.
        config.websiteDataStore = .nonPersistent()

        // The shared markdown renderer, injected before the page's own script
        // runs. A file:// page cannot reliably load a sibling script under this
        // CSP, so injecting it keeps the page's file access at nothing.
        if let markdown = AtlasResources.markdownScript {
            config.userContentController.addUserScript(
                WKUserScript(source: markdown, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }

        // Shared tokens and components, injected before the page's own
        // <style> so each page can still override a shared default.
        config.userContentController.addAtlasSharedStyles()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // let the page's own background show
        // Matches the page's own ground, so a light interface does not
        // flash black behind the web view while it loads.
        webView.underPageBackgroundColor = .atlasAdaptive(light: 0xF0ECE4, dark: 0x06070A)

        // Dev escape hatch, matching every other surface: point ATLAS_CHAT_PAGE
        // at the file in the repo and edits show up without a rebuild.
        let override = ProcessInfo.processInfo.environment["ATLAS_CHAT_PAGE"]
            .map { URL(fileURLWithPath: $0) }
        if let page = override ?? AtlasResources.chatPage {
            // Read access is scoped to the page itself: it loads no sibling
            // files, because the renderer is injected rather than fetched.
            webView.loadFileURL(page, allowingReadAccessTo: page)
        } else {
            NSLog("[ATLAS Chat] chat.html NOT FOUND in AtlasCore bundle")
            webView.loadHTMLString(Self.missingPage, baseURL: nil)
        }

        // Development only: nil unless ATLAS_CHAT_PAGE points at the repo copy.
        context.coordinator.liveReload = PageLiveReload.watch(override, reloading: webView)

        bridge.attach(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let bridge: AssistantChatBridge
        /// Held here so it outlives makeNSView; a watcher nobody retains
        /// is deallocated at once and silently never fires.
        var liveReload: PageLiveReload?

        init(bridge: AssistantChatBridge) { self.bridge = bridge }

        /// Only ATLAS's own page may load in this web view. A link the model
        /// wrote opens in the user's browser, where it is the browser's problem.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.navigationType == .other, url.isFileURL {
                decisionHandler(.allow) // the initial bundled load
                return
            }
            decisionHandler(.cancel)
            // Anything that is not plain web browsing (file://, custom schemes a
            // handler might act on) is dropped rather than handed to the system.
            if url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
            } else {
                NSLog("[ATLAS Chat] blocked navigation to %@", url.absoluteString)
            }
        }

        /// No popups. Returning nil means `window.open` does nothing at all.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url,
               url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            bridge.pageDidLoad()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            NSLog("[ATLAS Chat] provisional nav failed: %@", error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[ATLAS Chat] nav failed: %@", error.localizedDescription)
        }
    }

    /// Shown only if the bundled page is missing, so a packaging mistake is
    /// visible instead of a silent black rectangle.
    static let missingPage = """
    <body style="background:#06070a;color:#ff3b30;font:12px -apple-system;padding:24px">
    Assistant transcript page not found — chat.html did not ship with AtlasCore resources.
    </body>
    """
}

/// Holds the web view so the transcript can be pushed into a page that outlives
/// any single SwiftUI body evaluation, and queues writes made before it loads.
final class AssistantChatBridge {
    private weak var webView: WKWebView?
    private var pageIsReady = false
    /// Calls made before the page finished loading, replayed in order.
    private var pending: [(function: String, json: String)] = []
    /// What the page currently shows, so `sync` only sends real changes.
    private var sent: [String: String] = [:]
    private var sentIDs: [String] = []

    fileprivate func attach(_ webView: WKWebView) {
        self.webView = webView
        // A new web view means a fresh page: anything already sent is gone.
        pageIsReady = false
        sent = [:]
        sentIDs = []
    }

    /// Replaces the whole transcript. Used once when the view appears.
    func setAll(_ messages: [ChatMessage], streamingID: String? = nil) {
        let payload = messages.map { ChatPayload($0, streaming: $0.id == streamingID) }
        sentIDs = messages.map(\.id)
        sent = Dictionary(uniqueKeysWithValues: payload.map { ($0.id, encode($0) ?? "") })
        send("setAll", encode(payload))
    }

    /// Pushes whatever actually changed.
    ///
    /// Streaming calls this on every token, so it must not rebuild the page: as
    /// long as the transcript only grew at the end, each changed message is
    /// patched in place. Anything else — loading another conversation, clearing,
    /// deleting — is a full replace.
    func sync(_ messages: [ChatMessage], streamingID: String? = nil) {
        guard messages.map(\.id).starts(with: sentIDs) else {
            setAll(messages, streamingID: streamingID)
            return
        }
        sentIDs = messages.map(\.id)
        for message in messages {
            let payload = ChatPayload(message, streaming: message.id == streamingID)
            guard let json = encode(payload), sent[message.id] != json else { continue }
            sent[message.id] = json
            send("update", json)
        }
    }

    /// Updates one message in place, appending it if the page has not seen it.
    /// Streaming updates land here, so the page can patch a single node rather
    /// than rebuild the transcript on every token.
    func update(_ message: ChatMessage, streaming: Bool = false) {
        send("update", encode(ChatPayload(message, streaming: streaming)))
    }

    private func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else {
            NSLog("[ATLAS Chat] failed to encode transcript payload")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func send(_ function: String, _ json: String?) {
        guard let json else { return }
        guard let webView, pageIsReady else {
            pending.append((function, json))
            return
        }
        // The JSON travels as a bound argument, never interpolated into the
        // script text, so no amount of quoting in model output can break out.
        webView.callAsyncJavaScript(
            "window.atlasChat.\(function)(json)",
            arguments: ["json": json],
            in: nil,
            in: .page
        ) { result in
            if case .failure(let error) = result {
                NSLog("[ATLAS Chat] %@ failed: %@", function, error.localizedDescription)
            }
        }
    }

    fileprivate func pageDidLoad() {
        pageIsReady = true
        let queued = pending
        pending = []
        for call in queued { send(call.function, call.json) }
    }
}

/// The shape `chat.html` expects. Kept separate from `ChatMessage` so the page
/// contract is explicit and the model stays free of view concerns.
private struct ChatPayload: Encodable {
    // `id` is also the diffing key in AssistantChatBridge.sync.
    let id: String
    let role: String
    let subtitle: String
    let text: String
    let streaming: Bool
    let files: [String]
    let reasoning: String
    let error: String?

    init(_ message: ChatMessage, streaming: Bool) {
        self.id = message.id
        self.role = message.role.rawValue
        self.subtitle = message.executionLocation.rawValue
        self.text = message.text
        self.streaming = streaming
        self.files = message.touchedFiles
        self.reasoning = message.reasoning
        self.error = nil
    }
}
