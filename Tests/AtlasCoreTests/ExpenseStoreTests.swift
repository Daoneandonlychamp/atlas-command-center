import XCTest
import SQLCipher
@testable import AtlasCore

/// Checks the money-going-out store: scheduling, rollups, price-change
/// detection, migrations and encryption at rest.
///
/// Every test runs against a database in a temporary directory. The real
/// `expenses.sqlite` in Application Support is never opened, and nothing here
/// touches EventKit — the calendar half is pure planning, tested separately.
final class ExpenseStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ExpenseStore!
    /// A fixed calendar so month arithmetic does not depend on where this runs.
    private var calendar: Calendar!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AtlasExpenseTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ExpenseStore(databaseURL: directory.appendingPathComponent("expenses.sqlite"))
        XCTAssertNil(store.openFailure, "store should open: \(store.openFailure ?? "")")

        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - Models

    func testModelsRoundTripThroughJSON() throws {
        let subscription = Subscription(name: "Adobe CC", amountMinorUnits: 5999,
                                        cadence: .monthly, nextDueOn: day(2026, 10, 12),
                                        category: .software, notes: "annual plan, billed monthly")
        let expense = Expense(name: "Domain renewal", amountMinorUnits: 1400,
                              category: .services, spentOn: day(2026, 9, 3))
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(Subscription.self, from: encoder.encode(subscription)),
                       subscription)
        XCTAssertEqual(try decoder.decode(Expense.self, from: encoder.encode(expense)), expense)
    }

    func testCadenceNormalisesToAComparableMonthlyFigure() {
        let yearly = Subscription(name: "Yearly", amountMinorUnits: 12000, cadence: .yearly)
        let monthly = Subscription(name: "Monthly", amountMinorUnits: 1000, cadence: .monthly)
        let weekly = Subscription(name: "Weekly", amountMinorUnits: 100, cadence: .weekly)

        XCTAssertEqual(yearly.monthlyEquivalentMinorUnits, 1000)
        XCTAssertEqual(monthly.monthlyEquivalentMinorUnits, 1000)
        XCTAssertEqual(weekly.monthlyEquivalentMinorUnits, 433, "52 weeks / 12 months")
        XCTAssertEqual(yearly.yearlyMinorUnits, 12000)
        XCTAssertEqual(monthly.yearlyMinorUnits, 12000)
    }

    // MARK: - Scheduling

    func testAdvanceStepsByTheCadence() {
        let start = day(2026, 1, 15)
        XCTAssertEqual(BillSchedule.advance(start, by: .weekly, calendar: calendar), day(2026, 1, 22))
        XCTAssertEqual(BillSchedule.advance(start, by: .monthly, calendar: calendar), day(2026, 2, 15))
        XCTAssertEqual(BillSchedule.advance(start, by: .quarterly, calendar: calendar), day(2026, 4, 15))
        XCTAssertEqual(BillSchedule.advance(start, by: .yearly, calendar: calendar), day(2027, 1, 15))
    }

    /// A monthly bill anchored on the 31st has to land on the last day of a
    /// short month rather than spilling into the next one.
    func testMonthlyBillOnTheThirtyFirstClampsToShortMonths() {
        let jan31 = day(2026, 1, 31)
        let next = BillSchedule.advance(jan31, by: .monthly, calendar: calendar)
        XCTAssertEqual(calendar.component(.month, from: next), 2)
        XCTAssertEqual(calendar.component(.day, from: next), 28, "February, not the 3rd of March")
    }

    func testNextDueRollsPastMissedPaymentsButKeepsToday() {
        let anchor = day(2026, 1, 10)
        let now = day(2026, 4, 20)
        let next = BillSchedule.nextDue(from: anchor, cadence: .monthly, asOf: now, calendar: calendar)
        XCTAssertEqual(next, day(2026, 5, 10), "shows the next payment, not the missed ones")

        // A bill due today is due today, not next month.
        let today = day(2026, 4, 10)
        XCTAssertEqual(BillSchedule.nextDue(from: anchor, cadence: .monthly,
                                            asOf: today, calendar: calendar),
                       day(2026, 4, 10))
    }

    func testDaysUntilIsNegativeWhenOverdue() {
        let now = day(2026, 9, 7)
        XCTAssertEqual(BillSchedule.daysUntil(day(2026, 9, 12), asOf: now, calendar: calendar), 5)
        XCTAssertEqual(BillSchedule.daysUntil(day(2026, 9, 7), asOf: now, calendar: calendar), 0)
        XCTAssertEqual(BillSchedule.daysUntil(day(2026, 9, 1), asOf: now, calendar: calendar), -6)
    }

    func testOccurrencesLandsEveryHitInAMonth() {
        let weekly = Subscription(name: "Weekly", amountMinorUnits: 500, cadence: .weekly,
                                  nextDueOn: day(2026, 9, 1))
        let hits = BillSchedule.occurrences(of: weekly, from: day(2026, 9, 1), to: day(2026, 10, 1),
                                            calendar: calendar)
        XCTAssertEqual(hits.count, 5, "1, 8, 15, 22, 29 September")

        let yearly = Subscription(name: "Yearly", amountMinorUnits: 9900, cadence: .yearly,
                                  nextDueOn: day(2026, 3, 4))
        XCTAssertTrue(BillSchedule.occurrences(of: yearly, from: day(2026, 9, 1),
                                               to: day(2026, 10, 1), calendar: calendar).isEmpty,
                      "a yearly bill due in March does not appear in September")
    }

    func testAnArchivedSubscriptionHasNoOccurrences() {
        let off = Subscription(name: "Cancelled", amountMinorUnits: 500, cadence: .monthly,
                               nextDueOn: day(2026, 9, 5), isActive: false)
        XCTAssertTrue(BillSchedule.occurrences(of: off, from: day(2026, 9, 1),
                                               to: day(2026, 10, 1), calendar: calendar).isEmpty)
    }

    // MARK: - CRUD

    func testSubscriptionCRUD() {
        let created = store.upsert(Subscription(name: "Railway", amountMinorUnits: 800))
        XCTAssertEqual(store.subscriptions().count, 1)

        var edited = created
        edited.name = "Railway Pro"
        store.upsert(edited)
        XCTAssertEqual(store.subscriptions().count, 1, "an update must not insert a second row")
        XCTAssertEqual(store.subscriptions().first?.name, "Railway Pro")

        XCTAssertEqual(store.deleteSubscription(created.id), .deleted)
        XCTAssertEqual(store.deleteSubscription(created.id), .notFound)
    }

    func testExpenseCRUDAndDateWindow() {
        store.upsert(Expense(name: "In range", amountMinorUnits: 1000, spentOn: day(2026, 9, 10)))
        store.upsert(Expense(name: "Out of range", amountMinorUnits: 9999, spentOn: day(2026, 8, 10)))

        let september = store.expenses(from: day(2026, 9, 1), to: day(2026, 10, 1))
        XCTAssertEqual(september.map(\.name), ["In range"])
        XCTAssertEqual(store.expenses().count, 2, "no window means everything")
    }

    func testCreditAccountAndFinanceProfileRoundTrip() {
        let account = CreditAccount(name: "Everyday card", balanceMinorUnits: 42_000,
                                    creditLimitMinorUnits: 100_000,
                                    aprBasisPoints: 2_499,
                                    minimumPaymentMinorUnits: 3_500,
                                    plannedPaymentMinorUnits: 12_000,
                                    paymentDueOn: day(2026, 9, 20),
                                    statementClosesOn: day(2026, 9, 15),
                                    autopayEnabled: true,
                                    openedOn: day(2020, 1, 1))
        let savedAccount = store.upsert(account)
        let loadedAccount = store.creditAccounts().first
        XCTAssertEqual(loadedAccount?.id, savedAccount.id)
        XCTAssertEqual(loadedAccount?.name, "Everyday card")
        XCTAssertEqual(loadedAccount?.balanceMinorUnits, 42_000)
        XCTAssertEqual(loadedAccount?.creditLimitMinorUnits, 100_000)
        XCTAssertEqual(loadedAccount?.aprBasisPoints, 2_499)
        XCTAssertEqual(loadedAccount?.minimumPaymentMinorUnits, 3_500)
        XCTAssertEqual(loadedAccount?.plannedPaymentMinorUnits, 12_000)
        XCTAssertEqual(loadedAccount?.autopayEnabled, true)
        XCTAssertEqual(loadedAccount?.paymentDueOn, day(2026, 9, 20))
        XCTAssertEqual(loadedAccount?.statementClosesOn, day(2026, 9, 15))
        XCTAssertEqual(loadedAccount?.updatedAt.timeIntervalSince1970 ?? 0,
                       savedAccount.updatedAt.timeIntervalSince1970, accuracy: 0.001)

        let profile = FinanceProfile(openingCashMinorUnits: 250_000,
                                     recurringIncomeMinorUnits: 400_000,
                                     nextIncomeOn: day(2026, 9, 15),
                                     monthlyDebtBudgetMinorUnits: 50_000,
                                     bufferMinorUnits: 100_000)
        let saved = store.saveFinanceProfile(profile)
        let loadedProfile = store.financeProfile()
        XCTAssertEqual(loadedProfile.openingCashMinorUnits, 250_000)
        XCTAssertEqual(loadedProfile.recurringIncomeMinorUnits, 400_000)
        XCTAssertEqual(loadedProfile.nextIncomeOn, day(2026, 9, 15))
        XCTAssertEqual(loadedProfile.monthlyDebtBudgetMinorUnits, 50_000)
        XCTAssertEqual(loadedProfile.bufferMinorUnits, 100_000)
        XCTAssertEqual(loadedProfile.updatedAt.timeIntervalSince1970,
                       saved.updatedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testMarkPaidRollsTheDueDateForward() {
        let saved = store.upsert(Subscription(name: "Monthly", amountMinorUnits: 1000,
                                              cadence: .monthly, nextDueOn: day(2026, 9, 5)))
        let paid = store.markPaid(saved.id, asOf: day(2026, 9, 5), calendar: calendar)
        XCTAssertEqual(paid?.nextDueOn, day(2026, 10, 5))
        XCTAssertNil(store.markPaid("no-such-id"))
    }

    // MARK: - Price changes

    func testChangingTheAmountRecordsThePreviousPrice() {
        var saved = store.upsert(Subscription(name: "Creeping", amountMinorUnits: 1000))
        XCTAssertFalse(saved.hasUnacknowledgedPriceChange)

        saved.amountMinorUnits = 1200
        let raised = store.upsert(saved)
        XCTAssertTrue(raised.hasUnacknowledgedPriceChange)
        XCTAssertEqual(raised.previousAmountMinorUnits, 1000)
        XCTAssertEqual(raised.priceDeltaMinorUnits, 200)
        XCTAssertNotNil(raised.priceChangedAt)
    }

    func testAnUnrelatedEditKeepsThePriceFlag() {
        var saved = store.upsert(Subscription(name: "Creeping", amountMinorUnits: 1000))
        saved.amountMinorUnits = 1200
        saved = store.upsert(saved)

        saved.notes = "renamed, price untouched"
        let again = store.upsert(saved)
        XCTAssertTrue(again.hasUnacknowledgedPriceChange, "editing notes must not clear the flag")
        XCTAssertEqual(again.previousAmountMinorUnits, 1000)
    }

    func testAcknowledgingClearsThePriceFlag() {
        var saved = store.upsert(Subscription(name: "Creeping", amountMinorUnits: 1000))
        saved.amountMinorUnits = 1200
        saved = store.upsert(saved)

        let cleared = store.upsert(saved, acknowledgingPriceChange: true)
        XCTAssertFalse(cleared.hasUnacknowledgedPriceChange)
        XCTAssertNil(cleared.previousAmountMinorUnits)
        XCTAssertFalse(store.subscriptions().first!.hasUnacknowledgedPriceChange)
    }

    // MARK: - Scheduled price changes

    /// The Google One case: $2.99 now, $19.99 from 10 October. Recorded up
    /// front, so the forecast is right before it lands.
    func testAKnownFuturePriceIsCostedFromItsStartDate() {
        let sub = Subscription(name: "Google One", amountMinorUnits: 299, cadence: .monthly,
                               nextDueOn: day(2026, 9, 10),
                               scheduledAmountMinorUnits: 1999,
                               scheduledFrom: day(2026, 10, 10))

        XCTAssertEqual(sub.amountMinorUnits(on: day(2026, 9, 10), calendar: calendar), 299)
        XCTAssertEqual(sub.amountMinorUnits(on: day(2026, 10, 9), calendar: calendar), 299)
        XCTAssertEqual(sub.amountMinorUnits(on: day(2026, 10, 10), calendar: calendar), 1999,
                       "the day it starts is charged at the new price")
        XCTAssertEqual(sub.amountMinorUnits(on: day(2026, 11, 10), calendar: calendar), 1999)
    }

    func testTheMonthItRisesIsCostedAtTheNewPriceNotTheOld() {
        store.upsert(Subscription(name: "Google One", amountMinorUnits: 299, cadence: .monthly,
                                  nextDueOn: day(2026, 9, 10),
                                  scheduledAmountMinorUnits: 1999,
                                  scheduledFrom: day(2026, 10, 10)))

        XCTAssertEqual(store.cashFlow(for: day(2026, 9, 15), calendar: calendar)
                        .subscriptionsMinorUnits, 299, "September is still the old price")
        XCTAssertEqual(store.cashFlow(for: day(2026, 10, 15), calendar: calendar)
                        .subscriptionsMinorUnits, 1999, "October has risen")
        XCTAssertEqual(store.cashFlow(for: day(2026, 11, 15), calendar: calendar)
                        .subscriptionsMinorUnits, 1999)
    }

    func testSummaryShowsBothTodaysFigureAndWhatItBecomes() {
        let now = day(2026, 9, 7)
        store.upsert(Subscription(name: "Google One", amountMinorUnits: 299, cadence: .monthly,
                                  nextDueOn: day(2026, 9, 10),
                                  scheduledAmountMinorUnits: 1999,
                                  scheduledFrom: day(2026, 10, 10)))
        store.upsert(Subscription(name: "Steady", amountMinorUnits: 500, cadence: .monthly,
                                  nextDueOn: day(2026, 9, 20)))

        let summary = store.summary(asOf: now, calendar: calendar)
        XCTAssertEqual(summary.monthlyCommittedMinorUnits, 799, "what you pay today")
        XCTAssertEqual(summary.futureMonthlyMinorUnits, 2499, "what it becomes")
        XCTAssertEqual(summary.pendingPriceChangeCount, 1)
    }

    func testAPendingChangeIsOnlyPendingUntilItsDate() {
        let sub = Subscription(name: "Google One", amountMinorUnits: 299,
                               scheduledAmountMinorUnits: 1999,
                               scheduledFrom: day(2026, 10, 10))
        XCTAssertTrue(sub.hasPendingPriceChange(asOf: day(2026, 9, 7), calendar: calendar))
        XCTAssertFalse(sub.hasPendingPriceChange(asOf: day(2026, 10, 10), calendar: calendar))
        XCTAssertEqual(sub.scheduledDeltaMinorUnits, 1700)
    }

    /// Once the date arrives the new price simply becomes the price. It must not
    /// also raise the "price changed without telling you" flag — this one was
    /// announced, and crying wolf about it would train the flag to be ignored.
    func testSettlingAnArrivedChangeDoesNotRaiseTheSurpriseFlag() {
        let saved = store.upsert(Subscription(name: "Google One", amountMinorUnits: 299,
                                              cadence: .monthly, nextDueOn: day(2026, 10, 10),
                                              scheduledAmountMinorUnits: 1999,
                                              scheduledFrom: day(2026, 10, 10)))

        XCTAssertEqual(store.settleScheduledPriceChanges(asOf: day(2026, 10, 11),
                                                         calendar: calendar), 1)
        let after = store.subscriptions().first { $0.id == saved.id }
        XCTAssertEqual(after?.amountMinorUnits, 1999)
        XCTAssertNil(after?.scheduledAmountMinorUnits, "the schedule is spent")
        XCTAssertNil(after?.scheduledFrom)
        XCTAssertFalse(after?.hasUnacknowledgedPriceChange ?? true,
                       "an announced rise is not a surprise")
    }

    func testSettlingLeavesAChangeThatHasNotArrivedAlone() {
        store.upsert(Subscription(name: "Google One", amountMinorUnits: 299,
                                  scheduledAmountMinorUnits: 1999,
                                  scheduledFrom: day(2026, 10, 10)))
        XCTAssertEqual(store.settleScheduledPriceChanges(asOf: day(2026, 9, 7),
                                                         calendar: calendar), 0)
        XCTAssertEqual(store.subscriptions().first?.amountMinorUnits, 299)
    }

    func testAScheduledChangeSurvivesTheRoundTrip() {
        store.upsert(Subscription(name: "Google One", amountMinorUnits: 299,
                                  scheduledAmountMinorUnits: 1999,
                                  scheduledFrom: day(2026, 10, 10)))
        let loaded = store.subscriptions().first
        XCTAssertEqual(loaded?.scheduledAmountMinorUnits, 1999)
        XCTAssertEqual(loaded?.scheduledFrom, day(2026, 10, 10))
    }

    // MARK: - Rollups

    func testSummaryCountsCommittedSpendDueSoonAndOverdue() {
        let now = day(2026, 9, 7)
        store.upsert(Subscription(name: "Monthly", amountMinorUnits: 1000, cadence: .monthly,
                                  nextDueOn: day(2026, 9, 12)))                   // due soon
        store.upsert(Subscription(name: "Yearly", amountMinorUnits: 12000, cadence: .yearly,
                                  nextDueOn: day(2027, 3, 1)))                    // far off
        store.upsert(Subscription(name: "Late", amountMinorUnits: 500, cadence: .monthly,
                                  nextDueOn: day(2026, 9, 1)))                    // overdue
        store.upsert(Subscription(name: "Archived", amountMinorUnits: 9999, cadence: .monthly,
                                  nextDueOn: day(2026, 9, 8), isActive: false))    // ignored

        let summary = store.summary(asOf: now, dueWithinDays: 14, calendar: calendar)
        XCTAssertEqual(summary.activeSubscriptions, 3)
        XCTAssertEqual(summary.monthlyCommittedMinorUnits, 1000 + 1000 + 500)
        XCTAssertEqual(summary.yearlyCommittedMinorUnits, 12000 + 12000 + 6000)
        XCTAssertEqual(summary.dueSoonCount, 1)
        XCTAssertEqual(summary.dueSoonMinorUnits, 1000)
        XCTAssertEqual(summary.overdueCount, 1)
    }

    func testCashFlowSumsSubscriptionsAndExpensesForTheMonth() {
        store.upsert(Subscription(name: "Weekly", amountMinorUnits: 500, cadence: .weekly,
                                  nextDueOn: day(2026, 9, 1)))
        store.upsert(Subscription(name: "Monthly", amountMinorUnits: 2000, cadence: .monthly,
                                  nextDueOn: day(2026, 9, 20)))
        store.upsert(Expense(name: "One off", amountMinorUnits: 750, spentOn: day(2026, 9, 10)))
        store.upsert(Expense(name: "Other month", amountMinorUnits: 9999, spentOn: day(2026, 8, 10)))

        let flow = store.cashFlow(for: day(2026, 9, 15), calendar: calendar)
        XCTAssertEqual(flow.subscriptionsMinorUnits, 5 * 500 + 2000)
        XCTAssertEqual(flow.expensesMinorUnits, 750)
        XCTAssertEqual(flow.outMinorUnits, 5 * 500 + 2000 + 750)
        XCTAssertNil(flow.netMinorUnits, "no income figure means no net, not a net of zero")
    }

    func testNetOnlyAppearsOnceThereIsIncome() {
        var flow = CashFlowMonth(month: day(2026, 9, 1), subscriptionsMinorUnits: 1000,
                                 expensesMinorUnits: 500)
        XCTAssertNil(flow.netMinorUnits)
        flow.incomeMinorUnits = 4000
        XCTAssertEqual(flow.netMinorUnits, 2500)
    }

    func testDueSoonIsSoonestFirstAndIncludesOverdue() {
        let now = day(2026, 9, 7)
        store.upsert(Subscription(name: "Later", amountMinorUnits: 100, nextDueOn: day(2026, 9, 15)))
        store.upsert(Subscription(name: "Overdue", amountMinorUnits: 100, nextDueOn: day(2026, 9, 2)))
        store.upsert(Subscription(name: "Soon", amountMinorUnits: 100, nextDueOn: day(2026, 9, 9)))
        XCTAssertEqual(store.dueSoon(within: 14, asOf: now, calendar: calendar).map(\.name),
                       ["Overdue", "Soon", "Later"])
    }

    // MARK: - Migration and encryption

    func testSchemaIsAtTheCurrentVersion() {
        XCTAssertEqual(store.schemaVersion(), ExpenseStore.currentSchemaVersion)
        XCTAssertGreaterThanOrEqual(ExpenseStore.currentSchemaVersion, 3)
    }

    /// The migration runner is additive: replaying every step over a populated
    /// file must keep both the real records and a table it has never heard of.
    func testMigrationPreservesUnknownDataAndReplaysCleanly() throws {
        store.upsert(Subscription(name: "Keep me", amountMinorUnits: 1234))
        store.upsert(Expense(name: "Keep this too", amountMinorUnits: 99))
        let url = store.databaseURL
        let key = try XCTUnwrap(store.revealDatabaseKey())
        store = nil

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle,
                                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        let raw = try XCTUnwrap(handle)
        XCTAssertEqual(sqlite3_exec(raw, "PRAGMA key = \"x'\(key)'\";", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, """
        CREATE TABLE future_feature (id TEXT PRIMARY KEY, payload TEXT);
        INSERT INTO future_feature VALUES ('a', 'do not lose me');
        PRAGMA user_version = 0;
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let migrated = ExpenseStore(databaseURL: url)
        XCTAssertNil(migrated.openFailure)
        XCTAssertEqual(migrated.schemaVersion(), ExpenseStore.currentSchemaVersion)
        XCTAssertEqual(migrated.subscriptions().map(\.name), ["Keep me"])
        XCTAssertEqual(migrated.expenses().map(\.name), ["Keep this too"])

        var check: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &check,
                                       SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        let reader = try XCTUnwrap(check)
        XCTAssertEqual(sqlite3_exec(reader, "PRAGMA key = \"x'\(key)'\";", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(reader, "SELECT payload FROM future_feature WHERE id='a';",
                                          -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "do not lose me")
        sqlite3_finalize(statement)
        sqlite3_close(reader)
    }

    func testDatabaseFileIsNotReadableAsPlainSQLite() throws {
        store.upsert(Subscription(name: "Confidential Retainer", notes: "sensitive-marker-string"))
        let url = store.databaseURL
        store = nil

        let bytes = try Data(contentsOf: url)
        XCTAssertFalse(bytes.starts(with: Array("SQLite format 3".utf8)))
        XCTAssertNil(bytes.range(of: Data("sensitive-marker-string".utf8)))
        XCTAssertNil(bytes.range(of: Data("Confidential Retainer".utf8)))
    }

    func testEmptyStoreReportsEmptyRatherThanFailing() {
        XCTAssertTrue(store.subscriptions().isEmpty)
        XCTAssertTrue(store.expenses().isEmpty)
        XCTAssertTrue(store.creditAccounts().isEmpty)
        XCTAssertTrue(store.dueSoon().isEmpty)
        let summary = store.summary()
        XCTAssertEqual(summary.activeSubscriptions, 0)
        XCTAssertEqual(summary.monthlyCommittedMinorUnits, 0)
    }
}
