import Foundation
import WebKit
import AtlasCore

// MARK: - Bridge

/// Sits between `finances.html` and `ExpenseStore`.
///
/// The page owns what is on screen; this owns everything that touches the
/// database. Every write reports back — saved, or why not — because a form that
/// silently failed is worse than one that visibly did.
@MainActor
final class FinancesBridge {
    private weak var webView: WKWebView?
    private var pageIsReady = false
    private var pending: [(function: String, json: String)] = []

    private let store: ExpenseStore
    /// Read-only: the sanitised snapshot Foxtrot writes. ATLAS never contacts
    /// Stripe, and nothing on this page can write back to it.
    private let finance: FinanceReader
    /// Writes bill due dates into Reminders and Calendar. Explicit, never
    /// automatic — it only runs when the page asks.
    private let sync: BillSyncService
    /// Which payoff strategy the plan is costed against. A view preference, not
    /// a stored one — the same as the SwiftUI page it replaces.
    private var payoffStrategy: DebtPayoffStrategy = .avalanche
    /// What the last paste parsed into, held here rather than sent to the page
    /// and back. The page returns ids; the amounts and dates it imports are the
    /// ones Swift read, not ones the page could have altered in between.
    private var parsedInvoices: [InvoiceImport.Candidate] = []

    /// `FinanceReader.shared` and `BillSyncService.shared` are resolved in the
    /// body rather than as default arguments: a default is evaluated in the
    /// caller's context, which is not guaranteed to be the main actor.
    init(store: ExpenseStore = .shared, finance: FinanceReader? = nil,
         sync: BillSyncService? = nil) {
        self.store = store
        self.finance = finance ?? .shared
        self.sync = sync ?? .shared
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        pageIsReady = false
    }

    func pageDidLoad() {
        pageIsReady = true
        let queued = pending
        pending = []
        for call in queued { push(call.function, call.json) }
        reload()
    }

    // MARK: - Actions

