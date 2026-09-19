import SwiftUI
import WebKit
import ImageIO
import UniformTypeIdentifiers
import AtlasCore

/// The canvas: an infinite pan-and-zoom surface over JSON Canvas files.
///
/// The format is the one Obsidian Canvas writes, so this opens the `.canvas`
/// files already in the vaults and anything drawn here opens in Obsidian. That
/// interoperability is the reason the feature is worth building at all — a
/// private canvas format would just be another silo.
struct CanvasView: View {
    @EnvironmentObject var appState: AtlasAppState
    @State private var bridge = CanvasBridge()

    var body: some View {
        CanvasWebView(bridge: bridge)
            .background(AtlasTheme.Colors.background)
            .onAppear { bridge.vaults = appState.vaults.map { URL(fileURLWithPath: $0.path) } }
    }
}

struct CanvasWebView: NSViewRepresentable {
    let bridge: CanvasBridge

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .nonPersistent()

        // The shared markdown renderer, injected before the page's own script
        // runs. A file:// page cannot reliably load a sibling script under this
        // CSP, so injecting it keeps the page's file access at nothing.
        if let markdown = AtlasResources.markdownScript {
            config.userContentController.addUserScript(
                WKUserScript(source: markdown, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
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

        let override = ProcessInfo.processInfo.environment["ATLAS_CANVAS_PAGE"]
            .map { URL(fileURLWithPath: $0) }
        if let page = override ?? AtlasResources.canvasPage {
            // Scoped to the page itself. Vault files are never readable here —
            // previews come from the app as data URIs.
            webView.loadFileURL(page, allowingReadAccessTo: page)
        } else {
            NSLog("[ATLAS Canvas] canvas.html NOT FOUND in AtlasCore bundle")
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
        private let bridge: CanvasBridge
        /// Held here so it outlives makeNSView; a watcher nobody retains
        /// is deallocated at once and silently never fires.
        var liveReload: PageLiveReload?

        init(bridge: CanvasBridge) { self.bridge = bridge }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "atlas",
                  let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = object["action"] as? String,
                  let action = CanvasAction(rawValue: name)
            else {
                NSLog("[ATLAS Canvas] dropped an unrecognised message from the page")
                return
            }
            DispatchQueue.main.async { self.bridge.handle(action, object) }
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
    }
}

/// What the canvas page may ask for. The raw string is matched against this set
/// and anything else is dropped, so the page can ask but never command.
enum CanvasAction: String {
    case list, load, save, create, openExternal, openFile, thumbnail, jserror
}

/// Between `canvas.html` and the `.canvas` files on disk.
@MainActor
final class CanvasBridge {
    private weak var webView: WKWebView?
    private var pageIsReady = false
    private var pending: [(script: String, json: String)] = []

    private let store = CanvasStore.shared
    /// Vault roots to search, handed in by the view.
    var vaults: [URL] = []
    /// When the open canvas was last written, as ATLAS saw it. Auto-save refuses
    /// to write over a file that changed underneath — Obsidian may have the same
    /// canvas open, and silently winning that race would lose its edits.
    private var lastKnownWrite: Date?

    func attach(_ webView: WKWebView) {
        self.webView = webView
        pageIsReady = false
    }

    func pageDidLoad() {
        pageIsReady = true
        let queued = pending
        pending = []
        for call in queued { push(raw: call.script, json: call.json) }
    }

    func handle(_ action: CanvasAction, _ payload: [String: Any]) {
        switch action {
        case .list:
            listCanvases()

        case .load:
            guard let path = payload["path"] as? String else { return }
            load(URL(fileURLWithPath: path))

        case .save:
            guard let path = payload["path"] as? String,
                  let nodes = payload["nodes"] as? [[String: Any]],
                  let edges = payload["edges"] as? [[String: Any]]
            else { return }
            save(URL(fileURLWithPath: path), nodes: nodes, edges: edges)

        case .create:
            guard let name = payload["name"] as? String else { return }
            create(named: name)

        case .openExternal:
            // A link node, or a path — whichever the page sent.
            if let link = payload["url"] as? String, let url = URL(string: link),
               url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
            } else if let path = payload["path"] as? String {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }

        case .openFile:
            // Resolved against the vault the same way previews are, so a file
            // node opens the thing it is actually pointing at.
            guard let canvasPath = payload["path"] as? String,
                  let file = payload["file"] as? String,
                  let url = Self.resolve(file, from: URL(fileURLWithPath: canvasPath))
            else {
                notify("That file is not where the canvas says it is.", bad: true)
                return
            }
            NSWorkspace.shared.open(url)

        case .jserror:
            // The page telling us why it is inert, which beats guessing.
            NSLog("[ATLAS Canvas] page: %@", (payload["text"] as? String) ?? "?")

        case .thumbnail:
            guard let canvasPath = payload["path"] as? String,
                  let file = payload["file"] as? String else { return }
            preview(file: file, canvas: URL(fileURLWithPath: canvasPath))
        }
    }

    private func listCanvases() {
        let files = store.list(vaults: vaults)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let payload = files.map { file -> [String: Any] in
            // A readable location rather than a 90-character absolute path.
            let where_ = file.url.deletingLastPathComponent().path
                .replacingOccurrences(of: home, with: "~")
            return ["path": file.url.path, "name": file.name, "where": where_]
        }
        push("listed", encode(payload))
        NSLog("[ATLAS Canvas] %d canvases found", files.count)
    }

    private func load(_ url: URL) {
        do {
            let document = try store.load(url)
            lastKnownWrite = Self.modified(url)
            var payload = document.raw
            payload["path"] = url.path
            payload["name"] = document.name
            push("loaded", encode(payload))
        } catch {
            notify("Could not open that canvas: \(error.localizedDescription)", bad: true)
        }
    }

    /// Writes back only what the page owns.
    ///
    /// The document is re-read from disk first so every key ATLAS does not
    /// understand — Obsidian's `metadata`, anything a later version adds — is
    /// carried through instead of being replaced by what the page happens to know.
    private func save(_ url: URL, nodes: [[String: Any]], edges: [[String: Any]]) {
        // Auto-save runs on a timer, so this check is what stops a background
        // write from quietly overwriting edits made in Obsidian since we loaded.
        if let known = lastKnownWrite, let current = Self.modified(url),
           current > known.addingTimeInterval(0.5) {
            notify("This canvas changed outside ATLAS. Reopen it before saving.", bad: true)
            return
        }
        do {
            let existing = (try? store.load(url)) ?? CanvasDocument(url: url, raw: [:])
            try store.save(existing.merging(nodes: nodes, edges: edges))
            lastKnownWrite = Self.modified(url)
            push(raw: "window.atlasCanvas.saved()", json: "{}")
        } catch {
            notify("Could not save: \(error.localizedDescription)", bad: true)
        }
    }

    nonisolated static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func create(named name: String) {
        do {
            let document = try store.create(named: name)
            lastKnownWrite = Self.modified(document.url)
            var payload = document.raw
            payload["path"] = document.url.path
            payload["name"] = document.name
            push("loaded", encode(payload))
        } catch {
            notify(error.localizedDescription, bad: true)
        }
    }

    /// Renders a preview for a file node and hands it back as a data URI.
    ///
    /// The page has no file access at all — that is deliberate — so an image
    /// cannot be an `<img src="file://…">`. Instead the app resolves the path,
    /// downsamples the image and returns the bytes inline. Eighteen full-size
    /// PNGs would be a lot of memory; a 480px JPEG is not.
    private func preview(file: String, canvas: URL) {
        guard let url = Self.resolve(file, from: canvas) else { return }
        let extensions = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]

        if extensions.contains(url.pathExtension.lowercased()) {
            // Off the main thread: a canvas of twenty images would otherwise
            // stall the window while they decode.
            Task.detached(priority: .utility) {
                guard let data = Self.thumbnail(of: url, maxDimension: 480) else { return }
                let uri = "data:image/jpeg;base64,\(data.base64EncodedString())"
                await MainActor.run { self.send(preview: ["file": file, "image": uri]) }
            }
            return
        }

        // Markdown and other text: the first few lines are enough to recognise it.
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let excerpt = text.split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(14).joined(separator: "\n")
            send(preview: ["file": file, "text": String(excerpt.prefix(600))])
        }
    }

