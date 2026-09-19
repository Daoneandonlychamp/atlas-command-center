import Foundation
import AtlasCore

/// Carries out what `BillCalendarSync.plan` decided.
///
/// The decisions live in AtlasCore and are unit-tested without EventKit. This
/// half only performs them, and it lives in AtlasApp because it needs
/// `CalendarManager`.
///
/// SAFETY — every write goes into the two containers ATLAS created and named
/// (`ATLAS Bills`), found or made on demand. Nothing here touches a list or
/// calendar the user already had, and nothing runs on its own: the Finances
/// page calls `syncAll` when the person presses the button.
@MainActor
final class BillSyncService {
    static let shared = BillSyncService()

    private let store: ExpenseStore
    private let calendar = CalendarManager.shared

    init(store: ExpenseStore = .shared) { self.store = store }

    struct Outcome: Equatable {
        var created = 0
        var updated = 0
        var removed = 0
        var unchanged = 0
        var failures: [String] = []

        var isEmpty: Bool { created == 0 && updated == 0 && removed == 0 }

        /// A sentence for the status line, rather than four counters nobody reads.
        var summary: String {
            if !failures.isEmpty { return failures[0] }
            if isEmpty { return "Calendar already up to date" }
            var parts: [String] = []
            if created > 0 { parts.append("\(created) added") }
            if updated > 0 { parts.append("\(updated) updated") }
            if removed > 0 { parts.append("\(removed) removed") }
            return parts.joined(separator: " · ")
        }
    }

    /// True when both permissions are in place. The page uses this to explain
    /// why the button is disabled rather than letting it fail silently.
    var canSync: Bool {
        calendar.reminderAuthorizationStatus == .authorized
            && calendar.calendarAuthorizationStatus == .authorized
    }

    var permissionNote: String? {
        if calendar.reminderAuthorizationStatus != .authorized { return "ATLAS needs Reminders access." }
        if calendar.calendarAuthorizationStatus != .authorized { return "ATLAS needs Calendar access." }
        return nil
    }

    /// Pushes every subscription's next due date into Reminders and Calendar.
    ///
    /// Idempotent: a second run over unchanged data reports "already up to date"
    /// and writes nothing, because `plan` compares against what the last sync
    /// recorded.
    func syncAll() -> Outcome {
        var outcome = Outcome()
        if let note = permissionNote {
            outcome.failures.append(note)
            return outcome
        }

        let listId: String
        let calendarId: String
        switch calendar.findOrCreateReminderList(named: BillCalendarSync.listName) {
        case .success(let id): listId = id
        case .failure(let error):
            outcome.failures.append(describe(error)); return outcome
        }
        switch calendar.findOrCreateEventCalendar(named: BillCalendarSync.calendarName) {
        case .success(let id): calendarId = id
        case .failure(let error):
            outcome.failures.append(describe(error)); return outcome
        }

        for subscription in store.subscriptions() {
            let state = store.syncState(subscription.id)
            let action = BillCalendarSync.plan(for: subscription,
                                               reminderId: state?.reminderId ?? "",
                                               eventId: state?.eventId ?? "",
                                               syncedDueOn: state?.dueOn)
            switch action {
            case .upToDate:
                outcome.unchanged += 1

            case .create(let title, let due, let notes):
                write(subscription: subscription, title: title, due: due, notes: notes,
                      listId: listId, calendarId: calendarId,
                      replacing: nil, outcome: &outcome, counting: \.created)

            case .update(let reminderId, let eventId, let title, let due, let notes):
                // Replace rather than edit in place: EventKit will not move a
                // reminder between due dates as cleanly as it will accept a new
                // one, and the old identifiers are known so nothing is orphaned.
                write(subscription: subscription, title: title, due: due, notes: notes,
                      listId: listId, calendarId: calendarId,
                      replacing: (reminderId, eventId), outcome: &outcome, counting: \.updated)

            case .remove(let reminderId, let eventId):
                calendar.deleteReminderIfPresent(id: reminderId)
                calendar.deleteEventIfPresent(id: eventId)
                store.recordSync(subscription.id, reminderId: "", eventId: "",
                                 dueOn: subscription.nextDueOn)
                outcome.removed += 1
            }
        }
        return outcome
    }

