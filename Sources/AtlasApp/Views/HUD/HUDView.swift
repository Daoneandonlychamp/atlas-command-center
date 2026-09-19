import SwiftUI
import WebKit
import AtlasCore

/// The JARVIS surface: a web page hosted inside ATLAS.
///
/// Why a web view rather than SwiftUI shapes — the HUD is dense vector work
/// that gets restyled constantly, and HTML/Canvas iterates far faster than
/// hand-coded `Path`s. The page renders only; every number it shows is
/// assembled natively in `HUDFeed` and handed over as JSON, so the native side
/// keeps EventKit, the Keychain, and process access.
struct HUDView: View {
    @EnvironmentObject var appState: AtlasAppState
    @StateObject private var feed = HUDFeed.shared
    @State private var bridge = HUDBridge()

    /// One second: fast enough for a live CPU sweep, and the expensive sources
    /// throttle themselves inside HUDFeed.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let stateManager = SovereignPresenceStateManager.shared
    private let voiceService = SovereignVoiceService.shared

    var body: some View {
        HUDWebView(bridge: bridge, onAction: handle)
            .onAppear {
                pushFrame()
                // The Chatterbox model takes about a minute to load. Warming it
                // when the dashboard opens turns the first BRIEF ME press from a
                // sixty-second silence into a near-immediate one.
                SovereignVoiceService.shared.warmWorker()
            }
            .onReceive(tick) { _ in pushFrame() }
            .onReceive(stateManager.objectWillChange) { _ in pushFrame() }
            .onReceive(voiceService.objectWillChange) { _ in pushFrame() }
            // Loudness rides its own channel at 30 Hz. Routing it through
            // pushFrame() rebuilt and re-encoded the entire dashboard — disk
            // read included — on every audio frame.
            .onReceive(voiceService.energyUpdates) { frame in bridge.sendEnergy(frame) }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        feed.reloadAll()
                        appState.refreshAllData()
                        pushFrame()
                    } label: {
                        Label("Refresh HUD", systemImage: "arrow.clockwise")
                    }
                    .help("Re-read every source now")
                }
            }
    }

    /// Actions the page can ask for. Kept to a fixed, named set — the page
    /// never gets to say "run this", only "the user pressed this button".
    private func handle(_ action: String) {
        switch action {
        case "requestCalendar":
            CalendarManager.shared.requestCalendarAccess { _ in appState.refreshAllData() }
        case "requestReminders":
            CalendarManager.shared.requestReminderAccess { _ in appState.refreshAllData() }
        case "openProjects":
            appState.selectedSection = .projects
        case "openAutomations":
            appState.selectedSection = .automations
        case "openNotes":
            appState.selectedSection = .notes
        case "openConnections":
            appState.selectedSection = .connections
        case "openActivity":
            appState.selectedSection = .activity
        case "speakBrief":
            speakBrief()
        case "stopSpeaking":
            SovereignVoiceService.shared.stop()
        case "refresh":
            feed.reloadAll()
            appState.refreshAllData()
        case let error where error.hasPrefix("jserror:"):
            NSLog("[ATLAS HUD] page error: %@", String(error.dropFirst("jserror:".count)))
        default:
            NSLog("[ATLAS HUD] ignoring unknown action %@", action)
        }
    }

    /// Speaks the current snapshot. The text is composed from the same payload
    /// the page is showing, so what you hear matches what you see.
    private func speakBrief() {
        guard let payload = feed.payload else { return }
        let voice = SovereignVoiceService.shared

        // Already working on it. Restarting here would call stop(), which kills
        // the worker mid-synthesis and puts the model load back to zero.
        switch voice.state {
        case .warming, .synthesizing, .playing:
            NSLog("[ATLAS HUD] brief already in progress (%@)", voice.state.uiState)
            return
        default:
            break
        }

        voice.checkRuntimeAvailability()
        let text = BriefComposer.spokenBrief(from: payload)
        NSLog("[ATLAS HUD] speaking brief (%d chars)", text.count)
        voice.speak(text: text, deliveryMode: .mission, onPlaybackCompleted: { outcome in
            NSLog("[ATLAS HUD] brief finished: %@", String(describing: outcome))
        })
    }

    private func pushFrame() {
        feed.tick(
            events: appState.todayEvents,
            overdueTasks: appState.overdueReminders.count,
            calendarAuthorized: CalendarManager.shared.calendarAuthorizationStatus == .authorized,
            remindersAuthorized: CalendarManager.shared.reminderAuthorizationStatus == .authorized,
            projects: appState.projects,
            notes: appState.recentNotes,
            pendingApprovals: appState.pendingApprovals.count,
            services: appState.serviceStatuses,
            loaded: appState.hasLoadedOnce
        )
        guard let payload = feed.payload else { return }
        bridge.send(payload.jsonString())
    }
}

