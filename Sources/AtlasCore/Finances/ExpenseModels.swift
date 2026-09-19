import Foundation

/// Money going out: subscriptions you pay for and one-off expenses.
///
/// The existing `FinanceReader` covers money coming in — Stripe charges, your
/// customers' subscriptions, infrastructure spend read from provider APIs.
/// Nothing here overlaps with that. These are records you enter, held locally.
///
/// Amounts are whole minor units (cents) as `Int`, matching `FinanceSnapshot`
/// and for the same reason: a monthly total built out of `Double` drifts.

// MARK: - Cadence

/// How often a subscription renews.
public enum BillingCadence: String, Codable, CaseIterable, Sendable {
    case weekly
    case fortnightly
    case monthly
    case quarterly
    case semiannual
    case yearly

    public var title: String {
        switch self {
        case .weekly: return "Weekly"
        case .fortnightly: return "Every 2 weeks"
        case .monthly: return "Monthly"
        case .quarterly: return "Quarterly"
        case .semiannual: return "Every 6 months"
        case .yearly: return "Yearly"
        }
    }

    /// How many times this renews in a year. Used to normalise everything to a
    /// comparable monthly figure.
    public var timesPerYear: Double {
        switch self {
        case .weekly: return 52
        case .fortnightly: return 26
        case .monthly: return 12
        case .quarterly: return 4
        case .semiannual: return 2
        case .yearly: return 1
        }
    }

    /// The step used to walk a due date forward.
    var component: (Calendar.Component, Int) {
        switch self {
        case .weekly: return (.day, 7)
        case .fortnightly: return (.day, 14)
        case .monthly: return (.month, 1)
        case .quarterly: return (.month, 3)
        case .semiannual: return (.month, 6)
        case .yearly: return (.year, 1)
        }
    }
}

/// What the money went on. Deliberately short — a long list nobody maintains is
/// worse than a handful that get used.
public enum ExpenseCategory: String, Codable, CaseIterable, Sendable {
    case software
    case infrastructure
    case hardware
    case services
    case marketing
    case office
    case personal
    case other

    public var title: String {
        switch self {
        case .software: return "Software"
        case .infrastructure: return "Infrastructure"
        case .hardware: return "Hardware"
        case .services: return "Services"
        case .marketing: return "Marketing"
        case .office: return "Office"
        case .personal: return "Personal"
        case .other: return "Other"
        }
    }
}

/// Where a record came from. A subscription ATLAS pre-filled from a provider API
/// is not the same as one you typed, and the difference matters when its price
/// changes underneath you.
public enum ExpenseSource: String, Codable, CaseIterable, Sendable {
    case manual
    /// Pre-filled from `infra.json` — Railway, Vercel, Neon.
    case infrastructure

    public var title: String {
        switch self {
        case .manual: return "Entered by hand"
        case .infrastructure: return "Read from the provider"
        }
    }
}

// MARK: - Subscription

