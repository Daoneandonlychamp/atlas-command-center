import Foundation

// MARK: - Actions

/// The complete set of things `finances.html` is allowed to ask for.
///
/// Anything that does not decode into one of these never reaches the store, so
/// the page's reach is fixed at compile time rather than by whatever its
/// JavaScript happens to send.
public enum FinanceActionKind: String, Decodable, CaseIterable, Sendable {
    case load
    case saveSubscription
    case deleteSubscription
    case markPaid
    case acknowledgePrice
    case saveExpense
    case deleteExpense
    case saveCreditAccount
    case saveProfile
    case setStrategy
    case trackProvider
    case syncCalendar
    case parseInvoices
    case importInvoices
}

/// One decoded message from the page.
///
/// Every field is optional because one struct covers both editors; which fields
/// have to be present is decided by `FinanceActionValidator`, per action, rather
/// than by the shape of the type.
public struct FinanceAction: Decodable, Sendable {
    public let action: FinanceActionKind
    public let id: String?

    // Shared by both editors.
    public let name: String?
    /// Money arrives as the text the user typed. It is parsed once, here, through
    /// `Money.minorUnits` — the page never sends a number, because a JSON float
    /// is exactly the `Double` rounding this codebase avoids.
    public let amount: String?
    public let currency: String?
    public let category: String?
    public let notes: String?

    // Subscription only.
    public let cadence: String?
    public let nextDueOn: String?
    public let isActive: Bool?
    public let scheduledAmount: String?
    public let scheduledFrom: String?

    // Expense only.
    public let spentOn: String?

    // Credit account only. Every money field is text, for the same reason as
    // `amount`.
    public let balance: String?
    public let limit: String?
    /// A percentage as typed — "24.99" — parsed to basis points.
    public let apr: String?
    public let minimum: String?
    public let planned: String?
    public let paymentDueOn: String?
    public let statementClosesOn: String?
    public let openedOn: String?
    public let autopayEnabled: Bool?

    // Planning setup only.
    public let openingCash: String?
    public let recurringIncome: String?
    public let nextIncomeOn: String?
    public let monthlyDebtBudget: String?
    public let buffer: String?

    // Debt payoff only.
    public let strategy: String?

    /// Which infrastructure provider to start tracking, by name.
    public let provider: String?

    /// Invoice import: the pasted text to parse, then the ids the user kept.
    /// The rows themselves never make the round trip — Swift holds what it
    /// parsed, so the page cannot hand back an amount it edited.
    public let pasted: String?
    public let include: [String]?
}

/// Why a write was refused, in words the page can show as-is.
public enum FinanceRefusal: Error, Equatable, Sendable {
    case missing(String)
    case badAmount(String)
    case badDate(String)
    case unknownValue(String, String)
    case notFound(String)

    public var message: String {
        switch self {
        case .missing(let field):
            return "\(field) is required."
        case .badAmount(let text):
            return "\"\(text)\" is not an amount. Use digits and at most two decimals."
        case .badDate(let text):
            return "\"\(text)\" is not a date."
        case .unknownValue(let field, let value):
            return "\(value) is not a valid \(field)."
        case .notFound(let what):
            return "That \(what) no longer exists."
        }
    }
}

// MARK: - Validation

/// Turns a decoded action into a record, or says why it cannot.
///
/// Separate from the bridge so the rules can be tested without a web view, and
/// so every field is checked in one place rather than at each call site. The
/// page runs its own checks for the person typing; these are the ones that
/// decide whether a row is written.
public enum FinanceActionValidator {

    public static func subscription(from action: FinanceAction,
                                    existing: Subscription?) -> Result<Subscription, FinanceRefusal> {
        guard let name = action.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return .failure(.missing("Name")) }

        let amountText = action.amount ?? ""
        guard let amount = Money.minorUnits(amountText) else {
            return .failure(.badAmount(amountText))
        }

        let cadenceText = action.cadence ?? BillingCadence.monthly.rawValue
        guard let cadence = BillingCadence(rawValue: cadenceText) else {
            return .failure(.unknownValue("cadence", cadenceText))
        }