    private func send(preview payload: [String: Any]) {
        push("preview", encode(payload))
    }

    /// Path resolution lives in AtlasCore as `CanvasWebViewPathResolver` so it
    /// can be tested; this is just the spelling used here.
    nonisolated static func resolve(_ file: String, from canvas: URL) -> URL? {
        CanvasWebViewPathResolver.resolve(file, from: canvas)
    }

    /// Downsamples with ImageIO rather than loading the full image first, so a
    /// 4000px source never lands in memory at full size.
    ///
    /// Nonisolated because it touches no actor state — that is what lets the
    /// decode happen off the main thread instead of stalling the window.
    nonisolated static func thumbnail(of url: URL, maxDimension: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    }

    private func notify(_ message: String, bad: Bool) {
        guard let json = encode([message, bad ? "1" : ""]) else { return }
        push(raw: "window.atlasCanvas.notify(JSON.parse(json)[0], JSON.parse(json)[1] !== '')",
             json: json)
    }

    private func encode(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    private func push(_ function: String, _ json: String?) {
        guard let json else { return }
        push(raw: "window.atlasCanvas.\(function)(json)", json: json)
    }

    private func push(raw script: String, json: String) {
        guard let webView, pageIsReady else {
            pending.append((script, json))
            return
        }
        webView.callAsyncJavaScript(script, arguments: ["json": json], in: nil, in: .page) { result in
            if case .failure(let error) = result {
                NSLog("[ATLAS Canvas] script failed: %@", error.localizedDescription)
            }
        }
    }
}
