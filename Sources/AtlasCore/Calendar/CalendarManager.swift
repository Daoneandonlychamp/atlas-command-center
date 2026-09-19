import Foundation
import EventKit

public struct AtlasCalendarEvent: Identifiable, Codable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let location: String?
    public let calendarName: String
    /// The owning calendar's colour, so a week view can tint blocks the way
    /// Calendar.app does rather than painting everything one shade.
    public let colorHex: String
    public let isAllDay: Bool
    public let notes: String?
    /// False for subscribed or read-only calendars, so the page can refuse to
    /// offer a drag that would fail on save.
    public let isEditable: Bool

    public init(id: String = UUID().uuidString, title: String, startDate: Date, endDate: Date,
                location: String? = nil, calendarName: String = "Personal",
                colorHex: String = "#D4B059", isAllDay: Bool = false,
                notes: String? = nil, isEditable: Bool = true) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.calendarName = calendarName
        self.colorHex = colorHex
        self.isAllDay = isAllDay
        self.notes = notes
        self.isEditable = isEditable
    }
}

public struct AtlasTask: Identifiable, Codable {
    public let id: String
    public let title: String
    public let dueDate: Date?
    public var isCompleted: Bool
    /// The reminder list's name. On the kanban board this is the column.
    public let category: String
    /// The list's identifier, which is what moving a card between columns writes.
    public let listId: String
    public let notes: String?
    /// EKReminder priority: 0 none, 1–4 high, 5 medium, 6–9 low.
    public let priority: Int
    /// When the reminder was made and last touched. The board ages cards off
    /// these, so a task nobody has moved in a fortnight shows it.
    public let createdAt: Date?
    public let modifiedAt: Date?

