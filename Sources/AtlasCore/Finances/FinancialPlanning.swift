import Foundation

// MARK: - Credit accounts

/// The small, non-sensitive slice of a revolving account ATLAS needs to plan.
/// No account number, credentials, report, or identity data is stored.
public struct CreditAccount: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var balanceMinorUnits: Int
    public var creditLimitMinorUnits: Int
    /// 2,499 means 24.99%. Keeping APR as basis points avoids persisted floats.
    public var aprBasisPoints: Int
    public var minimumPaymentMinorUnits: Int
    public var plannedPaymentMinorUnits: Int
    public var paymentDueOn: Date
    public var statementClosesOn: Date
    public var autopayEnabled: Bool
    public var openedOn: Date
    public var isActive: Bool
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                name: String,
                balanceMinorUnits: Int = 0,
                creditLimitMinorUnits: Int = 0,
                aprBasisPoints: Int = 0,
                minimumPaymentMinorUnits: Int = 0,
                plannedPaymentMinorUnits: Int = 0,
                paymentDueOn: Date = Date(),
                statementClosesOn: Date = Date(),
                autopayEnabled: Bool = false,
                openedOn: Date = Date(),
                isActive: Bool = true,
                notes: String = "",
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.balanceMinorUnits = max(0, balanceMinorUnits)
        self.creditLimitMinorUnits = max(0, creditLimitMinorUnits)
        self.aprBasisPoints = max(0, aprBasisPoints)
        self.minimumPaymentMinorUnits = max(0, minimumPaymentMinorUnits)
        self.plannedPaymentMinorUnits = max(0, plannedPaymentMinorUnits)
        self.paymentDueOn = paymentDueOn
        self.statementClosesOn = statementClosesOn
        self.autopayEnabled = autopayEnabled
        self.openedOn = openedOn
        self.isActive = isActive
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var availableCreditMinorUnits: Int {
        max(0, creditLimitMinorUnits - balanceMinorUnits)
    }

    /// Basis points of utilization: 3,000 is 30%. Nil means there is no limit
    /// to divide by, not that utilization is zero.
    public var utilizationBasisPoints: Int? {
        guard creditLimitMinorUnits > 0 else { return nil }
        return Int((Double(balanceMinorUnits) / Double(creditLimitMinorUnits) * 10_000).rounded())
    }

    public var projectedBalanceMinorUnits: Int {
        max(0, balanceMinorUnits - plannedPaymentMinorUnits)
    }

    public var projectedUtilizationBasisPoints: Int? {
        guard creditLimitMinorUnits > 0 else { return nil }
        return Int((Double(projectedBalanceMinorUnits) / Double(creditLimitMinorUnits) * 10_000).rounded())
    }

    public func paymentToReach(utilizationPercent target: Int) -> Int? {
        guard creditLimitMinorUnits > 0 else { return nil }
        let safeTarget = min(100, max(0, target))
        let targetBalance = creditLimitMinorUnits * safeTarget / 100
        return max(0, balanceMinorUnits - targetBalance)
    }
}

public struct CreditSummary: Codable, Equatable, Sendable {
    public var totalBalanceMinorUnits: Int
    public var totalLimitMinorUnits: Int
    public var plannedPaymentMinorUnits: Int

    public init(accounts: [CreditAccount]) {
        let active = accounts.filter(\.isActive)
        totalBalanceMinorUnits = active.reduce(0) { $0 + $1.balanceMinorUnits }
        totalLimitMinorUnits = active.reduce(0) { $0 + $1.creditLimitMinorUnits }
        plannedPaymentMinorUnits = active.reduce(0) { $0 + min($1.balanceMinorUnits, $1.plannedPaymentMinorUnits) }
    }

    public var utilizationBasisPoints: Int? {
        guard totalLimitMinorUnits > 0 else { return nil }
        return Int((Double(totalBalanceMinorUnits) / Double(totalLimitMinorUnits) * 10_000).rounded())
    }

    public var projectedUtilizationBasisPoints: Int? {
        guard totalLimitMinorUnits > 0 else { return nil }
        let balance = max(0, totalBalanceMinorUnits - plannedPaymentMinorUnits)
        return Int((Double(balance) / Double(totalLimitMinorUnits) * 10_000).rounded())
    }