        let categoryText = action.category ?? ExpenseCategory.software.rawValue
        guard let category = ExpenseCategory(rawValue: categoryText) else {
            return .failure(.unknownValue("category", categoryText))
        }

        let dueText = action.nextDueOn ?? ""
        guard let nextDueOn = FinanceDate.parse(dueText) else {
            return .failure(.badDate(dueText))
        }

        // A scheduled rise is all-or-nothing: an amount without a date, or a
        // date without an amount, is a half-entered change that would forecast
        // wrongly, so it is refused rather than half-applied.
        var scheduledAmount: Int?
        var scheduledFrom: Date?
        let hasScheduledAmount = !(action.scheduledAmount ?? "").isEmpty
        let hasScheduledFrom = !(action.scheduledFrom ?? "").isEmpty
        if hasScheduledAmount || hasScheduledFrom {
            guard hasScheduledAmount else { return .failure(.missing("Scheduled amount")) }
            guard hasScheduledFrom else { return .failure(.missing("Scheduled date")) }
            guard let parsed = Money.minorUnits(action.scheduledAmount ?? "") else {
                return .failure(.badAmount(action.scheduledAmount ?? ""))
            }
            guard let from = FinanceDate.parse(action.scheduledFrom ?? "") else {
                return .failure(.badDate(action.scheduledFrom ?? ""))
            }
            scheduledAmount = parsed
            scheduledFrom = from
        }

