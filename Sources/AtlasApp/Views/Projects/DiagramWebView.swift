import SwiftUI
import WebKit

/// Hosts an archify diagram, which is a self-contained HTML page with its SVG,
/// styles and script inlined.
///
/// Read access is granted to the file itself rather than its folder: the page
/// pulls in nothing from beside it, and the folder is inside the user's vault.
struct DiagramWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Nothing here needs to persist, and the diagram shares no state with
        // the rest of the app.
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.loadFileURL(url, allowingReadAccessTo: url)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // The detail pane is reused as the user moves between projects, so the view
        // is handed a new URL rather than rebuilt. Reload only on a real change,
        // otherwise every SwiftUI update restarts the diagram.
        if context.coordinator.loaded != url {
            context.coordinator.loaded = url
            webView.loadFileURL(url, allowingReadAccessTo: url)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: URL

        init(url: URL) { self.loaded = url }

        /// A diagram may link out to docs; those belong in the browser, not in a
        /// panel with no way back.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.allow); return
            }
            if navigationAction.navigationType == .linkActivated,
               target.scheme == "http" || target.scheme == "https" {
                NSWorkspace.shared.open(target)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
