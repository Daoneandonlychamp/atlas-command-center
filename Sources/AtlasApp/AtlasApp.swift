import SwiftUI
import AppKit
import UserNotifications
import AtlasCore
import Luminare

final class AtlasAppDelegate: NSObject, NSApplicationDelegate {
    private var globalMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            AtlasMenuBarController.shared.setupMenuBar()
            self.registerKeyboardShortcuts()
            self.startNotificationScheduling()
        }
    }

    /// Event and reminder alerts are rebuilt from EventKit rather than tracked,
    /// so this only has to run often enough to notice new items — every fifteen
    /// minutes covers anything scheduled further out than the lead time.
    private var notificationTimer: Timer?

    private func startNotificationScheduling() {
        let scheduler = NotificationScheduler.shared
        guard scheduler.isAvailable else { return }
        scheduler.requestAccess { granted in
            guard granted else { return }
            scheduler.refresh()
            self.notificationTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { _ in
                scheduler.refresh()
            }
        }
    }

    private func registerKeyboardShortcuts() {
        globalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if flags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "k" {
                AtlasAppState.shared.isCommandPaletteOpen.toggle()
                return nil
            }
            if flags.contains([.command, .shift]) && event.charactersIgnoringModifiers?.lowercased() == "a" {
                AtlasAppState.shared.isCommandPaletteOpen.toggle()
                return nil
            }
            return event
        }
    }
}

final class AtlasMenuBarController: NSObject {
    static let shared = AtlasMenuBarController()
    private var statusItem: NSStatusItem?

    private var pollTimer: Timer?

    func setupMenuBar() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⚡︎ ATLAS"
        item.button?.action = #selector(menuBarClicked)
        item.button?.target = self
        self.statusItem = item