public struct Subscription: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var amountMinorUnits: Int
    public var currency: String
    public var cadence: BillingCadence
    /// The next date money leaves. Rolled forward by `BillSchedule`.
    public var nextDueOn: Date
    public var category: ExpenseCategory
    public var source: ExpenseSource
    /// Provider key for pre-filled rows ("railway"), so a refresh finds it again.
    public var providerKey: String
    public var notes: String
    public var isActive: Bool
    /// The last amount seen before the current one, when it changed. Non-nil
    /// means a price rise or drop nobody was told about.
    public var previousAmountMinorUnits: Int?
    public var priceChangedAt: Date?
    /// A price rise you already know about — "Google One goes to $19.99 on
    /// 10 October". Recorded up front so the forecast is right before it lands,
    /// and so it does not arrive as a surprise the way an unannounced rise does.
    public var scheduledAmountMinorUnits: Int?
    public var scheduledFrom: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                name: String,
                amountMinorUnits: Int = 0,
                currency: String = "usd",
                cadence: BillingCadence = .monthly,
                nextDueOn: Date = Date(),
                category: ExpenseCategory = .software,
                source: ExpenseSource = .manual,
                providerKey: String = "",
                notes: String = "",
                isActive: Bool = true,
                previousAmountMinorUnits: Int? = nil,
                priceChangedAt: Date? = nil,
                scheduledAmountMinorUnits: Int? = nil,
                scheduledFrom: Date? = nil,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.amountMinorUnits = amountMinorUnits
        self.currency = currency
        self.cadence = cadence
        self.nextDueOn = nextDueOn
        self.category = category
        self.source = source
        self.providerKey = providerKey
        self.notes = notes
        self.isActive = isActive
        self.previousAmountMinorUnits = previousAmountMinorUnits
        self.priceChangedAt = priceChangedAt
        self.scheduledAmountMinorUnits = scheduledAmountMinorUnits
        self.scheduledFrom = scheduledFrom
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// What this costs on a given day, honouring a scheduled change.
    ///
    /// Every total goes through here rather than reading `amountMinorUnits`
    /// directly, so a bill that rises next month is costed correctly in the
    /// month it rises rather than at today's price.
    public func amountMinorUnits(on date: Date, calendar: Calendar = .current) -> Int {
        guard let scheduled = scheduledAmountMinorUnits, let from = scheduledFrom else {
            return amountMinorUnits
        }
        return calendar.startOfDay(for: date) >= calendar.startOfDay(for: from)
            ? scheduled : amountMinorUnits
    }

    /// This subscription's cost normalised to one month, so a yearly plan and a
    /// weekly one can sit in the same total.
    public var monthlyEquivalentMinorUnits: Int {
        Int((Double(amountMinorUnits) * cadence.timesPerYear / 12).rounded())
    }

    /// The monthly figure once every scheduled change has taken effect.
    public var futureMonthlyEquivalentMinorUnits: Int {
        let amount = scheduledAmountMinorUnits ?? amountMinorUnits
        return Int((Double(amount) * cadence.timesPerYear / 12).rounded())
    }

    public var yearlyMinorUnits: Int {
        Int((Double(amountMinorUnits) * cadence.timesPerYear).rounded())
    }

    /// A price change that is coming but has not landed yet.
    public func hasPendingPriceChange(asOf now: Date = Date(),
                                      calendar: Calendar = .current) -> Bool {
        guard let from = scheduledFrom, scheduledAmountMinorUnits != nil else { return false }
        return calendar.startOfDay(for: from) > calendar.startOfDay(for: now)
    }

    /// Signed difference the scheduled change will make, or nil if none is set.
    public var scheduledDeltaMinorUnits: Int? {
        guard let scheduled = scheduledAmountMinorUnits else { return nil }
        return scheduled - amountMinorUnits
    }

    /// True once the scheduled date has arrived and the new price should simply
    /// become the price.
    public func scheduledChangeIsDue(asOf now: Date = Date(),
                                     calendar: Calendar = .current) -> Bool {
        guard let from = scheduledFrom, scheduledAmountMinorUnits != nil else { return false }
        return calendar.startOfDay(for: now) >= calendar.startOfDay(for: from)
    }

    /// Set when the amount moved and nobody acknowledged it yet.
    public var hasUnacknowledgedPriceChange: Bool {
        previousAmountMinorUnits != nil
    }

    /// Signed difference against the previous price, or nil if it never moved.
    public var priceDeltaMinorUnits: Int? {
        guard let previous = previousAmountMinorUnits else { return nil }
        return amountMinorUnits - previous
    }
}

// MARK: - Expense

/// A one-off payment. Recurring money is a `Subscription`; this is everything
/// else that left the account.
public struct Expense: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var amountMinorUnits: Int
    public var currency: String
    public var category: ExpenseCategory
    public var spentOn: Date
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                name: String,
                amountMinorUnits: Int = 0,
                currency: String = "usd",
                category: ExpenseCategory = .other,
                spentOn: Date = Date(),
                notes: String = "",
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.amountMinorUnits = amountMinorUnits
        self.currency = currency
        self.category = category
        self.spentOn = spentOn
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Scheduling

/// Works out when a subscription is next due.
///
/// Pure date arithmetic, kept out of the store so it can be tested without a
/// database and reasoned about on its own. Everything is done in the supplied
/// calendar, so a month step lands on the same day-of-month rather than 30 days
/// later, and the end-of-month cases behave the way a bill actually does.
public enum BillSchedule {
    /// Rolls `date` forward by one cadence step.
    public static func advance(_ date: Date, by cadence: BillingCadence,
                               calendar: Calendar = .current) -> Date {
        let (component, amount) = cadence.component
        return calendar.date(byAdding: component, value: amount, to: date) ?? date
    }