    public func paymentToReach(utilizationPercent target: Int) -> Int? {
        guard totalLimitMinorUnits > 0 else { return nil }
        let safeTarget = min(100, max(0, target))
        return max(0, totalBalanceMinorUnits - totalLimitMinorUnits * safeTarget / 100)
    }
}

// MARK: - Finance profile

/// User-entered planning assumptions. The Stripe snapshot is intentionally not
/// used as recurring income because its reporting window may not be a month.
public struct FinanceProfile: Codable, Equatable, Sendable {
    public var openingCashMinorUnits: Int
    public var recurringIncomeMinorUnits: Int
    public var nextIncomeOn: Date
    public var monthlyDebtBudgetMinorUnits: Int
    public var bufferMinorUnits: Int
    public var updatedAt: Date

    public init(openingCashMinorUnits: Int = 0,
                recurringIncomeMinorUnits: Int = 0,
                nextIncomeOn: Date = Date(),
                monthlyDebtBudgetMinorUnits: Int = 0,
                bufferMinorUnits: Int = 0,
                updatedAt: Date = Date()) {
        self.openingCashMinorUnits = max(0, openingCashMinorUnits)
        self.recurringIncomeMinorUnits = max(0, recurringIncomeMinorUnits)
        self.nextIncomeOn = nextIncomeOn
        self.monthlyDebtBudgetMinorUnits = max(0, monthlyDebtBudgetMinorUnits)
        self.bufferMinorUnits = max(0, bufferMinorUnits)
        self.updatedAt = updatedAt
    }

    public var isConfigured: Bool {
        openingCashMinorUnits > 0 || recurringIncomeMinorUnits > 0 || monthlyDebtBudgetMinorUnits > 0
    }
}

// MARK: - Debt payoff

public enum DebtPayoffStrategy: String, Codable, CaseIterable, Sendable {
    case avalanche
    case snowball

    public var title: String { self == .avalanche ? "Avalanche" : "Snowball" }
}

public struct DebtPaymentAllocation: Codable, Identifiable, Equatable, Sendable {
    public var id: String { accountID }
    public let accountID: String
    public let accountName: String
    public let amountMinorUnits: Int
}

public struct DebtPayoffPlan: Codable, Equatable, Sendable {
    public let strategy: DebtPayoffStrategy
    public let monthlyBudgetMinorUnits: Int
    public let minimumsMinorUnits: Int
    public let firstMonth: [DebtPaymentAllocation]
    public let payoffMonths: Int?
    public let interestMinorUnits: Int?
    public let interestSavedMinorUnits: Int?

    public var budgetCoversMinimums: Bool { monthlyBudgetMinorUnits >= minimumsMinorUnits }
}

public enum DebtPlanner {
    private struct WorkingAccount {
        let source: CreditAccount
        var balance: Int
    }

    public static func plan(accounts: [CreditAccount], monthlyBudgetMinorUnits: Int,
                            strategy: DebtPayoffStrategy) -> DebtPayoffPlan {
        let active = accounts.filter { $0.isActive && $0.balanceMinorUnits > 0 }
        let minimums = active.reduce(0) { $0 + min($1.balanceMinorUnits, $1.minimumPaymentMinorUnits) }
        let budget = max(0, monthlyBudgetMinorUnits)
        let first = allocate(accounts: active.map { WorkingAccount(source: $0, balance: $0.balanceMinorUnits) },
                             budget: budget, strategy: strategy)

        guard !active.isEmpty else {
            return DebtPayoffPlan(strategy: strategy, monthlyBudgetMinorUnits: budget,
                                  minimumsMinorUnits: 0, firstMonth: [], payoffMonths: 0,
                                  interestMinorUnits: 0, interestSavedMinorUnits: 0)
        }
        guard budget >= minimums, budget > 0 else {
            return DebtPayoffPlan(strategy: strategy, monthlyBudgetMinorUnits: budget,
                                  minimumsMinorUnits: minimums, firstMonth: first,
                                  payoffMonths: nil, interestMinorUnits: nil,
                                  interestSavedMinorUnits: nil)
        }

        let result = simulate(accounts: active, budget: budget, strategy: strategy)
        let baseline = minimums > 0
            ? simulate(accounts: active, budget: minimums, strategy: strategy)
            : nil
        let saved: Int?
        if let interest = result?.interest, let baselineInterest = baseline?.interest {
            saved = max(0, baselineInterest - interest)
        } else {
            saved = nil
        }
        return DebtPayoffPlan(strategy: strategy, monthlyBudgetMinorUnits: budget,
                              minimumsMinorUnits: minimums, firstMonth: first,
                              payoffMonths: result?.months, interestMinorUnits: result?.interest,
                              interestSavedMinorUnits: saved)
    }

