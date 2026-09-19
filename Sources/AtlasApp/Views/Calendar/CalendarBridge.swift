import Foundation
import WebKit
import AtlasCore

/// Sits between `calendar.html` and EventKit.
///
/// The page owns which range it is showing; this owns everything that touches
/// the user's data. Every write goes through `CalendarManager`, and every result
/// — including failures — is reported back to the page, because a drag that
/// silently did not save is worse than one that visibly failed.
@MainActor
final class CalendarBridge {
    private weak var webView: WKWebView?
    private var pageIsReady = false
    /// Calls made before the page finished loading. These hold the finished
    /// script, not a function name — flushing must not wrap them a second time.
    private var pending: [(script: String, json: String)] = []

    /// The window the page last asked for, so a write can refresh the same view.
    private var lastRange: (start: Date, end: Date)?
    private let manager = CalendarManager.shared

    /// Called after a successful write so the rest of the app can catch up.
    var onDataChanged: (() -> Void)?
    /// Asked for when the page wants the journal opened on a particular day.
    var onOpenJournal: ((Date) -> Void)?

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

    // MARK: - Actions

    func handle(_ action: CalendarAction) {
        switch action.action {
        case .range:
            guard let start = action.start, let end = action.end else {
                NSLog("[ATLAS Calendar] range request had unparseable dates")
                return
            }
            lastRange = (start, end)
            reload()

        case .create:
            guard let title = action.title, let start = action.start, let end = action.end else { return }
            report(manager.createEvent(title: title, start: start, end: end,
                                       location: action.location, notes: action.notes,
                                       calendarId: action.calendarId),
                   success: "Event created")

        case .update:
            guard let id = action.id else { return }
            report(manager.updateEvent(id: id, title: action.title, start: action.start,
                                       end: action.end, location: action.location,
                                       notes: action.notes),
                   success: "Event updated")

        case .delete:
            guard let id = action.id else { return }
            report(manager.deleteEvent(id: id), success: "Event deleted")

        case .completeReminder:
            guard let id = action.id else { return }
            report(manager.updateReminder(id: id, isCompleted: true), success: "Done")

        case .uncompleteReminder:
            guard let id = action.id else { return }
            report(manager.updateReminder(id: id, isCompleted: false), success: "Reopened")

        case .deleteReminder:
            guard let id = action.id else { return }
            report(manager.deleteReminder(id: id), success: "Reminder deleted")

        case .newReminder:
            guard let title = action.title else { return }
            report(manager.createReminder(title: title, dueDate: action.start,
                                          notes: action.notes, listId: action.calendarId),
                   success: "Reminder added")

        case .quickAdd:
            guard let text = action.text else { return }
            quickAdd(text)

        case .openJournal:
            onOpenJournal?(action.start ?? Date())
        }
    }

    private func report(_ result: Result<Void, CalendarManager.CalendarWriteError>, success: String) {
        switch result {
        case .success:
            notify(success, bad: false)
            reload()
            onDataChanged?()
        case .failure(let error):
            notify(describe(error), bad: true)
            // Put the page back to the truth, so a failed drag does not leave the
            // event sitting where it never actually moved to.
            reload()
        }
    }

    private func describe(_ error: CalendarManager.CalendarWriteError) -> String {
        switch error {
        case .notAuthorized: return "ATLAS does not have calendar access."
        case .noCalendar: return "That calendar could not be found."
        case .saveFailed(let detail): return detail
        }
    }

    // MARK: - Quick add

    /// Turns "lunch with Ada thursday 1pm" into an event.
    ///
    /// The model only ever returns JSON describing the event; this code creates
    /// it. Nothing the model writes is executed, and a reply that does not parse
    /// is reported as a failure rather than guessed at.
    private func quickAdd(_ text: String) {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current

        let instruction = """
        Convert the user's line into a calendar event. Reply with JSON only, no \
        prose and no code fence, shaped exactly:
        {"title":"...","start":"YYYY-MM-DDTHH:MM:SS","end":"YYYY-MM-DDTHH:MM:SS","location":""}
        Times are local, 24-hour, with no timezone suffix. If no end is stated, \
        make it one hour after the start. If no time is stated, use 09:00. \
        Right now it is \(formatter.string(from: now)) (\(now.formatted(.dateTime.weekday(.wide)))).
        """

        Task {
            do {
                let reply = try await FeatherlessClient.shared.complete(
                    model: DirectChatSession.shared.settings.model,
                    messages: [
                        FeatherlessMessage(role: "system", content: instruction),
                        FeatherlessMessage(role: "user", content: text)
                    ],
                    temperature: 0.1,
                    maxTokens: 220
                )
                guard let parsed = QuickAddDraft(reply) else {
                    quickAddFailed("Could not read that as an event.")
                    return
                }
                let result = manager.createEvent(title: parsed.title, start: parsed.start,
                                                 end: parsed.end, location: parsed.location,
                                                 notes: "Added from: \(text)", calendarId: nil)
                switch result {
                case .success:
                    push("quickAddResult", encode(["title": parsed.title]))
                    reload()
                    onDataChanged?()
                case .failure(let error):
                    quickAddFailed(describe(error))
                }
            } catch {
                quickAddFailed(error.localizedDescription)
            }
        }
    }

