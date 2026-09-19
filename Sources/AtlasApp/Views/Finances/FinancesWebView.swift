import SwiftUI
import WebKit
import AtlasCore

/// Hosts `finances.html`.
///
/// SECURITY — this page is allowed to call into the app, because what it renders
/// is the user's own bills and spend rather than text a model wrote. What keeps
/// that safe is the shape of the channel, not its absence: the page posts a
/// named action from a fixed set (`FinanceAction.Kind`), anything that does not
/// decode into one is dropped, and everything that does decode is validated
/// again in Swift before a row is written. The page can ask to save a
/// subscription; it cannot ask to run a query.
///
/// Money is the reason the channel is this narrow. Amounts cross as the text the
/// user typed and are parsed once by `Money.minorUnits` on this side, so the
/// page never gets to hand the store a number that a JSON float already rounded.
///
/// Everything else stays locked down: no file access beyond the page itself, no
/// popups, non-persistent storage, and every navigation but the bundled load is
/// cancelled.
struct FinancesWebView: NSViewRepresentable {
    let bridge: FinancesBridge

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // A persistent store keeps serving the previous build's copy of the page,
        // so edits appear to do nothing.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "atlas")

        // Shared tokens and components, injected before the page's own <style>
        // so Finances can still override a shared default.
        config.userContentController.addAtlasSharedStyles()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .atlasAdaptive(light: 0xF0ECE4, dark: 0x06070A)

        // Dev escape hatch: point ATLAS_FINANCES_PAGE at the file in the repo and
        // the page reloads from source, so the HTML can be iterated on without
        // rebuilding the app.
        let override = ProcessInfo.processInfo.environment["ATLAS_FINANCES_PAGE"]
            .map { URL(fileURLWithPath: $0) }
        if let page = override ?? AtlasResources.financesPage {
            webView.loadFileURL(page, allowingReadAccessTo: page)
        } else {
            NSLog("[ATLAS Finances] finances.html NOT FOUND in AtlasCore bundle")
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
        private let bridge: FinancesBridge
        /// Held here so it outlives makeNSView; a watcher nobody retains
        /// is deallocated at once and silently never fires.
        var liveReload: PageLiveReload?

        init(bridge: FinancesBridge) { self.bridge = bridge }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "atlas",
                  let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let action = try? JSONDecoder().decode(FinanceAction.self, from: data)
            else {
                // Anything that is not one of the allowlisted actions never
                // reaches the store.
                NSLog("[ATLAS Finances] dropped an unrecognised message from the page")
                return
            }
            Task { @MainActor in bridge.handle(action) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in bridge.pageDidLoad() }
        }

        /// Only the bundled file may load. Anything else — a link in a note, a
        /// redirect — is refused rather than followed.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .other, navigationAction.request.url?.isFileURL == true {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        /// No popups. Returning nil means `window.open` does nothing at all.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }

    /// Shown when the bundle is missing the page, so the pane says what is wrong
    /// rather than sitting blank.
    private static let missingPage = """
    <!doctype html><meta charset="utf-8">
    <style>body{background:#06070a;color:rgba(255,255,255,.42);
    font:13px -apple-system,BlinkMacSystemFont,sans-serif;display:grid;
    place-items:center;height:100vh;margin:0;text-align:center}</style>
    <div>finances.html is missing from the AtlasCore bundle.<br>Rebuild the app.</div>
    """
}