    private static func simulate(accounts: [CreditAccount], budget: Int,
                                 strategy: DebtPayoffStrategy) -> (months: Int, interest: Int)? {
        var working = accounts.map { WorkingAccount(source: $0, balance: $0.balanceMinorUnits) }
        var interestTotal = 0
        for month in 1...600 {
            for index in working.indices where working[index].balance > 0 {
                let annual = working[index].source.aprBasisPoints
                let interest = Int((Double(working[index].balance) * Double(annual) / 1_200_000).rounded())
                working[index].balance += max(0, interest)
                interestTotal += max(0, interest)
            }
            let payments = allocate(accounts: working, budget: budget, strategy: strategy)
            for payment in payments {
                guard let index = working.firstIndex(where: { $0.source.id == payment.accountID }) else { continue }
                working[index].balance = max(0, working[index].balance - payment.amountMinorUnits)
            }
            if working.allSatisfy({ $0.balance == 0 }) { return (month, interestTotal) }
        }
        return nil
    }

    private static func allocate(accounts: [WorkingAccount], budget: Int,
                                 strategy: DebtPayoffStrategy) -> [DebtPaymentAllocation] {
        guard budget > 0 else { return [] }
        var remaining = budget
        var amounts: [String: Int] = [:]

        // Protect payment history first: assign minimums before optimizing.
        for account in accounts where account.balance > 0 {
            let amount = min(remaining, min(account.balance, account.source.minimumPaymentMinorUnits))
            if amount > 0 { amounts[account.source.id, default: 0] += amount }
            remaining -= amount
            if remaining == 0 { break }
        }

        let ordered = accounts.filter { $0.balance > (amounts[$0.source.id] ?? 0) }.sorted { lhs, rhs in
            switch strategy {
            case .avalanche:
                if lhs.source.aprBasisPoints != rhs.source.aprBasisPoints {
                    return lhs.source.aprBasisPoints > rhs.source.aprBasisPoints
                }
                return lhs.balance < rhs.balance
            case .snowball:
                if lhs.balance != rhs.balance { return lhs.balance < rhs.balance }
                return lhs.source.aprBasisPoints > rhs.source.aprBasisPoints
            }
        }

        for account in ordered where remaining > 0 {
            let already = amounts[account.source.id] ?? 0
            let amount = min(remaining, max(0, account.balance - already))
            amounts[account.source.id, default: 0] += amount
            remaining -= amount
        }

        return accounts.compactMap { account in
            guard let amount = amounts[account.source.id], amount > 0 else { return nil }
            return DebtPaymentAllocation(accountID: account.source.id,
                                         accountName: account.source.name,
                                         amountMinorUnits: amount)
        }.sorted {
            if $0.amountMinorUnits != $1.amountMinorUnits {
                return $0.amountMinorUnits > $1.amountMinorUnits
            }
            return $0.accountName.localizedCaseInsensitiveCompare($1.accountName) == .orderedAscending
        }
    }
}

// MARK: - Thirty-day forecast

public struct CashFlowEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let title: String
    /// Positive is money in; negative is money out.
    public let deltaMinorUnits: Int
}

public struct CashFlowForecast: Codable, Equatable, Sendable {
    public let startsOn: Date
    public let endsOn: Date
    public let openingMinorUnits: Int
    public let incomeMinorUnits: Int
    public let outMinorUnits: Int
    public let endingMinorUnits: Int
    public let lowestMinorUnits: Int
    public let lowestOn: Date
    public let safeToSpendMinorUnits: Int
    public let events: [CashFlowEvent]

