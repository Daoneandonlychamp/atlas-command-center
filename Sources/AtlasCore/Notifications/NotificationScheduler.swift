import Foundation
import UserNotifications

/// Local notifications for the things worth being interrupted by.
///
/// Three kinds and nothing else: an event a few
/// minutes before it starts, a reminder when it comes due, and a board card that
/// has gone stale. Anything more and the notifications stop meaning anything.
///
/// Everything is scheduled with `UNCalendarNotificationTrigger`, so alerts fire
/// whether or not ATLAS is running at that moment. Requests are re-created from
/// scratch on each pass and identified deterministically, so an event that moves
/// updates its alert rather than gaining a second one.
public final class NotificationScheduler {
    public static let shared = NotificationScheduler()

    /// Resolved on each use, never at construction.
    ///
    /// `UNUserNotificationCenter.current()` traps when the process has no bundle
    /// identity, and it traps inside UserNotifications rather than returning
    /// nil, so `isAvailable` cannot catch it. As a stored property it ran the
    /// moment `shared` was built — before any guard could run — which killed
    /// every `swift run AtlasApp` on launch with "bundleProxyForCurrentProcess
    /// is nil". Computed, the guards get to run first and the executable is
    /// debuggable outside a .app.
    ///
    /// Computed rather than `lazy`: `refresh` touches this from inside a
    /// UserNotifications completion handler, which is not the main thread, and
    /// a `lazy var` initialised from two threads at once is a data race.
    /// `current()` is a singleton accessor, so re-reading it costs nothing.
    private var centre: UNUserNotificationCenter { .current() }
    private let calendar = CalendarManager.shared

    /// Prefixes let a pass clear only its own kind, leaving cron alerts alone.
    private enum Prefix: String, CaseIterable {
        case event = "atlas.event."
        case reminder = "atlas.reminder."
        case stale = "atlas.stale."
    }

    public init() {}

    // MARK: - Settings

    public struct Settings: Codable, Equatable {
        public var events: Bool
        public var reminders: Bool
        public var staleCards: Bool
        /// How long before an event to speak up.
        public var eventLeadMinutes: Int
        /// How many days untouched before a card counts as stale. Matches the
        /// board's amber threshold so the badge and the alert agree.
        public var staleAfterDays: Int

        public init(events: Bool = true, reminders: Bool = true, staleCards: Bool = true,
                    eventLeadMinutes: Int = 10, staleAfterDays: Int = 7) {
            self.events = events
            self.reminders = reminders
            self.staleCards = staleCards
            self.eventLeadMinutes = eventLeadMinutes
            self.staleAfterDays = staleAfterDays
        }

        private static let key = "atlas.notifications.settings"

        public static func load() -> Settings {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode(Settings.self, from: data)
            else { return Settings() }
            return decoded
        }

        public func save() {
            guard let data = try? JSONEncoder().encode(self) else { return }
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    public var settings = Settings.load() {
        didSet { settings.save() }
    }

    // MARK: - Authorisation

    /// UserNotifications needs a real bundle identity. Running the executable
    /// directly during development there is none, and asking would trap.
    public var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    public func requestAccess(_ completion: ((Bool) -> Void)? = nil) {
        guard isAvailable else { completion?(false); return }
        centre.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion?(granted) }
        }
    }

    public func authorisationStatus(_ completion: @escaping (UNAuthorizationStatus) -> Void) {
        guard isAvailable else { completion(.denied); return }
        centre.getNotificationSettings { settings in
            DispatchQueue.main.async { completion(settings.authorizationStatus) }
        }
    }

    // MARK: - Scheduling