    func handle(_ action: FinanceAction) {
        if let failure = store.openFailure {
            push("error", encode(["message": failure, "fatal": true]))
            return
        }

        switch action.action {
        case .load:
            reload()

        case .saveSubscription:
            // An id that no longer resolves means the row was deleted in another
            // window while this form was open. Saving would silently resurrect
            // it under a new identity, so it is refused instead.
            let existing = resolveSubscription(action.id)
            if action.id?.isEmpty == false, existing == nil {
                return refuse(.notFound("subscription"))
            }
            switch FinanceActionValidator.subscription(from: action, existing: existing) {
            case .success(let record):
                store.upsert(record)
                done(existing == nil ? "Subscription created" : "Subscription saved")
            case .failure(let refusal):
                refuse(refusal)
            }

        case .deleteSubscription:
            guard let id = action.id, !id.isEmpty else { return refuse(.missing("Subscription id")) }
            switch store.deleteSubscription(id) {
            case .deleted: done("Subscription deleted")
            case .notFound: refuse(.notFound("subscription"))
            case .restricted: refuse(.notFound("subscription"))
            }

        case .markPaid:
            guard let id = action.id, !id.isEmpty else { return refuse(.missing("Subscription id")) }
            guard resolveSubscription(id) != nil else { return refuse(.notFound("subscription")) }
            store.markPaid(id)
            done("Marked paid")

        case .acknowledgePrice:
            guard let id = action.id, !id.isEmpty else { return refuse(.missing("Subscription id")) }
            guard let record = resolveSubscription(id) else { return refuse(.notFound("subscription")) }
            store.upsert(record, acknowledgingPriceChange: true)
            done("Price change acknowledged")

        case .saveExpense:
            let existing = resolveExpense(action.id)
            if action.id?.isEmpty == false, existing == nil {
                return refuse(.notFound("expense"))
            }
            switch FinanceActionValidator.expense(from: action, existing: existing) {
            case .success(let record):
                store.upsert(record)
                done(existing == nil ? "Expense created" : "Expense saved")
            case .failure(let refusal):
                refuse(refusal)
            }

        case .deleteExpense:
            guard let id = action.id, !id.isEmpty else { return refuse(.missing("Expense id")) }
            switch store.deleteExpense(id) {
            case .deleted: done("Expense deleted")
            case .notFound: refuse(.notFound("expense"))
            case .restricted: refuse(.notFound("expense"))
            }

        case .saveCreditAccount:
            let existing = resolveCreditAccount(action.id)
            if action.id?.isEmpty == false, existing == nil {
                return refuse(.notFound("account"))
            }
            switch FinanceActionValidator.creditAccount(from: action, existing: existing) {
            case .success(let record):
                store.upsert(record)
                done(existing == nil ? "Account added" : "Account saved")
            case .failure(let refusal):
                refuse(refusal)
            }

        case .saveProfile:
            switch FinanceActionValidator.profile(from: action, existing: store.financeProfile()) {
            case .success(let record):
                store.saveFinanceProfile(record)
                done("Planning setup saved")
            case .failure(let refusal):
                refuse(refusal)
            }

        case .setStrategy:
            let text = action.strategy ?? ""
            guard let strategy = DebtPayoffStrategy(rawValue: text) else {
                return refuse(.unknownValue("strategy", text))
            }
            // Not a write: the plan is recomputed and sent back, so the choice
            // lives for as long as the page does and nothing is stored.
            payoffStrategy = strategy
            reload()

        case .trackProvider:
            let name = action.provider ?? ""
            guard let provider = InfraPrefill.candidates(from: finance.infra, store: store)
                .first(where: { $0.name == name })
            else { return refuse(.unknownValue("provider", name)) }
            InfraPrefill.add(provider, store: store)
            done("Tracking \(provider.name.capitalized)")

        case .syncCalendar:
            if let note = sync.permissionNote {
                return push("note", encode(["message": note]))
            }
            let outcome = sync.syncAll()
            push("note", encode(["message": outcome.summary]))
            reload()

        case .parseInvoices:
            // Parsed but not written. The page shows what was found and nothing
            // is stored until the user says which rows to keep.
            parsedInvoices = InvoiceImport.parse(action.pasted ?? "")
            push("invoices", encode([
                "candidates": parsedInvoices.map { candidate in
                    var row: [String: Any] = [
                        "id": candidate.id,
                        "description": candidate.description,
                        "amountText": Money.format(candidate.amountMinorUnits),
                        "date": shortDate(candidate.date),
                        "include": candidate.include
                    ]
                    if let warning = candidate.warning { row["warning"] = warning }
                    return row
                }
            ]))

        case .importInvoices:
            let keep = Set(action.include ?? [])
            let chosen = parsedInvoices.filter { keep.contains($0.id) }
            guard !chosen.isEmpty else { return refuse(.missing("At least one charge")) }
            for candidate in chosen {
                store.upsert(Expense(name: candidate.description,
                                     amountMinorUnits: candidate.amountMinorUnits,
                                     category: InvoiceImport.category(for: candidate.description),
                                     spentOn: candidate.date,
                                     notes: "Imported from a pasted invoice list"))
            }
            parsedInvoices = []
            done("Imported \(chosen.count) charge\(chosen.count == 1 ? "" : "s")")
        }
    }

    /// Re-reads provider figures so a change in what they charge surfaces as a
    /// flagged price change rather than silently updating. Called on a timer by
    /// the host, the same as the SwiftUI page it replaces.
    func refreshProviderAmounts() {
        let changed = InfraPrefill.refreshAmounts(from: finance.infra, store: store)
        if changed > 0 {
            push("note", encode([
                "message": "\(changed) provider price\(changed == 1 ? "" : "s") changed"
            ]))
        }
        reload()
    }

    private func resolveSubscription(_ id: String?) -> Subscription? {
        guard let id, !id.isEmpty else { return nil }
        return store.subscriptions().first { $0.id == id }
    }

    private func resolveExpense(_ id: String?) -> Expense? {
        guard let id, !id.isEmpty else { return nil }
        return store.expenses().first { $0.id == id }
    }

    private func resolveCreditAccount(_ id: String?) -> CreditAccount? {
        guard let id, !id.isEmpty else { return nil }
        return store.creditAccounts().first { $0.id == id }
    }

    // MARK: - Sending state to the page