        // Everything the page does not own — provenance, the price-change
        // history, when the row was created — is carried across from the stored
        // record rather than rebuilt from the form.
        var record = existing ?? Subscription(name: name)
        record.name = name
        record.amountMinorUnits = amount
        if let currency = action.currency, !currency.isEmpty { record.currency = currency }
        record.cadence = cadence
        record.nextDueOn = nextDueOn
        record.category = category
        record.notes = action.notes ?? record.notes
        record.isActive = action.isActive ?? record.isActive
        record.scheduledAmountMinorUnits = scheduledAmount
        record.scheduledFrom = scheduledFrom
        record.updatedAt = Date()
        return .success(record)
    }

    public static func expense(from action: FinanceAction,
                               existing: Expense?) -> Result<Expense, FinanceRefusal> {
        guard let name = action.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return .failure(.missing("Name")) }

        let amountText = action.amount ?? ""
        guard let amount = Money.minorUnits(amountText) else {
            return .failure(.badAmount(amountText))
        }

        let categoryText = action.category ?? ExpenseCategory.other.rawValue
        guard let category = ExpenseCategory(rawValue: categoryText) else {
            return .failure(.unknownValue("category", categoryText))
        }

        let spentText = action.spentOn ?? ""
        guard let spentOn = FinanceDate.parse(spentText) else {
            return .failure(.badDate(spentText))
        }

        var record = existing ?? Expense(name: name)
        record.name = name
        record.amountMinorUnits = amount
        if let currency = action.currency, !currency.isEmpty { record.currency = currency }
        record.category = category
        record.spentOn = spentOn
        record.notes = action.notes ?? record.notes
        record.updatedAt = Date()
        return .success(record)
    }

    public static func creditAccount(from action: FinanceAction,
                                     existing: CreditAccount?) -> Result<CreditAccount, FinanceRefusal> {
        guard let name = action.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return .failure(.missing("Account nickname")) }

        let balance = try? amount(action.balance, "Balance").get()
        guard let balance else { return .failure(.badAmount(action.balance ?? "")) }
        let limit = try? amount(action.limit, "Credit limit").get()
        guard let limit else { return .failure(.badAmount(action.limit ?? "")) }
        let minimum = try? amount(action.minimum, "Minimum payment").get()
        guard let minimum else { return .failure(.badAmount(action.minimum ?? "")) }
        let planned = try? amount(action.planned, "Planned payment").get()
        guard let planned else { return .failure(.badAmount(action.planned ?? "")) }

        // An APR is a two-decimal percentage, so the cents parser converts it to
        // basis points exactly: "24.99" -> 2499. Going through Double here would
        // put the same rounding into the interest estimate that it puts into a
        // balance.
        let aprText = (action.apr ?? "").trimmingCharacters(in: .whitespaces)
        var aprBasisPoints = 0
        if !aprText.isEmpty {
            guard let parsed = Money.minorUnits(aprText), parsed >= 0 else {
                return .failure(.badAmount(aprText))
            }
            aprBasisPoints = parsed
        }

        guard let due = FinanceDate.parse(action.paymentDueOn ?? "") else {
            return .failure(.badDate(action.paymentDueOn ?? ""))
        }
        guard let closes = FinanceDate.parse(action.statementClosesOn ?? "") else {
            return .failure(.badDate(action.statementClosesOn ?? ""))
        }
        let openedText = action.openedOn ?? ""
        let opened = openedText.isEmpty ? (existing?.openedOn ?? Date())
                                        : FinanceDate.parse(openedText)
        guard let opened else { return .failure(.badDate(openedText)) }

        var record = existing ?? CreditAccount(name: name, paymentDueOn: due,
                                               statementClosesOn: closes)
        record.name = name
        record.balanceMinorUnits = balance
        record.creditLimitMinorUnits = limit
        record.aprBasisPoints = aprBasisPoints
        record.minimumPaymentMinorUnits = minimum
        record.plannedPaymentMinorUnits = planned
        record.paymentDueOn = due
        record.statementClosesOn = closes
        record.openedOn = opened
        record.autopayEnabled = action.autopayEnabled ?? record.autopayEnabled
        record.isActive = action.isActive ?? record.isActive
        record.notes = action.notes ?? record.notes
        record.updatedAt = Date()
        return .success(record)
    }

    public static func profile(from action: FinanceAction,
                               existing: FinanceProfile) -> Result<FinanceProfile, FinanceRefusal> {
        let cash = try? amount(action.openingCash, "Cash available").get()
        guard let cash else { return .failure(.badAmount(action.openingCash ?? "")) }
        let income = try? amount(action.recurringIncome, "Recurring income").get()
        guard let income else { return .failure(.badAmount(action.recurringIncome ?? "")) }
        let budget = try? amount(action.monthlyDebtBudget, "Debt budget").get()
        guard let budget else { return .failure(.badAmount(action.monthlyDebtBudget ?? "")) }
        let buffer = try? amount(action.buffer, "Buffer").get()
        guard let buffer else { return .failure(.badAmount(action.buffer ?? "")) }

        guard let nextIncome = FinanceDate.parse(action.nextIncomeOn ?? "") else {
            return .failure(.badDate(action.nextIncomeOn ?? ""))
        }

        var record = existing
        record.openingCashMinorUnits = cash
        record.recurringIncomeMinorUnits = income
        record.nextIncomeOn = nextIncome
        record.monthlyDebtBudgetMinorUnits = budget
        record.bufferMinorUnits = buffer
        record.updatedAt = Date()
        return .success(record)
    }

    /// A planning figure: blank means zero, but nonsense is refused rather than
    /// quietly becoming zero. A mistyped balance that lands as $0 reads as a
    /// paid-off card and takes the utilization figure with it.
    private static func amount(_ text: String?,
                               _ field: String) -> Result<Int, FinanceRefusal> {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .success(0) }
        guard let parsed = Money.minorUnits(trimmed) else {
            return .failure(.badAmount(trimmed))
        }
        guard parsed >= 0 else { return .failure(.missing(field)) }
        return .success(parsed)
    }
}

/// Dates cross the bridge as `yyyy-MM-dd` and nothing else.
///
/// A fixed format with a fixed locale, because `<input type="date">` always
/// produces this shape and a user's regional format arriving here would parse
/// 03/09 as either March or September depending on the machine.
public enum FinanceDate {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func parse(_ text: String) -> Date? {
        formatter.date(from: text)
    }

    public static func string(_ date: Date) -> String {
        formatter.string(from: date)
    }
}