    public var hasShortfall: Bool { lowestMinorUnits < 0 }
}

public enum CashFlowForecaster {
    public static func forecast(profile: FinanceProfile,
                                subscriptions: [Subscription],
                                expenses: [Expense],
                                creditAccounts: [CreditAccount],
                                asOf now: Date = Date(), days: Int = 30,
                                calendar: Calendar = .current) -> CashFlowForecast {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: max(1, days), to: start) ?? start
        var events: [CashFlowEvent] = []

        if profile.recurringIncomeMinorUnits > 0 {
            var due = BillSchedule.nextDue(from: profile.nextIncomeOn, cadence: .monthly,
                                           asOf: start, calendar: calendar)
            var step = 0
            while due < end && step < 3 {
                events.append(CashFlowEvent(id: "income-\(due.timeIntervalSince1970)", date: due,
                                            title: "Recurring income",
                                            deltaMinorUnits: profile.recurringIncomeMinorUnits))
                due = BillSchedule.advance(due, by: .monthly, calendar: calendar)
                step += 1
            }
        }

        for subscription in subscriptions where subscription.isActive {
            for due in BillSchedule.occurrences(of: subscription, from: start, to: end, calendar: calendar) {
                events.append(CashFlowEvent(id: "subscription-\(subscription.id)-\(due.timeIntervalSince1970)",
                                            date: due, title: subscription.name,
                                            deltaMinorUnits: -subscription.amountMinorUnits(on: due, calendar: calendar)))
            }
        }

        for expense in expenses where expense.spentOn >= start && expense.spentOn < end {
            events.append(CashFlowEvent(id: "expense-\(expense.id)", date: expense.spentOn,
                                        title: expense.name, deltaMinorUnits: -expense.amountMinorUnits))
        }

        for account in creditAccounts where account.isActive && account.balanceMinorUnits > 0 {
            // An entered due date is a real obligation, not merely a recurrence
            // anchor. If it is late, reserve the payment today rather than
            // quietly rolling it into next month.
            let due = max(calendar.startOfDay(for: account.paymentDueOn), start)
            guard due < end else { continue }
            let planned = account.plannedPaymentMinorUnits > 0
                ? account.plannedPaymentMinorUnits : account.minimumPaymentMinorUnits
            let payment = min(account.balanceMinorUnits, max(0, planned))
            if payment > 0 {
                events.append(CashFlowEvent(id: "credit-\(account.id)-\(due.timeIntervalSince1970)",
                                            date: due, title: "\(account.name) payment",
                                            deltaMinorUnits: -payment))
            }
        }

        events.sort {
            if calendar.isDate($0.date, inSameDayAs: $1.date) {
                return $0.deltaMinorUnits > $1.deltaMinorUnits // income lands before same-day bills
            }
            return $0.date < $1.date
        }
        var balance = profile.openingCashMinorUnits
        var lowest = balance
        var lowestOn = start
        for event in events {
            balance += event.deltaMinorUnits
            if balance < lowest {
                lowest = balance
                lowestOn = event.date
            }
        }
        let income = events.reduce(0) { $0 + max(0, $1.deltaMinorUnits) }
        let out = events.reduce(0) { $0 + max(0, -$1.deltaMinorUnits) }
        let safe = max(0, lowest - profile.bufferMinorUnits)
        return CashFlowForecast(startsOn: start, endsOn: end,
                                openingMinorUnits: profile.openingCashMinorUnits,
                                incomeMinorUnits: income, outMinorUnits: out,
                                endingMinorUnits: balance, lowestMinorUnits: lowest,
                                lowestOn: lowestOn, safeToSpendMinorUnits: safe, events: events)
    }
}

// MARK: - Deterministic actions

public enum FinancialActionKind: String, Codable, Sendable {
    case urgent, protect, improve, review
}

public struct FinancialAction: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: FinancialActionKind
    public let priority: Int
    public let title: String
    public let detail: String
    public let amountMinorUnits: Int?
    public let deadline: Date?
    public let estimatedImpact: String
}

