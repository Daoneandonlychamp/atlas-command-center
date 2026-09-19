import SwiftUI
import WebKit
import AtlasCore

/// The board: Reminders lists as columns, reminders as cards.
///
/// Nothing is stored here. Moving a card writes the reminder into another list,
/// so the board, Reminders.app, your phone and Siri are all one dataset. That is
/// the whole reason this is backed by EventKit rather than its own database.
struct KanbanView: View {
    @EnvironmentObject var appState: AtlasAppState
    @State private var bridge = KanbanBridge()
    @State private var status = CalendarManager.shared.reminderAuthorizationStatus

    var body: some View {
        Group {
            if status == .authorized {
                KanbanWebView(bridge: bridge)
            } else {
                gate
            }
        }
        .background(AtlasTheme.Colors.background)
        .onAppear {
            refresh()
            bridge.onDataChanged = { appState.refreshAllData() }
        }
    }

    private var gate: some View {
        VStack(spacing: AtlasTheme.Spacing.md) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 30))
                .foregroundColor(AtlasTheme.Colors.champagneGold)
            Text("The board needs access to Reminders")
                .font(AtlasTheme.Typography.headline)
                .foregroundColor(AtlasTheme.Colors.textPrimary)
            Text(status == .denied
                 ? "Access was denied, and macOS stops asking after that. Turn it on in System Settings › Privacy & Security › Reminders."
                 : "Columns are your Reminders lists.")
                .font(AtlasTheme.Typography.caption)
                .foregroundColor(AtlasTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: AtlasTheme.Spacing.sm) {
                Button("Request access") {
                    CalendarManager.shared.requestReminderAccess { _ in refresh() }
                }
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Check again") { refresh() }
            }
            .font(AtlasTheme.Typography.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refresh() {
        status = CalendarManager.shared.reminderAuthorizationStatus
        if status == .authorized { bridge.reload() }
    }
}

/// Hosts `kanban.html`.
///
/// Read access is granted to the resources folder rather than the single file,
/// because the page loads its vendored copy of Sortable from beside itself. That
/// folder holds only pages ATLAS ships; the dangerous flags that would let a
/// file:// page read anywhere on disk stay off.
struct KanbanWebView: NSViewRepresentable {
    let bridge: KanbanBridge

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
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

        let override = ProcessInfo.processInfo.environment["ATLAS_BOARD_PAGE"]
            .map { URL(fileURLWithPath: $0) }
        if let page = override ?? AtlasResources.kanbanPage {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            NSLog("[ATLAS Board] kanban.html NOT FOUND in AtlasCore bundle")
            webView.loadHTMLString("""
            <body style="background:#06070a;color:#ff3b30;font:12px -apple-system;padding:24px">
            Board page not found — kanban.html did not ship with AtlasCore resources.
            </body>
            """, baseURL: nil)
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
        private let bridge: KanbanBridge
        /// Held here so it outlives makeNSView; a watcher nobody retains
        /// is deallocated at once and silently never fires.
        var liveReload: PageLiveReload?

        init(bridge: KanbanBridge) { self.bridge = bridge }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "atlas",
                  let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let action = try? JSONDecoder().decode(BoardAction.self, from: data)
            else {
                NSLog("[ATLAS Board] dropped an unrecognised message from the page")
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
    }
}

/// Everything the board may ask for. Decoding is the allowlist.
struct BoardAction: Decodable {
    enum Kind: String, Decodable {
        case load, move, create, toggle, delete, rename, createList, schedule
    }

    let action: Kind
    let id: String?
    let listId: String?
    let title: String?
    let due: Date?
    let priority: Int?
    let completed: Bool?

    private enum CodingKeys: String, CodingKey {
        case action, id, listId, title, due, priority, completed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(Kind.self, forKey: .action)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        listId = try container.decodeIfPresent(String.self, forKey: .listId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        completed = try container.decodeIfPresent(Bool.self, forKey: .completed)
        due = try container.decodeIfPresent(String.self, forKey: .due).flatMap {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
        }
    }
}

/// Between `kanban.html` and EventKit.
@MainActor
final class KanbanBridge {
    private weak var webView: WKWebView?
    private var pageIsReady = false
    /// Finished scripts, not function names — flushing must not wrap them again.
    private var pending: [(script: String, json: String)] = []
    private let manager = CalendarManager.shared

    var onDataChanged: (() -> Void)?

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