    /// The whole snapshot, after every write.
    ///
    /// Re-reading rather than patching what the page already holds is what keeps
    /// the two from drifting: a scheduled rise that settled, a due date that
    /// rolled forward and a recalculated total all arrive together, and the page
    /// never has to know which of them a given write touched.
    func reload() {
        if let failure = store.openFailure {
            push("error", encode(["message": failure, "fatal": true]))
            return
        }

        // A scheduled rise whose date has passed simply becomes the price.
        store.settleScheduledPriceChanges()

        let now = Date()
        let summary = store.summary(asOf: now)
        let month = store.cashFlow(for: now)
        let dueSoonIds = Set(store.dueSoon(within: 14, asOf: now).map(\.id))

        let payload: [String: Any] = [
            "subscriptions": store.subscriptions().map { encodeSubscription($0, asOf: now,
                                                                            dueSoon: dueSoonIds) },
            "expenses": store.expenses().map(encodeExpense),
            "summary": [
                "activeSubscriptions": summary.activeSubscriptions,
                "monthlyCommitted": summary.monthlyCommittedMinorUnits,
                "yearlyCommitted": summary.yearlyCommittedMinorUnits,
                "dueSoonCount": summary.dueSoonCount,
                "dueSoonTotal": summary.dueSoonMinorUnits,
                "overdueCount": summary.overdueCount,
                "priceChangeCount": summary.priceChangeCount,
                "futureMonthly": summary.futureMonthlyMinorUnits,
                "pendingPriceChangeCount": summary.pendingPriceChangeCount
            ],
            "month": [
                "label": month.month.formatted(.dateTime.month(.wide).year()),
                "subscriptions": month.subscriptionsMinorUnits,
                "expenses": month.expensesMinorUnits,
                "out": month.outMinorUnits
            ],
            "options": [
                "cadences": BillingCadence.allCases.map { ["value": $0.rawValue, "label": $0.title] },
                "categories": ExpenseCategory.allCases.map { ["value": $0.rawValue, "label": $0.title] },
                "strategies": DebtPayoffStrategy.allCases.map { ["value": $0.rawValue, "label": $0.title] }
            ],
            "plan": encodePlan(asOf: now),
            "moneyIn": encodeMoneyIn(),
            // Providers ATLAS already reads a figure for but does not track as a
            // bill yet — offered rather than added, so nothing appears in the
            // totals that the user did not put there.
            "infraOffers": InfraPrefill.candidates(from: finance.infra, store: store)
                .map { provider -> [String: Any] in
                    var row: [String: Any] = [
                        "name": provider.name,
                        "label": provider.name.capitalized,
                        "detail": provider.plan ?? "current spend",
                        "amountText": Money.format(Int(((provider.currentUSD ?? 0) * 100).rounded()))
                    ]
                    row["available"] = provider.available
                    return row
                },
            "canSync": sync.canSync,
            "today": FinanceDate.string(now)
        ]
        push("render", encode(payload))
    }

    /// The Money in tab, or `configured: false` when Foxtrot has not run.
    ///
    /// This carries the page's honesty rules with it: test figures are labelled
    /// rather than shown as revenue, an incomplete fetch is marked a floor, and
    /// a source that is not wired says so instead of showing zero. Absent is not
    /// the same as zero, and the page is given enough to say which it is.
    private func encodeMoneyIn() -> [String: Any] {
        finance.refresh()
        guard let snapshot = finance.snapshot else {
            return ["configured": false]
        }
        let t = snapshot.totals

        var payload: [String: Any] = [
            "configured": true,
            "isLive": snapshot.isLive,
            "isStale": snapshot.isStale,
            "complete": snapshot.complete,
            "generatedAt": snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened),
            "droppedTextFields": snapshot.droppedTextFields,
            "totals": [
                "netText": Money.format(t.netMinorUnits),
                "grossText": Money.format(t.grossMinorUnits),
                "refundedText": Money.format(t.refundedMinorUnits),
                "openDisputeText": Money.format(t.openDisputeMinorUnits),
                "chargesSeen": t.chargesSeen,
                "paidCount": t.paidCount,
                "payoutCount": t.payoutCount,
                "disputedCount": t.disputedCount,
                "openDisputeCount": t.openDisputeCount,
                "unpaidInvoiceCount": t.unpaidInvoiceCount,
                "failedPaymentCount": t.failedPaymentCount,
                "activeSubscriptions": t.activeSubscriptions
            ],
            "unavailable": snapshot.unavailable.map {
                $0.replacingOccurrences(of: "_", with: " ").capitalized
            }
        ]