    private func quickAddFailed(_ message: String) {
        push("quickAddResult", encode(["error": message]))
    }

    // MARK: - Feeding the page

    func reload() {
        let range = lastRange ?? (Date(), Calendar.current.date(byAdding: .day, value: 42, to: Date())!)
        let events = manager.fetchEvents(from: range.start, to: range.end)
        let calendars = manager.writableEventCalendars()

        NSLog("[ATLAS Calendar] range %@ → %@ gave %d events, %d writable calendars (cal auth %@, rem auth %@)",
              String(describing: range.start), String(describing: range.end), events.count, calendars.count,
              manager.calendarAuthorizationStatus.rawValue, manager.reminderAuthorizationStatus.rawValue)

        manager.fetchReminders(includeCompleted: false) { [weak self] reminders in
            guard let self else { return }
            NSLog("[ATLAS Calendar] %d reminders", reminders.count)
            let payload = CalendarPayload(
                events: events.map(CalendarPayload.Event.init),
                reminders: reminders
                    .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
                    .map(CalendarPayload.Reminder.init),
                calendars: calendars.map { CalendarPayload.Source(id: $0.id, title: $0.title) },
                canWrite: !calendars.isEmpty
            )
            self.push("render", self.encode(payload))
        }
    }

    private func notify(_ message: String, bad: Bool) {
        guard let json = encode([message, bad ? "1" : ""]) else { return }
        // notify takes two arguments, so it is called with the array spread.
        push(raw: "window.atlasCalendar.notify(JSON.parse(json)[0], JSON.parse(json)[1] !== '')", json: json)
    }

    private func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func push(_ function: String, _ json: String?) {
        guard let json else { return }
        push(raw: "window.atlasCalendar.\(function)(json)", json: json)
    }

    /// The payload always travels as a bound argument rather than being spliced
    /// into the script text, so nothing in a calendar entry can break out of it.
    private func push(raw script: String, json: String) {
        guard let webView, pageIsReady else {
            pending.append((script, json))
            return
        }
        webView.callAsyncJavaScript(script, arguments: ["json": json], in: nil, in: .page) { result in
            if case .failure(let error) = result {
                NSLog("[ATLAS Calendar] script failed: %@", error.localizedDescription)
            }
        }
    }
}

/// What `calendar.html` expects to be handed.
private struct CalendarPayload: Encodable {
    struct Event: Encodable {
        let id: String, title: String, start: Date, end: Date
        let location: String?, notes: String?, calendar: String, color: String
        let allDay: Bool, editable: Bool

        init(_ event: AtlasCalendarEvent) {
            id = event.id
            title = event.title
            start = event.startDate
            end = event.endDate
            location = event.location
            notes = event.notes
            calendar = event.calendarName
            color = event.colorHex
            allDay = event.isAllDay
            editable = event.isEditable
        }
    }

    struct Reminder: Encodable {
        let id: String, title: String, due: Date?, completed: Bool, list: String

        init(_ task: AtlasTask) {
            id = task.id
            title = task.title
            due = task.dueDate
            completed = task.isCompleted
            list = task.category
        }
    }

    struct Source: Encodable { let id: String, title: String }

    let events: [Event]
    let reminders: [Reminder]
    let calendars: [Source]
    let canWrite: Bool
}

/// The JSON the model is asked to produce for quick add.
///
/// Parsed defensively: models wrap JSON in prose or a code fence often enough
/// that pulling the outermost braces out is worth the three lines.
private struct QuickAddDraft {
    let title: String
    let start: Date
    let end: Date
    let location: String?

    init?(_ reply: String) {
        guard let first = reply.firstIndex(of: "{"), let last = reply.lastIndex(of: "}"),
              first < last else { return nil }
        let slice = String(reply[first...last])
        guard let data = slice.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String, !title.isEmpty,
              let startText = object["start"] as? String,
              let start = QuickAddDraft.local(startText)
        else { return nil }

        self.title = title
        self.start = start
        self.end = (object["end"] as? String).flatMap(QuickAddDraft.local)
            ?? start.addingTimeInterval(3600)
        let place = object["location"] as? String
        self.location = (place?.isEmpty == false) ? place : nil
    }

    /// The model is told to answer in local time with no zone suffix, so these
    /// are parsed in the current timezone rather than as UTC.
    private static func local(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