        // Driven independently of any view. The menu bar is what you see when
        // the window is closed or another section is open, so it cannot depend
        // on the HUD being on screen to stay current.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.pollState()
        }
        pollState()
    }

    /// Reading cron state spawns sqlite3 and reading sessions walks hundreds of
    /// megabytes. Neither belongs on the main thread — doing this synchronously
    /// at launch stops the window from ever appearing.
    private var lastCronPoll = Date.distantPast

    /// The usage file is a cheap read and changes constantly, so it is polled
    /// every tick. Cron state costs two sqlite3 spawns and moves on the order
    /// of minutes, so it is refreshed far less often.
    private func pollState() {
        let refreshCron = Date().timeIntervalSince(lastCronPoll) >= 60
        if refreshCron { lastCronPoll = Date() }

        DispatchQueue.global(qos: .utility).async {
            let cron = CronService.shared
            if refreshCron { cron.refresh() }
            let usage = ClaudeUsageReader.shared
            usage.refresh()

            DispatchQueue.main.async {
                self.update(failing: cron.failingCount, usage: usage.snapshot)
            }
        }
    }

    /// The menu bar is the only part of ATLAS visible when the window is not.
    /// It carries the one thing worth interrupting for — a failing job — and
    /// otherwise the number that quietly matters, today's spend.
    func update(failing: Int, usage: ClaudeUsageSnapshot?) {
        guard let button = statusItem?.button else { return }

        // A failing job outranks everything: it is the only state that wants
        // your attention right now.
        if failing > 0 {
            button.title = "⚡︎ \(failing)⚠︎"
            NSApp.dockTile.badgeLabel = "\(failing)"
        } else if let usage, !usage.isStale,
                  let five = usage.fiveHour?.usedPercentage {
            let seven = usage.sevenDay?.usedPercentage
            button.title = seven.map { String(format: "⚡︎ 5h %.0f%% · 7d %.0f%%", five, $0) }
                ?? String(format: "⚡︎ 5h %.0f%%", five)
            NSApp.dockTile.badgeLabel = nil
        } else {
            button.title = "⚡︎ ATLAS"
            NSApp.dockTile.badgeLabel = nil
        }

        // Notify once per transition into failure, not once per refresh.
        if failing > 0, failing != lastFailingCount {
            notifyFailing(failing)
        }
        lastFailingCount = failing
    }

    private var lastFailingCount = 0

    /// UserNotifications needs a real bundle identity. Running the executable
    /// directly during development there is none, and asking would trap — so
    /// the alert is simply skipped outside the packaged app.
    private func notifyFailing(_ count: Int) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "ATLAS · Scheduled jobs failing"
            content.body = "\(count) Hermes job\(count == 1 ? " is" : "s are") failing."
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "atlas.cron.failing.\(count)",
                                             content: content, trigger: nil))
        }
    }

    /// Direct chat, hanging off the menu bar item.
    ///
    /// Built lazily and kept alive, because it holds a live `DirectChatSession`
    /// conversation — rebuilding it per click would drop a reply mid-stream.
    private lazy var chatPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 460, height: 560)
        popover.contentViewController = NSHostingController(rootView: MenuBarChatView())
        return popover
    }()

    /// Click drops the chat down; the window is one button away inside it. The
    /// quick question is the common case, so it gets the single click.
    @objc private func menuBarClicked() {
        guard let button = statusItem?.button else { return }
        if chatPopover.isShown {
            chatPopover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            chatPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Brings the main window forward on the Assistant page, carrying whatever
    /// conversation the popover was on — they are the same session.
    func openAssistantWindow() {
        chatPopover.performClose(nil)
        AtlasAppState.shared.selectedSection = .assistant
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}

@main
struct AtlasApp: App {
    @NSApplicationDelegateAdaptor(AtlasAppDelegate.self) private var appDelegate
    @StateObject private var appState = AtlasAppState.shared
    @AppStorage("atlas.appearance") private var appearance = AtlasAppearance.system.rawValue

    private var preferredScheme: ColorScheme? {
        AtlasAppearance(rawValue: appearance)?.colorScheme
    }

    var body: some Scene {
        WindowGroup {
            MainContentView()
                .environmentObject(appState)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(preferredScheme)
                .luminareTint(overridingWith: AtlasTheme.Colors.champagneGold)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

enum AtlasAppearance: String, CaseIterable, Identifiable {
    case system, dark, light

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

final class AtlasAppState: ObservableObject {
    public static let shared = AtlasAppState()

    @Published public var selectedSection: NavigationSection = .overview
    @Published public var selectedProject: AtlasProject? = nil
    @Published public var pendingAssistantProjectContext: AtlasProject? = nil
    /// A day another surface wants the journal opened on — the calendar's
    /// "journal this day" button and the ⌘K verb both set it.
    @Published public var pendingJournalDay: Date? = nil
    @Published public var isCommandPaletteOpen: Bool = false
    @Published public var isRefreshing: Bool = false
    /// False until the first scan lands. Before that, an empty list means
    /// "not known yet", not "nothing there" — the UI must say so.
    @Published public var hasLoadedOnce: Bool = false

    @Published public var projects: [AtlasProject] = []
    @Published public var vaults: [AtlasVault] = []
    @Published public var serviceStatuses: [ServiceConnectionStatus] = []
    @Published public var activities: [AtlasActivity] = []
    @Published public var pendingApprovals: [AtlasApprovalRequest] = []
    @Published public var todayEvents: [AtlasCalendarEvent] = []
    @Published public var overdueReminders: [AtlasTask] = []
    @Published public var recentNotes: [AtlasNote] = []

    public init() {
        refreshAllData()
    }

    public func refreshAllData(completion: (() -> Void)? = nil) {
        guard !isRefreshing else {
            completion?()
            return
        }

        isRefreshing = true

        DispatchQueue.global(qos: .userInitiated).async {
            let group = DispatchGroup()

            var p: [AtlasProject] = []
            var v: [AtlasVault] = []
            var s: [ServiceConnectionStatus] = []
            var a: [AtlasActivity] = []
            var appr: [AtlasApprovalRequest] = []
            var calEvents: [AtlasCalendarEvent] = []
            var remTasks: [AtlasTask] = []
            var newestNotes: [AtlasNote] = []

            // 1. Projects
            group.enter()
            p = ProjectScanner.shared.discoverProjects()
            group.leave()

            // 2. Vaults
            group.enter()
            v = ObsidianScanner.shared.discoverVaults()
            group.leave()

            // 3. Service health
            group.enter()
            s = HermesConnector.shared.checkServices()
            group.leave()

            // 4. Activities & Approvals
            group.enter()
            a = ActivityLedger.shared.fetchActivities()
            appr = ActivityLedger.shared.fetchPendingApprovals()
            group.leave()

            // 5. Calendar events
            group.enter()
            if CalendarManager.shared.calendarAuthorizationStatus == .authorized {
                calEvents = CalendarManager.shared.fetchTodayEvents()
            }
            group.leave()

            // 6. Reminders (async EventKit callback)
            if CalendarManager.shared.reminderAuthorizationStatus == .authorized {
                group.enter()
                CalendarManager.shared.fetchOverdueTasks { tasks in
                    remTasks = tasks
                    group.leave()
                }
            }

            // 7. Globally newest notes
            group.enter()
            newestNotes = ObsidianScanner.shared.fetchGloballyNewestNotes(vaults: v, limit: 10)
            group.leave()

            _ = group.wait(timeout: .now() + 3.0)

            DispatchQueue.main.async {
                self.projects = p
                self.vaults = v
                self.serviceStatuses = s
                self.activities = a
                self.pendingApprovals = appr
                self.todayEvents = calEvents
                self.overdueReminders = remTasks
                self.recentNotes = newestNotes
                self.isRefreshing = false
                self.hasLoadedOnce = true
                completion?()
            }
        }
    }
}