    func handle(_ action: BoardAction) {
        switch action.action {
        case .load:
            reload()

        case .move:
            guard let id = action.id, let listId = action.listId else { return }
            report(manager.updateReminder(id: id, listId: listId), success: nil)

        case .create:
            guard let title = action.title else { return }
            report(manager.createReminder(title: title, dueDate: action.due, notes: nil,
                                          listId: action.listId,
                                          priority: Self.eventKitPriority(action.priority)),
                   success: "Added")

        case .toggle:
            guard let id = action.id, let completed = action.completed else { return }
            report(manager.updateReminder(id: id, isCompleted: completed), success: nil)

        case .delete:
            guard let id = action.id else { return }
            report(manager.deleteReminder(id: id), success: "Deleted")

        case .rename:
            guard let id = action.id, let title = action.title else { return }
            report(manager.updateReminder(id: id, title: title), success: nil)

        case .schedule:
            guard let id = action.id else { return }
            scheduleCard(id)

        case .createList:
            guard let title = action.title else { return }
            switch manager.createReminderList(named: title) {
            case .success:
                reload()
                onDataChanged?()
            case .failure(let error):
                let detail: String
                switch error {
                case .notAuthorized: detail = "ATLAS does not have Reminders access."
                case .noCalendar: detail = "No Reminders account to put the list in."
                case .saveFailed(let message): detail = message
                }
                notify(detail, bad: true)
            }
        }
    }

    /// Turns a card into an hour on the calendar: the board says what is worth
    /// doing, the calendar says when. Uses the card's due date if it has one,
    /// otherwise the next free-looking hour today.
    private func scheduleCard(_ id: String) {
        manager.fetchReminders(includeCompleted: true) { [weak self] tasks in
            guard let self, let task = tasks.first(where: { $0.id == id }) else { return }
            let start = Self.slot(for: task.dueDate)
            let result = self.manager.createEvent(
                title: task.title,
                start: start,
                end: start.addingTimeInterval(3600),
                location: nil,
                notes: "Scheduled from the ATLAS board · \(task.category)",
                calendarId: nil
            )
            switch result {
            case .success:
                self.notify("Scheduled \(Self.when.string(from: start))", bad: false)
                self.onDataChanged?()
            case .failure:
                self.notify("Could not put that on the calendar.", bad: true)
            }
        }
    }

    /// A due date lands on its own day; anything else goes to the next whole
    /// hour, which is close enough to be moved by dragging it.
    static func slot(for due: Date?) -> Date {
        let calendar = Calendar.current
        if let due { return due }
        let next = calendar.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        return calendar.date(bySetting: .minute, value: 0, of: next) ?? next
    }

    private static let when: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return formatter
    }()

    /// The page uses 1–3, high to low, the way people type it. EventKit wants
    /// 1–9 with 1–4 high, 5 medium, 6–9 low.
    static func eventKitPriority(_ value: Int?) -> Int {
        switch value ?? 0 {
        case 1: return 1
        case 2: return 5
        case 3: return 9
        default: return 0
        }
    }

    private func report(_ result: Result<Void, CalendarManager.CalendarWriteError>, success: String?) {
        switch result {
        case .success:
            if let success { notify(success, bad: false) }
            reload()
            onDataChanged?()
        case .failure(let error):
            let detail: String
            switch error {
            case .notAuthorized: detail = "ATLAS does not have Reminders access."
            case .noCalendar: detail = "That list could not be found."
            case .saveFailed(let message): detail = message
            }
            notify(detail, bad: true)
            // A card that did not actually move must not be left looking moved.
            reload()
        }
    }

    func reload() {
        let lists = manager.writableReminderLists()
        manager.fetchReminders(includeCompleted: true) { [weak self] tasks in
            guard let self else { return }
            NSLog("[ATLAS Board] %d lists, %d reminders", lists.count, tasks.count)
            let payload = BoardPayload(
                lists: lists.map { BoardPayload.List(id: $0.id, title: $0.title, color: $0.colorHex) },
                cards: tasks.map(BoardPayload.Card.init)
            )
            self.push("render", self.encode(payload))
        }
    }

    private func notify(_ message: String, bad: Bool) {
        guard let json = encode([message, bad ? "1" : ""]) else { return }
        push(raw: "window.atlasBoard.notify(JSON.parse(json)[0], JSON.parse(json)[1] !== '')", json: json)
    }

    private func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func push(_ function: String, _ json: String?) {
        guard let json else { return }
        push(raw: "window.atlasBoard.\(function)(json)", json: json)
    }

    private func push(raw script: String, json: String) {
        guard let webView, pageIsReady else {
            pending.append((script, json))
            return
        }
        webView.callAsyncJavaScript(script, arguments: ["json": json], in: nil, in: .page) { result in
            if case .failure(let error) = result {
                NSLog("[ATLAS Board] script failed: %@", error.localizedDescription)
            }
        }
    }
}

private struct BoardPayload: Encodable {
    struct List: Encodable { let id: String, title: String, color: String }

    struct Card: Encodable {
        let id: String, title: String, listId: String
        let due: Date?, completed: Bool, priority: Int
        let created: Date?, modified: Date?

        init(_ task: AtlasTask) {
            id = task.id
            title = task.title
            listId = task.listId
            due = task.dueDate
            completed = task.isCompleted
            priority = task.priority
            created = task.createdAt
            modified = task.modifiedAt
        }
    }

    let lists: [List]
    let cards: [Card]
}
