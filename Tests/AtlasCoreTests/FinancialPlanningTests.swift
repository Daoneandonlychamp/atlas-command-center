import XCTest
@testable import AtlasCore

final class FinancialPlanningTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func account(_ name: String, balance: Int, limit: Int,
                         apr: Int = 2_000, minimum: Int = 2_500,
                         planned: Int = 0) -> CreditAccount {
        CreditAccount(name: name, balanceMinorUnits: balance,
                      creditLimitMinorUnits: limit, aprBasisPoints: apr,
                      minimumPaymentMinorUnits: minimum,
                      plannedPaymentMinorUnits: planned,
                      paymentDueOn: day(2026, 9, 12),
                      statementClosesOn: day(2026, 9, 18))
    }

    func testUtilizationAndTargetPayments() {
        let card = account("Card", balance: 4_200, limit: 10_000, planned: 1_200)
        XCTAssertEqual(card.utilizationBasisPoints, 4_200)
        XCTAssertEqual(card.paymentToReach(utilizationPercent: 30), 1_200)
        XCTAssertEqual(card.paymentToReach(utilizationPercent: 10), 3_200)
        XCTAssertEqual(card.projectedUtilizationBasisPoints, 3_000)
    }

    func testOverallUtilizationUsesCombinedLimits() {
        let summary = CreditSummary(accounts: [
            account("A", balance: 3_000, limit: 10_000),
            account("B", balance: 2_000, limit: 10_000, planned: 1_000)
        ])
        XCTAssertEqual(summary.utilizationBasisPoints, 2_500)
        XCTAssertEqual(summary.projectedUtilizationBasisPoints, 2_000)
        XCTAssertEqual(summary.paymentToReach(utilizationPercent: 10), 3_000)
    }

    func testZeroLimitIsUnknownAndOverLimitIsSafe() {
        let noLimit = account("Unknown", balance: 2_000, limit: 0)
        XCTAssertNil(noLimit.utilizationBasisPoints)
        XCTAssertNil(noLimit.paymentToReach(utilizationPercent: 30))

        let over = account("Over", balance: 12_000, limit: 10_000)
        XCTAssertEqual(over.utilizationBasisPoints, 12_000)
        XCTAssertEqual(over.availableCreditMinorUnits, 0)
        XCTAssertEqual(over.paymentToReach(utilizationPercent: 30), 9_000)
    }

    func testAvalancheAndSnowballChooseDifferentTargetsAfterMinimums() {
        let small = account("Small", balance: 20_000, limit: 100_000,
                            apr: 1_200, minimum: 2_000)
        let expensive = account("Expensive", balance: 80_000, limit: 100_000,
                                apr: 2_900, minimum: 2_000)

        let avalanche = DebtPlanner.plan(accounts: [small, expensive],
                                         monthlyBudgetMinorUnits: 10_000,
                                         strategy: .avalanche)
        let snowball = DebtPlanner.plan(accounts: [small, expensive],
                                        monthlyBudgetMinorUnits: 10_000,
                                        strategy: .snowball)

        XCTAssertEqual(avalanche.firstMonth.first { $0.accountName == "Expensive" }?.amountMinorUnits,
                       8_000)
        XCTAssertEqual(snowball.firstMonth.first { $0.accountName == "Small" }?.amountMinorUnits,
                       8_000)
        XCTAssertNotNil(avalanche.payoffMonths)
        XCTAssertNotNil(snowball.payoffMonths)
    }

    func testInsufficientBudgetIsFlagged() {
        let cards = [
            account("A", balance: 20_000, limit: 100_000, minimum: 3_000),
            account("B", balance: 20_000, limit: 100_000, minimum: 3_000)
        ]
        let plan = DebtPlanner.plan(accounts: cards, monthlyBudgetMinorUnits: 5_000,
                                    strategy: .avalanche)
        XCTAssertFalse(plan.budgetCoversMinimums)
        XCTAssertEqual(plan.minimumsMinorUnits, 6_000)
        XCTAssertNil(plan.payoffMonths)
        XCTAssertNil(plan.interestMinorUnits)
    }

    func testForecastFindsTheLowestBalanceAndShortfall() {
        let now = day(2026, 9, 7)
        let profile = FinanceProfile(openingCashMinorUnits: 30_000,
                                     recurringIncomeMinorUnits: 50_000,
                                     nextIncomeOn: day(2026, 9, 20),
                                     bufferMinorUnits: 5_000)
        let rent = Subscription(name: "Rent", amountMinorUnits: 40_000,
                                cadence: .monthly, nextDueOn: day(2026, 9, 10))
        let forecast = CashFlowForecaster.forecast(profile: profile,
                                                   subscriptions: [rent], expenses: [],
                                                   creditAccounts: [], asOf: now,
                                                   calendar: calendar)
        XCTAssertTrue(forecast.hasShortfall)
        XCTAssertEqual(forecast.lowestMinorUnits, -10_000)
        XCTAssertEqual(forecast.lowestOn, day(2026, 9, 10))
        XCTAssertEqual(forecast.endingMinorUnits, 40_000)
        XCTAssertEqual(forecast.safeToSpendMinorUnits, 0)
    }

    func testForecastIncludesPlannedCardPaymentAndFutureExpense() {
        let now = day(2026, 9, 7)
        let profile = FinanceProfile(openingCashMinorUnits: 100_000)
        let card = account("Card", balance: 50_000, limit: 100_000,
                           minimum: 2_500, planned: 10_000)
        let purchase = Expense(name: "Desk", amountMinorUnits: 20_000,
                               spentOn: day(2026, 9, 15))
        let forecast = CashFlowForecaster.forecast(profile: profile,
                                                   subscriptions: [], expenses: [purchase],
                                                   creditAccounts: [card], asOf: now,
                                                   calendar: calendar)
        XCTAssertEqual(forecast.outMinorUnits, 30_000)
        XCTAssertEqual(forecast.endingMinorUnits, 70_000)
    }

    func testUrgentRisksRankAheadOfUtilizationAdvice() {
        let now = day(2026, 9, 7)
        let card = CreditAccount(name: "Card", balanceMinorUnits: 8_000,
                                 creditLimitMinorUnits: 10_000,
                                 minimumPaymentMinorUnits: 1_000,
                                 paymentDueOn: day(2026, 9, 9),
                                 statementClosesOn: day(2026, 9, 15))
        let late = Subscription(name: "Hosting", amountMinorUnits: 500,
                                nextDueOn: day(2026, 9, 1))
        let forecast = CashFlowForecaster.forecast(profile: FinanceProfile(),
                                                   subscriptions: [], expenses: [],
                                                   creditAccounts: [], asOf: now,
                                                   calendar: calendar)
        let actions = FinancialActionEngine.actions(accounts: [card], subscriptions: [late],
                                                    forecast: forecast, asOf: now,
                                                    calendar: calendar)
        XCTAssertEqual(actions.first?.id, "subscription-overdue-\(late.id)")
        XCTAssertTrue(actions.contains { $0.id == "payment-due-\(card.id)" })
        XCTAssertTrue(actions.contains { $0.id == "utilization-\(card.id)" })
    }

    func testOverdueCardIsNotSilentlyRolledIntoNextMonth() {
        let now = day(2026, 9, 7)
        let card = CreditAccount(name: "Late card", balanceMinorUnits: 10_000,
                                 creditLimitMinorUnits: 50_000,
                                 minimumPaymentMinorUnits: 2_500,
                                 paymentDueOn: day(2026, 9, 2),
                                 statementClosesOn: day(2026, 9, 10))
        let forecast = CashFlowForecaster.forecast(profile: FinanceProfile(openingCashMinorUnits: 20_000),
                                                   subscriptions: [], expenses: [],
                                                   creditAccounts: [card], asOf: now,
                                                   calendar: calendar)
        let actions = FinancialActionEngine.actions(accounts: [card], subscriptions: [],
                                                    forecast: forecast, asOf: now,
                                                    calendar: calendar)
        XCTAssertEqual(actions.first?.id, "payment-overdue-\(card.id)")
        XCTAssertEqual(forecast.outMinorUnits, 2_500,
                       "a late minimum remains reserved instead of vanishing from the forecast")
    }
}