/// Holds the web view so frames can be pushed into a page that outlives any
/// single SwiftUI body evaluation.
final class HUDBridge {
    fileprivate weak var webView: WKWebView?
    private var pageIsReady = false
    private var pending: String?

    /// Four numbers straight at the field, no payload build and no JSON encode.
    func sendEnergy(_ frame: AudioEnergyFrame) {
        guard let webView, pageIsReady else { return }
        let js = String(
            format: "window.atlasEnergy&&window.atlasEnergy(%.4f,%.4f,%.4f,%.4f)",
            frame.rmsLoudness, frame.bassEnergy, frame.midEnergy, frame.trebleEnergy
        )
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func send(_ json: String) {
        guard let webView, pageIsReady else {
            pending = json
            return
        }
        // The payload is passed as a JSON string and parsed inside the page,
        // so nothing in it is ever evaluated as JavaScript.
        let escaped = json
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "")
        webView.evaluateJavaScript("window.atlasRender(JSON.parse('\(escaped)'))") { _, error in
            if let error { NSLog("[ATLAS HUD] render error: %@", error.localizedDescription) }
        }
    }

    fileprivate func pageDidLoad() {
        pageIsReady = true
        if let pending {
            self.pending = nil
            send(pending)
        }
    }
}

private struct HUDWebView: NSViewRepresentable {
    let bridge: HUDBridge
    let onAction: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // The HUD page ships inside the app and changes with it. A persistent
        // store keeps serving the previous build's copy after an update, so
        // edits appear to do nothing — always load it fresh.
        config.websiteDataStore = .nonPersistent()

        // ES modules loaded from file:// are blocked as cross-origin, which
        // stops the bundled three.js field from loading at all. These allow a
        // file:// page to read sibling files. Scoped to pages ATLAS ships
        // itself — the web view never loads remote content.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        config.userContentController.add(context.coordinator, name: "atlas")

        // Shared tokens and components, injected before the page's own
        // <style> so each page can still override a shared default.
        config.userContentController.addAtlasSharedStyles()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // The page paints its own background; matching it here stops a white
        // flash between load and first paint.
        // Matches the page's own ground, so a light interface does not
        // flash black behind the web view while it loads.
        webView.underPageBackgroundColor = .atlasAdaptive(light: 0xF0ECE4, dark: 0x06070A)

        // Dev escape hatch: ATLAS_HUD_PAGE takes either a bundled page name, so a
        // candidate visual can be measured without touching the working one, or
        // an absolute path to a file in the repo, which is the form every other
        // surface uses and the only one that can be watched for edits.
        let hudOverride = ProcessInfo.processInfo.environment["ATLAS_HUD_PAGE"]
        let overridePath = hudOverride.flatMap { value -> URL? in
            guard value.hasPrefix("/") else { return nil }
            return FileManager.default.fileExists(atPath: value) ? URL(fileURLWithPath: value) : nil
        }

        if let page = overridePath ?? hudOverride.flatMap({ AtlasResources.page(named: $0) }) {
            NSLog("[ATLAS HUD] override page %@", page.path)
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else if let page = AtlasResources.hudPage {
            NSLog("[ATLAS HUD] loading %@", page.path)
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            NSLog("[ATLAS HUD] hud.html NOT FOUND in AtlasCore bundle")
            webView.loadHTMLString(Self.missingPage, baseURL: nil)
        }

        // Only a path override is a file you can edit; a bundled name is not.
        context.coordinator.liveReload = PageLiveReload.watch(overridePath, reloading: webView)

        bridge.webView = webView
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge, onAction: onAction) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let bridge: HUDBridge
        private let onAction: (String) -> Void
        /// Held here so it outlives makeNSView; a watcher nobody retains
        /// is deallocated at once and silently never fires.
        var liveReload: PageLiveReload?

        init(bridge: HUDBridge, onAction: @escaping (String) -> Void) {
            self.bridge = bridge
            self.onAction = onAction
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "atlas", let action = message.body as? String else { return }
            DispatchQueue.main.async { self.onAction(action) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            NSLog("[ATLAS HUD] page loaded")
            bridge.pageDidLoad()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            NSLog("[ATLAS HUD] provisional nav failed: %@", error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[ATLAS HUD] nav failed: %@", error.localizedDescription)
        }
    }

    /// Shown only if the bundled page is missing, so a packaging mistake is
    /// visible instead of a silent black rectangle.
    static let missingPage = """
    <body style="background:#06070a;color:#ff3b30;font:12px -apple-system;padding:24px">
    HUD page not found in the app bundle — hud.html did not ship with AtlasCore resources.
    </body>
    """
}