        if let infra = finance.infra {
            payload["infra"] = [
                "complete": infra.complete,
                "knownText": String(format: "$%.2f", infra.knownCurrentUSD),
                "providersCounted": infra.providersCounted,
                "providerTotal": infra.providers.count,
                "providers": infra.providers.map { p -> [String: Any] in
                    var row: [String: Any] = [
                        "name": p.name.capitalized,
                        "available": p.available,
                        "uncapped": p.uncapped
                    ]
                    if let plan = p.plan { row["plan"] = plan.uppercased() }
                    if let note = p.note { row["note"] = note }
                    // No figure is not zero — a provider ATLAS could not read
                    // says so rather than reporting nothing spent.
                    if let current = p.currentUSD {
                        row["currentText"] = String(format: "$%.2f", current)
                    }
                    if let estimated = p.estimatedUSD {
                        row["estimatedText"] = String(format: "est $%.2f", estimated)
                    }
                    return row
                }
            ]
        }
        return payload
    }

    /// The Plan tab: position, actions, forecast, cards and payoff.
    ///
    /// Every figure here is derived rather than stored, so it is computed on the
    /// way out rather than cached — the page holds a snapshot, never a model it
    /// has to keep in step.
    private func encodePlan(asOf now: Date) -> [String: Any] {
        let profile = store.financeProfile()
        let accounts = store.creditAccounts()
        let subscriptions = store.subscriptions()
        let summary = CreditSummary(accounts: accounts)
        let forecast = CashFlowForecaster.forecast(profile: profile,
                                                   subscriptions: subscriptions,
                                                   expenses: store.expenses(),
                                                   creditAccounts: accounts)
        let plan = DebtPlanner.plan(accounts: accounts,
                                    monthlyBudgetMinorUnits: profile.monthlyDebtBudgetMinorUnits,
                                    strategy: payoffStrategy)
        let actions = FinancialActionEngine.actions(accounts: accounts,
                                                    subscriptions: subscriptions,
                                                    forecast: forecast, asOf: now)

        return [
            "profile": [
                "openingCash": profile.openingCashMinorUnits,
                "openingCashText": Money.format(profile.openingCashMinorUnits),
                "recurringIncome": profile.recurringIncomeMinorUnits,
                "recurringIncomeText": Money.format(profile.recurringIncomeMinorUnits),
                "nextIncomeOn": FinanceDate.string(profile.nextIncomeOn),
                "monthlyDebtBudget": profile.monthlyDebtBudgetMinorUnits,
                "monthlyDebtBudgetText": Money.format(profile.monthlyDebtBudgetMinorUnits),
                "buffer": profile.bufferMinorUnits,
                "bufferText": Money.format(profile.bufferMinorUnits),
                "isConfigured": profile.isConfigured
            ],
            "credit": [
                "totalBalanceText": Money.format(summary.totalBalanceMinorUnits),
                "totalLimitText": Money.format(summary.totalLimitMinorUnits),
                "utilization": basisPoints(summary.utilizationBasisPoints),
                "projectedUtilization": basisPoints(summary.projectedUtilizationBasisPoints),
                "plannedPaymentText": Money.format(summary.plannedPaymentMinorUnits),
                "toReach30": optionalMoney(summary.paymentToReach(utilizationPercent: 30)),
                "toReach10": optionalMoney(summary.paymentToReach(utilizationPercent: 10)),
                "accounts": accounts.map(encodeCreditAccount)
            ],
            "forecast": [
                "income": forecast.incomeMinorUnits,
                "incomeText": Money.format(forecast.incomeMinorUnits),
                "out": forecast.outMinorUnits,
                "outText": Money.format(forecast.outMinorUnits),
                "ending": forecast.endingMinorUnits,
                "endingText": Money.format(forecast.endingMinorUnits),
                "lowest": forecast.lowestMinorUnits,
                "lowestText": Money.format(forecast.lowestMinorUnits),
                "lowestOn": shortDate(forecast.lowestOn),
                "safeToSpend": forecast.safeToSpendMinorUnits,
                "safeToSpendText": Money.format(forecast.safeToSpendMinorUnits),
                "hasShortfall": forecast.hasShortfall
            ],
            "actions": actions.map { action in
                var row: [String: Any] = [
                    "id": action.id,
                    "kind": action.kind.rawValue,
                    "title": action.title,
                    "detail": action.detail,
                    "impact": action.estimatedImpact
                ]
                if let amount = action.amountMinorUnits { row["amountText"] = Money.format(amount) }
                if let deadline = action.deadline { row["deadline"] = shortDate(deadline) }
                return row
            },
            "debt": [
                "strategy": payoffStrategy.rawValue,
                "budgetText": Money.format(plan.monthlyBudgetMinorUnits),
                "minimumsText": Money.format(plan.minimumsMinorUnits),
                "budgetCoversMinimums": plan.budgetCoversMinimums,
                "shortfallText": Money.format(max(0, plan.minimumsMinorUnits - plan.monthlyBudgetMinorUnits)),
                "payoffMonths": plan.payoffMonths as Any,
                "interestText": optionalMoney(plan.interestMinorUnits),
                "interestSavedText": optionalMoney(plan.interestSavedMinorUnits),
                "allocations": plan.firstMonth.map {
                    ["name": $0.accountName, "amountText": Money.format($0.amountMinorUnits)]
                },
                // Whether there is anything to plan at all, so the page can tell
                // "no debt recorded" apart from "no budget set".
                "hasDebt": !accounts.filter { $0.isActive && $0.balanceMinorUnits > 0 }.isEmpty
            ]
        ]
    }

    /// Two shapes per money field: `…Text` is what a row shows ("$1,250.00"),
    /// `…Input` is what the editor round-trips ("1250.00"). The editor must get
    /// back exactly what `Money.minorUnits` accepts, and a formatted string with
    /// a symbol and separators is not it.
    private func encodeCreditAccount(_ a: CreditAccount) -> [String: Any] {
        [
            "id": a.id,
            "name": a.name,
            "balanceText": Money.format(a.balanceMinorUnits),
            "balanceInput": moneyInput(a.balanceMinorUnits),
            "limit": a.creditLimitMinorUnits,
            "limitText": Money.format(a.creditLimitMinorUnits),
            "limitInput": moneyInput(a.creditLimitMinorUnits),
            // Basis points are hundredths of a percent, so the same helper that
            // renders cents renders an APR: 2499 -> "24.99".
            "aprInput": moneyInput(a.aprBasisPoints),
            "minimumInput": moneyInput(a.minimumPaymentMinorUnits),
            "plannedInput": moneyInput(a.plannedPaymentMinorUnits),
            "planned": a.plannedPaymentMinorUnits,
            "plannedText": Money.format(a.plannedPaymentMinorUnits),
            "paymentDueOn": FinanceDate.string(a.paymentDueOn),
            "paymentDueLabel": shortDate(a.paymentDueOn),
            "statementClosesOn": FinanceDate.string(a.statementClosesOn),
            "statementClosesLabel": shortDate(a.statementClosesOn),
            "openedOn": FinanceDate.string(a.openedOn),
            "autopayEnabled": a.autopayEnabled,
            "isActive": a.isActive,
            "notes": a.notes,
            "utilization": basisPoints(a.utilizationBasisPoints),
            "projectedUtilization": basisPoints(a.projectedUtilizationBasisPoints),
            "toReach30": optionalMoney(a.paymentToReach(utilizationPercent: 30)),
            "toReach10": optionalMoney(a.paymentToReach(utilizationPercent: 10))
        ]
    }

    /// Basis points as a percentage string, or "—" when there is no limit to
    /// divide by. Nil is not zero: a card with no limit recorded has no
    /// utilization, and showing 0% would read as one that is paid off.
    private func basisPoints(_ value: Int?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f%%", Double(value) / 100)
    }

    private func optionalMoney(_ value: Int?) -> String {
        value.map(Money.format) ?? "—"
    }

    /// The plain "1234.56" an editor field round-trips, with no symbol.
    private func moneyInput(_ minorUnits: Int) -> String {
        minorUnits == 0 ? "" : String(format: "%d.%02d", minorUnits / 100, abs(minorUnits % 100))
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func encodeSubscription(_ s: Subscription, asOf now: Date,
                                    dueSoon: Set<String>) -> [String: Any] {
        var row: [String: Any] = [
            "id": s.id,
            "name": s.name,
            "amount": s.amountMinorUnits,
            "amountText": Money.format(s.amountMinorUnits),
            "currency": s.currency,
            "cadence": s.cadence.rawValue,
            "cadenceLabel": s.cadence.title,
            "nextDueOn": FinanceDate.string(s.nextDueOn),
            "daysUntil": BillSchedule.daysUntil(s.nextDueOn, asOf: now),
            "category": s.category.rawValue,
            "categoryLabel": s.category.title,
            "source": s.source.rawValue,
            "notes": s.notes,
            "isActive": s.isActive,
            "monthlyEquivalent": s.monthlyEquivalentMinorUnits,
            "yearly": s.yearlyMinorUnits,
            "dueSoon": dueSoon.contains(s.id),
            // A row read from the provider is not editable by hand — the next
            // refresh would overwrite the edit, so the page hides the control
            // rather than offering one that does not hold.
            "editable": s.source == .manual
        ]
        if let delta = s.priceDeltaMinorUnits, let previous = s.previousAmountMinorUnits {
            row["priceChange"] = [
                "previous": previous,
                "previousText": Money.format(previous),
                "delta": delta,
                "deltaText": Money.format(abs(delta)),
                "rose": delta > 0,
                "at": s.priceChangedAt.map(FinanceDate.string) as Any
            ]
        }
        if let scheduled = s.scheduledAmountMinorUnits, let from = s.scheduledFrom {
            row["scheduled"] = [
                "amount": scheduled,
                "amountText": Money.format(scheduled),
                "from": FinanceDate.string(from),
                "delta": s.scheduledDeltaMinorUnits ?? 0,
                "pending": s.hasPendingPriceChange(asOf: now)
            ]
        }
        return row
    }

    private func encodeExpense(_ e: Expense) -> [String: Any] {
        [
            "id": e.id,
            "name": e.name,
            "amount": e.amountMinorUnits,
            "amountText": Money.format(e.amountMinorUnits),
            "currency": e.currency,
            "category": e.category.rawValue,
            "categoryLabel": e.category.title,
            "spentOn": FinanceDate.string(e.spentOn),
            "notes": e.notes
        ]
    }

    // MARK: - Replying

    private func done(_ message: String) {
        push("saved", encode(["message": message]))
        reload()
    }

    private func refuse(_ refusal: FinanceRefusal) {
        push("error", encode(["message": refusal.message, "fatal": false]))
    }

    /// Calls a function on the page, queueing until it has loaded.
    ///
    /// The payload is handed over as an argument rather than spliced into the
    /// script text. A subscription named with a quote would otherwise have to be
    /// escaped correctly into JavaScript source on every call, and getting that
    /// wrong once is both a broken page and a way in.
    private func push(_ function: String, _ json: String) {
        guard let webView, pageIsReady else {
            pending.append((function, json))
            return
        }
        webView.callAsyncJavaScript("window.atlasFinances.\(function)(json)",
                                    arguments: ["json": json], in: nil, in: .page) { result in
            if case .failure(let error) = result {
                NSLog("[ATLAS Finances] %@ failed: %@", function, error.localizedDescription)
            }
        }
    }

    /// Encodes to JSON, or to `null` if it cannot — a malformed literal would
    /// be a syntax error inside `evaluateJavaScript` and take the page's whole
    /// call with it.
    private func encode(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8)
        else {
            NSLog("[ATLAS Finances] could not encode a payload for the page")
            return "null"
        }
        return text
    }
}
