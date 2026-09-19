import XCTest

@testable import AtlasCore

/// Checks the boundary between `finances.html` and the store.
///
/// Two things are being proved. First, that only the allowlisted vocabulary
/// decodes at all — a message asking for anything else never becomes an action.
/// Second, that everything which *does* decode is validated again here, because
/// a web view can be handed any message and the page's own checks are a
/// convenience for the person typing, not a defence.
///
/// The money cases carry extra weight: this is the seam where a typed amount
/// becomes a stored integer, and a cent lost here is a total nobody can
/// reconcile later.
final class FinanceActionTests: XCTestCase {

    private func decode(_ json: String) -> FinanceAction? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FinanceAction.self, from: data)
    }

    // MARK: - The allowlist

    func testOnlyAllowlistedActionsDecode() {
        for kind in FinanceActionKind.allCases {
            XCTAssertNotNil(decode(#"{"action":"\#(kind.rawValue)"}"#),
                            "\(kind.rawValue) is in the allowlist and must decode")
        }
    }

    func testMessagesOutsideTheAllowlistAreRejected() {
        let hostile = [
            #"{"action":"eval","code":"fetch('https://example.com')"}"#,
            #"{"action":"runSQL","sql":"DROP TABLE subscriptions"}"#,
            #"{"action":"revealDatabaseKey"}"#,
            #"{"action":"saveSubscriptions"}"#,
            #"{"action":""}"#,
            #"{}"#
        ]
        for message in hostile {
            XCTAssertNil(decode(message), "\(message) must not decode into an action")
        }
    }

    // MARK: - Subscriptions

    private func subscriptionAction(name: String = "Vercel",
                                    amount: String = "20.00",
                                    cadence: String = "monthly",
                                    due: String = "2026-10-01",
                                    category: String = "infrastructure",
                                    scheduledAmount: String = "",
                                    scheduledFrom: String = "") -> FinanceAction {
        decode("""
        {"action":"saveSubscription","name":"\(name)","amount":"\(amount)",
         "cadence":"\(cadence)","nextDueOn":"\(due)","category":"\(category)",
         "scheduledAmount":"\(scheduledAmount)","scheduledFrom":"\(scheduledFrom)"}
        """)!
    }

    func testValidSubscriptionBecomesARecord() throws {
        let result = FinanceActionValidator.subscription(from: subscriptionAction(), existing: nil)
        let record = try XCTUnwrap(try? result.get())
        XCTAssertEqual(record.name, "Vercel")
        XCTAssertEqual(record.amountMinorUnits, 2000)
        XCTAssertEqual(record.cadence, .monthly)
        XCTAssertEqual(record.category, .infrastructure)
    }

    /// The whole reason amounts cross as text. If the page sent a number, this
    /// is the value that would arrive already rounded.
    func testAwkwardAmountKeepsItsCent() throws {
        let result = FinanceActionValidator.subscription(
            from: subscriptionAction(amount: "21.28"), existing: nil)
        let record = try XCTUnwrap(try? result.get())
        XCTAssertEqual(record.amountMinorUnits, 2128,
                       "21.28 must store as 2128, not 2127")
    }

    func testAmountsWithSymbolsAndSeparatorsParse() throws {
        let result = FinanceActionValidator.subscription(
            from: subscriptionAction(amount: "$1,250"), existing: nil)
        let record = try XCTUnwrap(try? result.get())
        XCTAssertEqual(record.amountMinorUnits, 125000)
    }

    func testNonsenseAmountIsRefused() {
        for bad in ["", "twenty", "20.123", "1.2.3", "--5"] {
            let result = FinanceActionValidator.subscription(
                from: subscriptionAction(amount: bad), existing: nil)
            XCTAssertThrowsError(try result.get(), "\"\(bad)\" must not become an amount")
        }
    }

    func testBlankNameIsRefused() {
        let result = FinanceActionValidator.subscription(
            from: subscriptionAction(name: "   "), existing: nil)
        guard case .failure(let refusal) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(refusal, .missing("Name"))
    }

    func testUnknownCadenceIsRefused() {
        let result = FinanceActionValidator.subscription(
            from: subscriptionAction(cadence: "hourly"), existing: nil)
        guard case .failure(let refusal) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(refusal, .unknownValue("cadence", "hourly"))
    }

    func testUnparseableDateIsRefused() {
        for bad in ["", "01/10/2026", "2026-13-45", "next tuesday"] {
            let result = FinanceActionValidator.subscription(
                from: subscriptionAction(due: bad), existing: nil)
            XCTAssertThrowsError(try result.get(), "\"\(bad)\" must not become a date")
        }
    }

    /// Half a scheduled change would forecast wrongly, so neither half is taken
    /// on its own.
    func testHalfEnteredScheduledChangeIsRefused() {
        let amountOnly = FinanceActionValidator.subscription(
            from: subscriptionAction(scheduledAmount: "24.00"), existing: nil)
        guard case .failure(let first) = amountOnly else { return XCTFail("expected a refusal") }
        XCTAssertEqual(first, .missing("Scheduled date"))

        let dateOnly = FinanceActionValidator.subscription(
            from: subscriptionAction(scheduledFrom: "2026-11-01"), existing: nil)
        guard case .failure(let second) = dateOnly else { return XCTFail("expected a refusal") }
        XCTAssertEqual(second, .missing("Scheduled amount"))
    }

    func testCompleteScheduledChangeIsKept() throws {
        let result = FinanceActionValidator.subscription(
            from: subscriptionAction(scheduledAmount: "24.00", scheduledFrom: "2026-11-01"),
            existing: nil)
        let record = try XCTUnwrap(try? result.get())
        XCTAssertEqual(record.scheduledAmountMinorUnits, 2400)
        XCTAssertNotNil(record.scheduledFrom)
        XCTAssertEqual(record.scheduledDeltaMinorUnits, 400)
    }

    /// An edit must not launder a provider row into a hand-entered one, or erase
    /// the price history the page never sees.
    func testEditKeepsWhatThePageDoesNotOwn() throws {
        var existing = Subscription(name: "Railway", amountMinorUnits: 2500,
                                    source: .infrastructure, providerKey: "railway")
        existing.previousAmountMinorUnits = 2000
        let created = existing.createdAt

        let result = FinanceActionValidator.subscription(
            from: subscriptionAction(name: "Railway", amount: "25.00"), existing: existing)
        let record = try XCTUnwrap(try? result.get())

        XCTAssertEqual(record.id, existing.id)
        XCTAssertEqual(record.source, .infrastructure)
        XCTAssertEqual(record.providerKey, "railway")
        XCTAssertEqual(record.previousAmountMinorUnits, 2000)
        XCTAssertEqual(record.createdAt, created)
    }

    // MARK: - Expenses

    func testValidExpenseBecomesARecord() throws {
        let action = decode("""
        {"action":"saveExpense","name":"Domain renewal","amount":"12.00",
         "spentOn":"2026-09-03","category":"services"}
        """)!
        let record = try XCTUnwrap(try? FinanceActionValidator.expense(from: action,
                                                                      existing: nil).get())
        XCTAssertEqual(record.name, "Domain renewal")
        XCTAssertEqual(record.amountMinorUnits, 1200)
        XCTAssertEqual(record.category, .services)
    }

    func testExpenseWithoutADateIsRefused() {
        let action = decode(#"{"action":"saveExpense","name":"Thing","amount":"5.00"}"#)!
        let result = FinanceActionValidator.expense(from: action, existing: nil)
        XCTAssertThrowsError(try result.get())
    }

    // MARK: - Credit accounts

    private func accountAction(name: String = "Sapphire",
                               balance: String = "820.00",
                               limit: String = "5000.00",
                               apr: String = "24.99",
                               minimum: String = "35.00",
                               planned: String = "200.00",
                               due: String = "2026-10-05",
                               closes: String = "2026-09-12") -> FinanceAction {
        decode("""
        {"action":"saveCreditAccount","name":"\(name)","balance":"\(balance)",
         "limit":"\(limit)","apr":"\(apr)","minimum":"\(minimum)","planned":"\(planned)",
         "paymentDueOn":"\(due)","statementClosesOn":"\(closes)","openedOn":"2024-01-01"}
        """)!
    }

    func testValidCreditAccountBecomesARecord() throws {
        let record = try XCTUnwrap(try? FinanceActionValidator
            .creditAccount(from: accountAction(), existing: nil).get())
        XCTAssertEqual(record.name, "Sapphire")
        XCTAssertEqual(record.balanceMinorUnits, 82000)
        XCTAssertEqual(record.creditLimitMinorUnits, 500000)
        XCTAssertEqual(record.minimumPaymentMinorUnits, 3500)
    }

    /// An APR is hundredths of a percent, so it goes through the same integer
    /// parser as money rather than a Double.
    func testAprBecomesBasisPointsExactly() throws {
        let record = try XCTUnwrap(try? FinanceActionValidator
            .creditAccount(from: accountAction(apr: "24.99"), existing: nil).get())
        XCTAssertEqual(record.aprBasisPoints, 2499)
    }

    func testBlankAprMeansZero() throws {
        let record = try XCTUnwrap(try? FinanceActionValidator
            .creditAccount(from: accountAction(apr: ""), existing: nil).get())
        XCTAssertEqual(record.aprBasisPoints, 0)
    }

    /// The bug this prevents: a typo in a balance silently becoming $0, which
    /// reads as a paid-off card and takes the utilization figure with it.
    func testMistypedBalanceIsRefusedRatherThanZeroed() {
        for bad in ["82O.00", "eight hundred", "820.000"] {
            let result = FinanceActionValidator.creditAccount(
                from: accountAction(balance: bad), existing: nil)
            XCTAssertThrowsError(try result.get(),
                                 "\"\(bad)\" must be refused, not silently zeroed")
        }
    }

    /// Blank is a real answer for a planning figure, and means nothing recorded.
    func testBlankPlanningAmountsMeanZero() throws {
        let record = try XCTUnwrap(try? FinanceActionValidator
            .creditAccount(from: accountAction(minimum: "", planned: ""), existing: nil).get())
        XCTAssertEqual(record.minimumPaymentMinorUnits, 0)
        XCTAssertEqual(record.plannedPaymentMinorUnits, 0)
    }

    func testAccountWithoutADueDateIsRefused() {
        let result = FinanceActionValidator.creditAccount(
            from: accountAction(due: ""), existing: nil)
        XCTAssertThrowsError(try result.get())
    }

    // MARK: - Planning setup

    func testProfileRoundTrips() throws {
        let action = decode("""
        {"action":"saveProfile","openingCash":"4200.00","recurringIncome":"6000.00",
         "nextIncomeOn":"2026-09-15","monthlyDebtBudget":"500.00","buffer":"1000.00"}
        """)!
        let record = try XCTUnwrap(try? FinanceActionValidator
            .profile(from: action, existing: FinanceProfile()).get())
        XCTAssertEqual(record.openingCashMinorUnits, 420000)
        XCTAssertEqual(record.recurringIncomeMinorUnits, 600000)
        XCTAssertEqual(record.monthlyDebtBudgetMinorUnits, 50000)
        XCTAssertEqual(record.bufferMinorUnits, 100000)
        XCTAssertTrue(record.isConfigured)
    }

    func testProfileWithNonsenseCashIsRefused() {
        let action = decode("""
        {"action":"saveProfile","openingCash":"lots","recurringIncome":"0",
         "nextIncomeOn":"2026-09-15","monthlyDebtBudget":"0","buffer":"0"}
        """)!
        XCTAssertThrowsError(try FinanceActionValidator
            .profile(from: action, existing: FinanceProfile()).get())
    }

    // MARK: - Dates

    func testDatesRoundTripThroughTheBridgeFormat() throws {
        let date = try XCTUnwrap(FinanceDate.parse("2026-09-09"))
        XCTAssertEqual(FinanceDate.string(date), "2026-09-09")
    }

    /// The format is fixed rather than the machine's, so a day-first locale
    /// cannot turn 3 September into 9 March.
    func testDateFormatIsNotTheMachinesLocale() {
        XCTAssertNil(FinanceDate.parse("09/03/2026"))
        XCTAssertNil(FinanceDate.parse("3 Sep 2026"))
    }
}