    private func write(subscription: Subscription, title: String, due: Date, notes: String,
                       listId: String, calendarId: String,
                       replacing previous: (reminder: String, event: String)?,
                       outcome: inout Outcome,
                       counting keyPath: WritableKeyPath<Outcome, Int>) {
        if let previous {
            calendar.deleteReminderIfPresent(id: previous.reminder)
            calendar.deleteEventIfPresent(id: previous.event)
        }

        var reminderId = ""
        var eventId = ""

        switch calendar.createReminderReturningId(title: title, dueDate: due,
                                                  notes: notes, listId: listId) {
        case .success(let id): reminderId = id
        case .failure(let error): outcome.failures.append(describe(error))
        }
        switch calendar.createAllDayEventReturningId(title: title, on: due,
                                                     notes: notes, calendarId: calendarId) {
        case .success(let id): eventId = id
        case .failure(let error): outcome.failures.append(describe(error))
        }

        if reminderId.isEmpty && eventId.isEmpty { return }
        store.recordSync(subscription.id, reminderId: reminderId, eventId: eventId, dueOn: due)
        outcome[keyPath: keyPath] += 1
    }

    private func describe(_ error: CalendarManager.CalendarWriteError) -> String {
        switch error {
        case .notAuthorized: return "ATLAS does not have calendar access."
        case .noCalendar: return "No writable calendar or reminder list was available."
        case .saveFailed(let detail): return detail
        }
    }
}

/// Offers the infrastructure providers ATLAS already reads as subscriptions.
///
/// Railway, Vercel and Neon report real spend through `InfraSnapshot`. Typing
/// them in by hand would mean maintaining the same numbers twice, so they are
/// pre-filled instead — and because the amount comes from the provider, a
/// silent price rise shows up as a flagged change the next time this runs.
@MainActor
enum InfraPrefill {
    /// Providers with a usable figure that are not already tracked.
    static func candidates(from infra: InfraSnapshot?, store: ExpenseStore) -> [InfraSnapshot.Provider] {
        guard let infra else { return [] }
        let tracked = Set(store.subscriptions().map(\.providerKey).filter { !$0.isEmpty })
        return infra.providers.filter { provider in
            provider.available
                && provider.currentUSD != nil
                && !tracked.contains(key(for: provider))
        }
    }

    /// Adds a provider as a monthly subscription, due at the start of next month.
    @discardableResult
    static func add(_ provider: InfraSnapshot.Provider, store: ExpenseStore,
                    asOf now: Date = Date(), calendar: Calendar = .current) -> Subscription {
        let cents = Int(((provider.currentUSD ?? 0) * 100).rounded())
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let due = calendar.date(byAdding: .month, value: 1, to: startOfMonth) ?? now
        return store.upsert(Subscription(
            name: provider.name,
            amountMinorUnits: cents,
            cadence: .monthly,
            nextDueOn: due,
            category: .infrastructure,
            source: .infrastructure,
            providerKey: key(for: provider),
            notes: provider.note ?? ""
        ))
    }

    /// Re-reads the current figure for every provider-backed subscription, so a
    /// change in what a provider charges surfaces as a flagged price change.
    @discardableResult
    static func refreshAmounts(from infra: InfraSnapshot?, store: ExpenseStore) -> Int {
        guard let infra else { return 0 }
        var changed = 0
        for provider in infra.providers where provider.available {
            guard let usd = provider.currentUSD,
                  var tracked = store.subscription(providerKey: key(for: provider)) else { continue }
            let cents = Int((usd * 100).rounded())
            guard cents != tracked.amountMinorUnits else { continue }
            tracked.amountMinorUnits = cents
            store.upsert(tracked)   // records the previous price as a change
            changed += 1
        }
        return changed
    }

    static func key(for provider: InfraSnapshot.Provider) -> String {
        "infra:" + provider.name.lowercased()
    }
}
