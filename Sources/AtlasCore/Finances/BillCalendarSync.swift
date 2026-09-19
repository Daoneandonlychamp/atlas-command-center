import Foundation

/// Puts bill due dates into Reminders and Calendar.
///
/// SAFETY — this is the only part of the finances feature that touches data
/// outside ATLAS, so the rules are narrow and enforced here rather than left to
/// callers:
///
///   * It writes only into containers ATLAS created and named itself
///     (`Self.listName` / `Self.calendarName`). It never writes into a list or
///     calendar the user already had.
///   * It updates the reminder and event it made last time, tracked by
///     identifier in `ExpenseStore`, so re-syncing corrects rather than
///     duplicates.
///   * It is explicit. Nothing here runs on a timer or on save; the Finances
///     page calls `sync` when the person asks for it.
///   * `plan(for:)` is pure and decides everything. The write step just carries
///     the plan out, which is what makes this testable without EventKit.
public enum BillCalendarSync {
    /// The names ATLAS owns. Anything else is left alone.
    public static let listName = "ATLAS Bills"
    public static let calendarName = "ATLAS Bills"

    /// What a sync would do to one subscription. Pure — no EventKit involved.
    public enum Action: Equatable, Sendable {
        /// Nothing changed since the last sync.
        case upToDate
        /// No reminder or event exists yet for this due date.
        case create(title: String, due: Date, notes: String)
        /// One exists but the date or amount moved.
        case update(reminderId: String, eventId: String, title: String, due: Date, notes: String)
        /// The subscription was archived, so its bill should come off the calendar.
        case remove(reminderId: String, eventId: String)
    }

    /// Decides what should happen to a subscription's calendar entries.
    ///
    /// `syncedDueOn` is what the last sync wrote. When it still matches, there is
    /// nothing to do — which is what keeps repeat syncs from churning the user's
    /// Reminders.
    public static func plan(for subscription: Subscription,
                            reminderId: String = "",
                            eventId: String = "",
                            syncedDueOn: Date? = nil,
                            calendar: Calendar = .current) -> Action {
        let hasEntries = !reminderId.isEmpty || !eventId.isEmpty

        guard subscription.isActive else {
            return hasEntries ? .remove(reminderId: reminderId, eventId: eventId) : .upToDate
        }

        let title = self.title(for: subscription)
        let notes = self.notes(for: subscription)
        let due = subscription.nextDueOn

        guard hasEntries else {
            return .create(title: title, due: due, notes: notes)
        }
        if let syncedDueOn, calendar.isDate(syncedDueOn, inSameDayAs: due) {
            return .upToDate
        }
        return .update(reminderId: reminderId, eventId: eventId, title: title, due: due, notes: notes)
    }

    /// "Adobe CC — $59.99". The amount is in the title because a Reminders list
    /// read on a phone shows the title and very little else.
    public static func title(for subscription: Subscription) -> String {
        "\(subscription.name) — \(money(subscription.amountMinorUnits, subscription.currency))"
    }

    public static func notes(for subscription: Subscription) -> String {
        var lines = ["\(subscription.cadence.title) · \(subscription.category.title)"]
        if let delta = subscription.priceDeltaMinorUnits, delta != 0 {
            let direction = delta > 0 ? "up" : "down"
            lines.append("Price \(direction) \(money(abs(delta), subscription.currency)) since last time.")
        }
        if !subscription.notes.isEmpty { lines.append(subscription.notes) }
        lines.append("Tracked by ATLAS.")
        return lines.joined(separator: "\n")
    }

    /// Minor units to a readable amount. Whole units unless there are real cents.
    public static func money(_ minorUnits: Int, _ currency: String = "usd") -> String {
        let symbol = currency.lowercased() == "usd" ? "$" : currency.uppercased() + " "
        let negative = minorUnits < 0
        let abs = Swift.abs(minorUnits)
        let whole = abs / 100
        let cents = abs % 100
        var text = symbol + whole.formatted(.number.grouping(.automatic))
        if cents != 0 { text += String(format: ".%02d", cents) }
        return negative ? "-" + text : text
    }
}