    /// The next due date at or after `now`, walking forward in whole cadence
    /// steps from `anchor`.
    ///
    /// A subscription left untouched for months should show its *next* payment,
    /// not the one that was missed in March — but it must not skip past a date
    /// that is due today.
    public static func nextDue(from anchor: Date, cadence: BillingCadence,
                               asOf now: Date = Date(),
                               calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        var due = anchor
        // Guard the loop: a cadence that somehow fails to advance would spin.
        var steps = 0
        while calendar.startOfDay(for: due) < today && steps < 1200 {
            let next = advance(due, by: cadence, calendar: calendar)
            if calendar.startOfDay(for: next) <= calendar.startOfDay(for: due) { break }
            due = next
            steps += 1
        }
        return due
    }

    /// Whole days from `now` until `due`. Negative when it is already past.
    public static func daysUntil(_ due: Date, asOf now: Date = Date(),
                                 calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: now)
        let to = calendar.startOfDay(for: due)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// Every due date in `[start, end)`, for laying bills onto a month.
    public static func occurrences(of subscription: Subscription,
                                   from start: Date, to end: Date,
                                   calendar: Calendar = .current) -> [Date] {
        guard subscription.isActive, start < end else { return [] }
        var out: [Date] = []
        var due = nextDue(from: subscription.nextDueOn, cadence: subscription.cadence,
                          asOf: start, calendar: calendar)
        var steps = 0
        while due < end && steps < 400 {
            if due >= start { out.append(due) }
            let next = advance(due, by: subscription.cadence, calendar: calendar)
            if next <= due { break }
            due = next
            steps += 1
        }
        return out
    }
}

// MARK: - Rollup

/// One month of money, both directions.
public struct CashFlowMonth: Codable, Equatable, Sendable {
    /// First moment of the month this describes.
    public var month: Date
    /// Committed outgoings: subscriptions due in the month plus one-off spend.
    public var subscriptionsMinorUnits: Int
    public var expensesMinorUnits: Int
    /// Revenue, when a Stripe snapshot is available. Nil when it is not, which
    /// is different from zero and is shown as such.
    public var incomeMinorUnits: Int?

    public init(month: Date,
                subscriptionsMinorUnits: Int = 0,
                expensesMinorUnits: Int = 0,
                incomeMinorUnits: Int? = nil) {
        self.month = month
        self.subscriptionsMinorUnits = subscriptionsMinorUnits
        self.expensesMinorUnits = expensesMinorUnits
        self.incomeMinorUnits = incomeMinorUnits
    }

    public var outMinorUnits: Int { subscriptionsMinorUnits + expensesMinorUnits }

    /// Income minus outgoings, or nil when there is no income figure to net
    /// against — an invented zero would read as "you broke even".
    public var netMinorUnits: Int? {
        guard let incomeMinorUnits else { return nil }
        return incomeMinorUnits - outMinorUnits
    }
}

/// What the Money-out tab shows at the top.
public struct SpendSummary: Codable, Equatable, Sendable {
    public var activeSubscriptions: Int
    public var monthlyCommittedMinorUnits: Int
    public var yearlyCommittedMinorUnits: Int
    public var dueSoonCount: Int
    public var dueSoonMinorUnits: Int
    public var overdueCount: Int
    public var priceChangeCount: Int
    /// The monthly figure once every scheduled rise has taken effect, and how
    /// many are waiting. Equal to the current figure when nothing is scheduled.
    public var futureMonthlyMinorUnits: Int
    public var pendingPriceChangeCount: Int

    public init(activeSubscriptions: Int = 0,
                monthlyCommittedMinorUnits: Int = 0,
                yearlyCommittedMinorUnits: Int = 0,
                dueSoonCount: Int = 0,
                dueSoonMinorUnits: Int = 0,
                overdueCount: Int = 0,
                priceChangeCount: Int = 0,
                futureMonthlyMinorUnits: Int = 0,
                pendingPriceChangeCount: Int = 0) {
        self.activeSubscriptions = activeSubscriptions
        self.monthlyCommittedMinorUnits = monthlyCommittedMinorUnits
        self.yearlyCommittedMinorUnits = yearlyCommittedMinorUnits
        self.dueSoonCount = dueSoonCount
        self.dueSoonMinorUnits = dueSoonMinorUnits
        self.overdueCount = overdueCount
        self.priceChangeCount = priceChangeCount
        self.futureMonthlyMinorUnits = futureMonthlyMinorUnits
        self.pendingPriceChangeCount = pendingPriceChangeCount
    }
}