public enum FinancialActionEngine {
    public static func actions(accounts: [CreditAccount], subscriptions: [Subscription],
                               forecast: CashFlowForecast, asOf now: Date = Date(),
                               calendar: Calendar = .current) -> [FinancialAction] {
        var actions: [FinancialAction] = []
        let today = calendar.startOfDay(for: now)

        if forecast.hasShortfall {
            actions.append(FinancialAction(id: "forecast-shortfall", kind: .urgent, priority: 100,
                                           title: "Cover the upcoming cash shortfall",
                                           detail: "Projected balance falls below zero within 30 days.",
                                           amountMinorUnits: abs(forecast.lowestMinorUnits),
                                           deadline: forecast.lowestOn,
                                           estimatedImpact: "Protects scheduled payments from failing."))
        }

        for subscription in subscriptions where subscription.isActive {
            let days = BillSchedule.daysUntil(subscription.nextDueOn, asOf: today, calendar: calendar)
            if days < 0 {
                actions.append(FinancialAction(id: "subscription-overdue-\(subscription.id)",
                                               kind: .urgent, priority: 98,
                                               title: "Resolve overdue \(subscription.name)",
                                               detail: "This tracked bill is \(-days) day\(-days == 1 ? "" : "s") late.",
                                               amountMinorUnits: subscription.amountMinorUnits,
                                               deadline: subscription.nextDueOn,
                                               estimatedImpact: "Prevents a missed obligation from lingering."))
            } else if subscription.hasUnacknowledgedPriceChange {
                actions.append(FinancialAction(id: "price-change-\(subscription.id)", kind: .review,
                                               priority: 45, title: "Review \(subscription.name)'s new price",
                                               detail: "Its recorded amount changed without acknowledgment.",
                                               amountMinorUnits: subscription.priceDeltaMinorUnits.map(abs),
                                               deadline: nil,
                                               estimatedImpact: "Confirms whether the recurring cost is still worth keeping."))
            }
        }

        for account in accounts where account.isActive && account.balanceMinorUnits > 0 {
            let due = calendar.startOfDay(for: account.paymentDueOn)
            let dueDays = BillSchedule.daysUntil(due, asOf: today, calendar: calendar)
            if dueDays < 0 {
                actions.append(FinancialAction(id: "payment-overdue-\(account.id)", kind: .urgent,
                                               priority: 99,
                                               title: "Resolve overdue \(account.name) payment",
                                               detail: "The entered due date is \(-dueDays) day\(-dueDays == 1 ? "" : "s") past.",
                                               amountMinorUnits: max(account.minimumPaymentMinorUnits,
                                                                     account.plannedPaymentMinorUnits),
                                               deadline: due,
                                               estimatedImpact: "Protects payment history from further damage."))
            } else if dueDays <= 7 {
                actions.append(FinancialAction(id: "payment-due-\(account.id)", kind: .protect,
                                               priority: account.autopayEnabled ? 82 : 94,
                                               title: "Pay \(account.name) on time",
                                               detail: account.autopayEnabled
                                                   ? "Autopay is marked on; verify the funding account."
                                                   : "Autopay is not marked on in ATLAS.",
                                               amountMinorUnits: max(account.minimumPaymentMinorUnits,
                                                                     account.plannedPaymentMinorUnits),
                                               deadline: due,
                                               estimatedImpact: "Protects payment history."))
            }

            if let utilization = account.utilizationBasisPoints, utilization > 3_000,
               let amount = account.paymentToReach(utilizationPercent: 30), amount > 0 {
                let close = BillSchedule.nextDue(from: account.statementClosesOn, cadence: .monthly,
                                                 asOf: today, calendar: calendar)
                actions.append(FinancialAction(id: "utilization-\(account.id)", kind: .improve,
                                               priority: utilization > 5_000 ? 86 : 68,
                                               title: "Lower \(account.name) below 30%",
                                               detail: "Pay before the statement closes when practical.",
                                               amountMinorUnits: amount, deadline: close,
                                               estimatedImpact: "Lowers reported revolving utilization; score impact varies."))
            }
        }

        return actions.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture)
        }
    }
}