    public init(id: String = UUID().uuidString, title: String, dueDate: Date? = nil,
                isCompleted: Bool = false, category: String = "General",
                listId: String = "", notes: String? = nil, priority: Int = 0,
                createdAt: Date? = nil, modifiedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.category = category
        self.listId = listId
        self.notes = notes
        self.priority = priority
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

public enum CalendarPermissionStatus: String, Codable {
    case notDetermined = "Not Determined"
    case authorized = "Authorized"
    case denied = "Denied"
    case restricted = "Restricted"
}

public final class CalendarManager {
    public static let shared = CalendarManager()

    private let eventStore = EKEventStore()

    public init() {}

    public var calendarAuthorizationStatus: CalendarPermissionStatus {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess:
            return .authorized
        case .denied, .writeOnly:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    public var reminderAuthorizationStatus: CalendarPermissionStatus {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .authorized, .fullAccess:
            return .authorized
        case .denied, .writeOnly:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    public func requestCalendarAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    public func requestReminderAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToReminders { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            eventStore.requestAccess(to: .reminder) { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    public func fetchTodayEvents() -> [AtlasCalendarEvent] {
        guard calendarAuthorizationStatus == .authorized else { return [] }
        let now = Date()
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }

        let predicate = eventStore.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let ekEvents = eventStore.events(matching: predicate)

        return ekEvents.map { ek in
            AtlasCalendarEvent(
                id: ek.eventIdentifier ?? UUID().uuidString,
                title: ek.title ?? "Untitled Event",
                startDate: ek.startDate,
                endDate: ek.endDate,
                location: ek.location,
                calendarName: ek.calendar?.title ?? "Calendar"
            )
        }.sorted { $0.startDate < $1.startDate }
    }

    public func fetchUpcomingEvents(days: Int = 7) -> [AtlasCalendarEvent] {
        guard calendarAuthorizationStatus == .authorized else { return [] }
        let now = Date()
        let cal = Calendar.current
        let startOfTomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now) ?? now)
        guard let endPeriod = cal.date(byAdding: .day, value: days, to: startOfTomorrow) else { return [] }

        let predicate = eventStore.predicateForEvents(withStart: startOfTomorrow, end: endPeriod, calendars: nil)
        let ekEvents = eventStore.events(matching: predicate)

        return ekEvents.map { ek in
            AtlasCalendarEvent(
                id: ek.eventIdentifier ?? UUID().uuidString,
                title: ek.title ?? "Untitled Event",
                startDate: ek.startDate,
                endDate: ek.endDate,
                location: ek.location,
                calendarName: ek.calendar?.title ?? "Calendar"
            )
        }.sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Range Fetch (month grid)

    /// Fetch all events in an arbitrary date range (used by the month grid).
    public func fetchEvents(from start: Date, to end: Date) -> [AtlasCalendarEvent] {
        guard calendarAuthorizationStatus == .authorized else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        return eventStore.events(matching: predicate).map(Self.convert).sorted { $0.startDate < $1.startDate }
    }

    /// One place that turns an EKEvent into the shape the app and its pages use,
    /// so a field added here reaches every caller instead of one fetch method.
    static func convert(_ ek: EKEvent) -> AtlasCalendarEvent {
        AtlasCalendarEvent(
            id: ek.eventIdentifier ?? UUID().uuidString,
            title: ek.title ?? "Untitled Event",
            startDate: ek.startDate,
            endDate: ek.endDate,
            location: ek.location,
            calendarName: ek.calendar?.title ?? "Calendar",
            colorHex: ek.calendar?.cgColor.flatMap { CalendarManager.hex(from: $0) } ?? "#D4B059",
            isAllDay: ek.isAllDay,
            notes: ek.notes,
            isEditable: ek.calendar?.allowsContentModifications ?? false
        )
    }

    static func hex(from color: CGColor) -> String? {
        guard let comps = color.components, comps.count >= 3 else { return nil }
        let r = Int(comps[0] * 255), g = Int(comps[1] * 255), b = Int(comps[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: - Writable Sources

    public struct CalendarSource: Identifiable, Hashable {
        public let id: String
        public let title: String
        public let colorHex: String
    }

    /// Writable event calendars the user can add events to.
    public func writableEventCalendars() -> [CalendarSource] {
        guard calendarAuthorizationStatus == .authorized else { return [] }
        return eventStore.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .map { CalendarSource(id: $0.calendarIdentifier, title: $0.title, colorHex: $0.cgColor.flatMap { hexString(from: $0) } ?? "#B0B0B0") }
    }

    /// Writable reminder lists.
    public func writableReminderLists() -> [CalendarSource] {
        guard reminderAuthorizationStatus == .authorized else { return [] }
        return eventStore.calendars(for: .reminder)
            .filter { $0.allowsContentModifications }
            .map { CalendarSource(id: $0.calendarIdentifier, title: $0.title, colorHex: $0.cgColor.flatMap { hexString(from: $0) } ?? "#B0B0B0") }
    }

    private func hexString(from color: CGColor) -> String? { Self.hex(from: color) }

    // MARK: - Create

    public enum CalendarWriteError: Error { case notAuthorized, noCalendar, saveFailed(String) }

    /// Create a new calendar event. Pass `calendarId` from `writableEventCalendars()` or nil for default.
    public func createEvent(title: String, start: Date, end: Date, location: String?, notes: String?, calendarId: String?) -> Result<Void, CalendarWriteError> {
        guard calendarAuthorizationStatus == .authorized else { return .failure(.notAuthorized) }
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = start
        event.endDate = end
        if let location, !location.isEmpty { event.location = location }
        if let notes, !notes.isEmpty { event.notes = notes }

        if let calendarId, let cal = eventStore.calendar(withIdentifier: calendarId) {
            event.calendar = cal
        } else if let def = eventStore.defaultCalendarForNewEvents {
            event.calendar = def
        } else {
            return .failure(.noCalendar)
        }

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return .success(())
        } catch {
            return .failure(.saveFailed(error.localizedDescription))
        }
    }

    /// Create a new reminder. Pass `listId` from `writableReminderLists()` or nil for default.
    public func createReminder(title: String, dueDate: Date?, notes: String?, listId: String?,
                               priority: Int = 0) -> Result<Void, CalendarWriteError> {
        guard reminderAuthorizationStatus == .authorized else { return .failure(.notAuthorized) }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        if priority > 0 { reminder.priority = priority }
        if let notes, !notes.isEmpty { reminder.notes = notes }
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        }

        if let listId, let cal = eventStore.calendar(withIdentifier: listId) {
            reminder.calendar = cal
        } else if let def = eventStore.defaultCalendarForNewReminders() {
            reminder.calendar = def
        } else {
            return .failure(.noCalendar)
        }

        do {
            try eventStore.save(reminder, commit: true)
            return .success(())
        } catch {
            return .failure(.saveFailed(error.localizedDescription))
        }
    }

    // MARK: - Identified writes
    //
    // The existing create methods return Void, and several callers depend on
    // that signature. Bills need the identifier back so a later sync can edit
    // the entry it made rather than adding a second one, so these are separate
    // additions rather than a change to a contract already in use.

    /// Creates a reminder and returns its identifier.
    public func createReminderReturningId(title: String, dueDate: Date?, notes: String?,
                                          listId: String?) -> Result<String, CalendarWriteError> {
        guard reminderAuthorizationStatus == .authorized else { return .failure(.notAuthorized) }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        if let notes, !notes.isEmpty { reminder.notes = notes }
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueDate)
        }
        if let listId, let list = eventStore.calendar(withIdentifier: listId) {
            reminder.calendar = list
        } else if let fallback = eventStore.defaultCalendarForNewReminders() {
            reminder.calendar = fallback
        } else {
            return .failure(.noCalendar)
        }
        do {
            try eventStore.save(reminder, commit: true)
            return .success(reminder.calendarItemIdentifier)
        } catch {
            return .failure(.saveFailed(error.localizedDescription))
        }
    }

    /// Creates an all-day event and returns its identifier.
    public func createAllDayEventReturningId(title: String, on day: Date, notes: String?,
                                             calendarId: String?) -> Result<String, CalendarWriteError> {
        guard calendarAuthorizationStatus == .authorized else { return .failure(.notAuthorized) }
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.isAllDay = true
        event.startDate = Calendar.current.startOfDay(for: day)
        event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: event.startDate) ?? event.startDate
        if let notes, !notes.isEmpty { event.notes = notes }
        if let calendarId, let cal = eventStore.calendar(withIdentifier: calendarId) {
            event.calendar = cal
        } else if let fallback = eventStore.defaultCalendarForNewEvents {
            event.calendar = fallback
        } else {
            return .failure(.noCalendar)
        }
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return .success(event.eventIdentifier)
        } catch {
            return .failure(.saveFailed(error.localizedDescription))
        }
    }

    /// Finds an existing event calendar by name, or makes one.
    ///
    /// Used only for the container ATLAS owns — it never adopts a calendar the
    /// user happens to have named the same thing in a different source.
    public func findOrCreateEventCalendar(named title: String) -> Result<String, CalendarWriteError> {
        guard calendarAuthorizationStatus == .authorized else { return .failure(.notAuthorized) }
        if let existing = eventStore.calendars(for: .event).first(where: {
            $0.title == title && $0.allowsContentModifications
        }) {
            return .success(existing.calendarIdentifier)
        }
        guard let source = eventStore.defaultCalendarForNewEvents?.source
                ?? eventStore.sources.first(where: { $0.sourceType == .calDAV })
                ?? eventStore.sources.first(where: { $0.sourceType == .local })
        else { return .failure(.noCalendar) }

        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = title
        calendar.source = source
        do {
            try eventStore.saveCalendar(calendar, commit: true)
            return .success(calendar.calendarIdentifier)
        } catch {
            return .failure(.saveFailed(error.localizedDescription))
        }
    }

    /// Finds an existing reminder list by name, or makes one.
    public func findOrCreateReminderList(named title: String) -> Result<String, CalendarWriteError> {
        guard reminderAuthorizationStatus == .authorized else { return .failure(.notAuthorized) }
        if let existing = eventStore.calendars(for: .reminder).first(where: {
            $0.title == title && $0.allowsContentModifications
        }) {
            return .success(existing.calendarIdentifier)
        }
        return createReminderList(named: title)
    }

    /// Removes a reminder ATLAS created. Silent when it is already gone —
    /// deleting something the user removed by hand is not an error.
    @discardableResult
    public func deleteReminderIfPresent(id: String) -> Bool {
        guard reminderAuthorizationStatus == .authorized,
              let item = eventStore.calendarItem(withIdentifier: id) as? EKReminder else { return false }
        return (try? eventStore.remove(item, commit: true)) != nil
    }

    /// Removes an event ATLAS created. Silent when it is already gone.
    @discardableResult
    public func deleteEventIfPresent(id: String) -> Bool {
        guard calendarAuthorizationStatus == .authorized,
              let event = eventStore.event(withIdentifier: id) else { return false }
        return (try? eventStore.remove(event, span: .thisEvent, commit: true)) != nil
    }

    /// Creates a Reminders list, which on the board is a column.
    ///
    /// A board needs somewhere for work to move *to*; with a single list there is
    /// nothing to drag between. The list is real — it shows up in Reminders.app
    /// and on the phone like any other.
    public func createReminderList(named title: String) -> Result<String, CalendarWriteError> {
        guard reminderAuthorizationStatus == .authorized else { return .failure(.notAuthorized) }
        // Local sources cannot always hold reminders; reusing the source the
        // default list already lives in is what makes this land in iCloud.
        guard let source = eventStore.defaultCalendarForNewReminders()?.source
                ?? eventStore.sources.first(where: { $0.sourceType == .calDAV })
                ?? eventStore.sources.first(where: { $0.sourceType == .local })
        else { return .failure(.noCalendar) }

        let list = EKCalendar(for: .reminder, eventStore: eventStore)
        list.title = title
        list.source = source
        do {
            try eventStore.saveCalendar(list, commit: true)
            return .success(list.calendarIdentifier)
        } catch {
            return .failure(.saveFailed(error.localizedDescription))
        }
    }

    // MARK: - Edit and delete

    /// Changes an existing event. Only the fields passed are touched, so a drag
    /// that moves an event in time does not have to resend its title and notes.
    ///
    /// `span: .thisEvent` on purpose — editing one occurrence of a repeating
    /// event should not silently rewrite the whole series.
    public func updateEvent(id: String, title: String? = nil, start: Date? = nil, end: Date? = nil,
                            location: String? = nil, notes: String? = nil,
                            calendarId: String? = nil) -> Result<Void, CalendarWriteError> {
        guard calendarAuthorizationStatus == .authorized else { return .failure(.notAuthorized) }
        guard let event = eventStore.event(withIdentifier: id) else { return .failure(.noCalendar) }
        guard event.calendar?.allowsContentModifications == true else {
            return .failure(.saveFailed("That calendar is read-only."))
        }

        if let title { event.title = title }
        if let start { event.startDate = start }
        if let end { event.endDate = end }
        if let location { event.location = location.isEmpty ? nil : location }
        if let notes { event.notes = notes.isEmpty ? nil : notes }
        if let calendarId, let cal = eventStore.calendar(withIdentifier: calendarId) { event.calendar = cal }

        // An end before its start is rejected by EventKit with an unhelpful
        // error, and a drag can produce it; keep the duration instead.
        if event.endDate <= event.startDate {
            event.endDate = event.startDate.addingTimeInterval(3600)
        }

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return .success(())
        } catch {
            return .failure(.saveFailed(error.localizedDescription))
        }
    }