    /// Rebuilds every alert from the current state of the calendar and reminders.
    ///
    /// Cheap enough to run on a timer and after any write, and rebuilding rather
    /// than diffing means a deleted event cannot leave a ghost alert behind.
    public func refresh(completion: (() -> Void)? = nil) {
        guard isAvailable else { completion?(); return }

        centre.getPendingNotificationRequests { [weak self] pending in
            guard let self else { completion?(); return }
            let mine = pending.map(\.identifier).filter { id in
                Prefix.allCases.contains { id.hasPrefix($0.rawValue) }
            }
            self.centre.removePendingNotificationRequests(withIdentifiers: mine)

            var requests: [UNNotificationRequest] = []
            if self.settings.events { requests += self.eventRequests() }

            self.calendar.fetchReminders(includeCompleted: false) { tasks in
                if self.settings.reminders { requests += self.reminderRequests(tasks) }
                if self.settings.staleCards { requests += self.staleRequests(tasks) }

                for request in requests { self.centre.add(request, withCompletionHandler: nil) }
                NSLog("[ATLAS Notify] scheduled %d alerts", requests.count)
                completion?()
            }
        }
    }

    /// Events starting in the next week, minus the lead time.
    private func eventRequests() -> [UNNotificationRequest] {
        let now = Date()
        let events = calendar.fetchEvents(from: now, to: now.addingTimeInterval(7 * 86400))
        return events.compactMap { event in
            guard !event.isAllDay else { return nil }
            let fireAt = event.startDate.addingTimeInterval(-Double(settings.eventLeadMinutes) * 60)
            guard fireAt > now else { return nil }

            let time = DateFormatter()
            time.dateFormat = "HH:mm"
            var body = "Starts at \(time.string(from: event.startDate))"
            if let location = event.location, !location.isEmpty { body += " · \(location)" }

            return request(id: Prefix.event.rawValue + event.id,
                           title: event.title, body: body, at: fireAt)
        }
    }

    /// Reminders at the moment they come due, and a nudge for ones already past.
    private func reminderRequests(_ tasks: [AtlasTask]) -> [UNNotificationRequest] {
        let now = Date()
        var out: [UNNotificationRequest] = []

        for task in tasks {
            guard let due = task.dueDate else { continue }
            if due > now {
                out.append(request(id: Prefix.reminder.rawValue + task.id,
                                   title: task.title, body: "Due now · \(task.category)", at: due))
            }
        }

        // Overdue work does not re-notify itself in Reminders.app, which is how
        // it quietly rots. One daily nudge, not one per item, so a long overdue
        // list does not turn into a wall of alerts.
        let overdue = tasks.filter { ($0.dueDate ?? .distantFuture) < now }
        if !overdue.isEmpty, let tomorrow = Self.nextMorning(after: now) {
            let names = overdue.prefix(3).map(\.title).joined(separator: ", ")
            let extra = overdue.count > 3 ? " and \(overdue.count - 3) more" : ""
            out.append(request(id: Prefix.reminder.rawValue + "overdue",
                               title: "\(overdue.count) overdue",
                               body: names + extra, at: tomorrow))
        }
        return out
    }

    /// Cards nobody has touched. Same threshold the board paints amber at, so
    /// the alert and the badge never disagree.
    private func staleRequests(_ tasks: [AtlasTask]) -> [UNNotificationRequest] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Double(settings.staleAfterDays) * 86400)
        let stale = tasks.filter { task in
            guard !task.isCompleted else { return false }
            let touched = task.modifiedAt ?? task.createdAt
            return (touched ?? now) < cutoff
        }
        guard !stale.isEmpty, let tomorrow = Self.nextMorning(after: now) else { return [] }

        let names = stale.prefix(3).map(\.title).joined(separator: ", ")
        let extra = stale.count > 3 ? " and \(stale.count - 3) more" : ""
        return [request(id: Prefix.stale.rawValue + "digest",
                        title: "\(stale.count) card\(stale.count == 1 ? "" : "s") going stale",
                        body: "Untouched for \(settings.staleAfterDays)+ days: " + names + extra,
                        at: tomorrow)]
    }

    /// 9am tomorrow — digests belong at the start of a day, not the middle of one.
    static func nextMorning(after date: Date) -> Date? {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
    }

    private func request(id: String, title: String, body: String, at date: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        // Calendar-based rather than an interval, so the alert survives sleep and
        // fires at the wall-clock time it was meant to.
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }
}
