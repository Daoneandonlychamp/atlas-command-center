import SwiftUI
import WebKit
import AtlasCore

/// Hosts `calendar.html` — the month, week and day views.
///
/// SECURITY — this page, unlike the Assistant transcript, *is* allowed to call
/// into the app, because the content it renders is the user's own calendar
/// rather than text a language model wrote. What keeps that safe is the shape of
/// the channel, not its absence: the page posts a named action from a fixed set
/// (`CalendarAction`), and anything it sends that does not decode into one is
/// dropped. It can ask to move an event; it cannot ask to run a command.
///
/// Everything else stays locked down: no file access, no universal access, no
/// popups, and every navigation but the bundled load is cancelled.
struct CalendarWebView: NSViewRepresentable {
    let bridge: CalendarBridge

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // A persistent store keeps serving the previous build's copy of the page,
        // so edits appear to do nothing.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "atlas")

        // Shared tokens and components, injected before the page's own
        // <style> so each page can still override a shared default.
        config.userContentController.addAtlasSharedStyles()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        // Matches the page's own ground, so a light interface does not
        // flash black behind the web view while it loads.
        webView.underPageBackgroundColor = .atlasAdaptive(light: 0xF0ECE4, dark: 0x06070A)

        // Dev escape hatch: point ATLAS_CALENDAR_PAGE at the file in the repo and
        // the page reloads from source, so the HTML can be iterated on without
        // rebuilding the app.
        let override = ProcessInfo.processInfo.environment["ATLAS_CALENDAR_PAGE"]
            .map { URL(fileURLWithPath: $0) }
        if let page = override ?? AtlasResources.calendarPage {
            webView.loadFileURL(page, allowingReadAccessTo: page)
        } else {
            NSLog("[ATLAS Calendar] calendar.html NOT FOUND in AtlasCore bundle")
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
        private let bridge: CalendarBridge
        /// Held here so it outlives makeNSView; a watcher nobody retains
        /// is deallocated at once and silently never fires.
        var liveReload: PageLiveReload?

        init(bridge: CalendarBridge) { self.bridge = bridge }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "atlas",
                  let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let action = try? JSONDecoder().decode(CalendarAction.self, from: data)
            else {
                NSLog("[ATLAS Calendar] dropped an unrecognised message from the page")
                return
            }
            DispatchQueue.main.async { self.bridge.handle(action) }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if navigationAction.navigationType == .other, url.isFileURL {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if url.scheme == "http" || url.scheme == "https" { NSWorkspace.shared.open(url) }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            bridge.pageDidLoad()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            NSLog("[ATLAS Calendar] provisional nav failed: %@", error.localizedDescription)
        }
    }

    static let missingPage = """
    <body style="background:#06070a;color:#ff3b30;font:12px -apple-system;padding:24px">
    Calendar page not found — calendar.html did not ship with AtlasCore resources.
    </body>
    """
}

/// Everything the page is allowed to ask for.
///
/// Decoding is the allowlist: a message that is not one of these `action` values
/// fails to decode and is dropped, so the set of things the page can do is fixed
/// here rather than trusted from the page.
struct CalendarAction: Decodable {
    enum Kind: String, Decodable {
        case range, create, update, delete
        case completeReminder, uncompleteReminder, deleteReminder
        case quickAdd, newReminder, openJournal
    }

    let action: Kind
    let id: String?
    let start: Date?
    let end: Date?
    let title: String?
    let location: String?
    let notes: String?
    let calendarId: String?
    let text: String?

    private enum CodingKeys: String, CodingKey {
        case action, id, start, end, title, location, notes, calendarId, text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(Kind.self, forKey: .action)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        calendarId = try container.decodeIfPresent(String.self, forKey: .calendarId)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        start = try container.decodeIfPresent(String.self, forKey: .start).flatMap(Self.parse)
        end = try container.decodeIfPresent(String.self, forKey: .end).flatMap(Self.parse)
    }

    /// The page sends `toISOString()`, which always carries milliseconds.
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parse(_ value: String) -> Date? {
        iso.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