    public func deleteEvent(id: String) -> Result<Void, CalendarWriteError> {
        guard calendarAuthorizationStatus == .authorized else { return .failure(.notAuthorized) }
        guard let event = eventStore.event(withIdentifier: id) else { return .failure(.noCalendar) }
        do {
            try eventStore.remove(event, span: .thisEvent, commit: true)
            return .success(())
        } catch {
            return .failure(.saveFailed(error.localizedDescription))
        }
    }

    /// Changes a reminder. Moving one between lists is how a kanban card changes
    /// column, so `listId` is the field that matters most here.
    public func updateReminder(id: String, title: String? = nil, dueDate: Date?? = nil,
                               notes: String? = nil, listId: String? = nil,
                               isCompleted: Bool? = nil) -> Result<Void, CalendarWriteError> {
        guard reminderAuthorizationStatus == .authorized else { return .failure(.notAuthorized) }
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            return .failure(.noCalendar)
        }

        if let title { reminder.title = title }
        if let notes { reminder.notes = notes.isEmpty ? nil : notes }
        if let isCompleted { reminder.isCompleted = isCompleted }
        if let listId, let cal = eventStore.calendar(withIdentifier: listId) { reminder.calendar = cal }
        // Double optional: .some(nil) clears the due date, nil leaves it alone.
        if let dueDate {
            reminder.dueDateComponents = dueDate.map {
                Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0)
            }
        }

        do {
            try eventStore.save(reminder, commit: true)
            return .success(())
        } catch {
            return .failure(.saveFailed(error.localizedDescription))
        }
    }

    public func deleteReminder(id: String) -> Result<Void, CalendarWriteError> {
        guard reminderAuthorizationStatus == .authorized else { return .failure(.notAuthorized) }
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            return .failure(.noCalendar)
        }
        do {
            try eventStore.remove(reminder, commit: true)
            return .success(())
        } catch {
            return .failure(.saveFailed(error.localizedDescription))
        }
    }

    /// Every reminder in the given lists, complete and incomplete.
    ///
    /// The kanban board needs the finished ones too — a Done column with nothing
    /// in it is not a Done column.
    public func fetchReminders(inLists listIds: [String]? = nil,
                               includeCompleted: Bool = true,
                               completion: @escaping ([AtlasTask]) -> Void) {
        guard reminderAuthorizationStatus == .authorized else { completion([]); return }
        let calendars = listIds.map { ids in
            ids.compactMap { eventStore.calendar(withIdentifier: $0) }
        }
        let predicate = eventStore.predicateForReminders(in: calendars?.isEmpty == false ? calendars : nil)
        eventStore.fetchReminders(matching: predicate) { reminders in
            let tasks = (reminders ?? [])
                .filter { includeCompleted || !$0.isCompleted }
                .map { reminder in
                    AtlasTask(
                        id: reminder.calendarItemIdentifier,
                        title: reminder.title ?? "Untitled",
                        dueDate: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                        isCompleted: reminder.isCompleted,
                        category: reminder.calendar?.title ?? "Reminders",
                        listId: reminder.calendar?.calendarIdentifier ?? "",
                        notes: reminder.notes,
                        priority: reminder.priority,
                        createdAt: reminder.creationDate,
                        modifiedAt: reminder.lastModifiedDate
                    )
                }
            DispatchQueue.main.async { completion(tasks) }
        }
    }

    /// Mark a reminder complete by its calendar item identifier.
    public func completeReminder(id: String, completion: @escaping (Bool) -> Void) {
        guard reminderAuthorizationStatus == .authorized else { completion(false); return }
        let predicate = eventStore.predicateForReminders(in: nil)
        eventStore.fetchReminders(matching: predicate) { [weak self] reminders in
            guard let self, let target = reminders?.first(where: { $0.calendarItemIdentifier == id }) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            target.isCompleted = true
            let ok = (try? self.eventStore.save(target, commit: true)) != nil
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Fetch ALL incomplete reminders (not just overdue) for the in-app list.
    public func fetchIncompleteReminders(completion: @escaping ([AtlasTask]) -> Void) {
        guard reminderAuthorizationStatus == .authorized else { completion([]); return }
        let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        eventStore.fetchReminders(matching: predicate) { ekReminders in
            let tasks = (ekReminders ?? []).map { r in
                AtlasTask(
                    id: r.calendarItemIdentifier,
                    title: r.title ?? "Untitled Reminder",
                    dueDate: r.dueDateComponents?.date,
                    isCompleted: r.isCompleted,
                    category: r.calendar?.title ?? "Reminders"
                )
            }
            DispatchQueue.main.async { completion(tasks) }
        }
    }

    public func fetchOverdueTasks(completion: @escaping ([AtlasTask]) -> Void) {
        guard reminderAuthorizationStatus == .authorized else {
            completion([])
            return
        }

        let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: Date(), calendars: nil)
        eventStore.fetchReminders(matching: predicate) { ekReminders in
            let tasks = (ekReminders ?? []).map { r in
                AtlasTask(
                    id: r.calendarItemIdentifier,
                    title: r.title ?? "Untitled Reminder",
                    dueDate: r.dueDateComponents?.date,
                    isCompleted: r.isCompleted,
                    category: r.calendar?.title ?? "Reminders"
                )
            }
            DispatchQueue.main.async { completion(tasks) }
        }
    }
}
