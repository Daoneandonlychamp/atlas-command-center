import Foundation
import SQLCipher

/// Encrypted local store for money going out.
///
/// Same construction as `ChatStore` and `CRMStore`: SQLCipher unlocked with a
/// raw 256-bit key held in the login Keychain, never a passphrase and never a
/// file on disk. What you pay for, and when, is exactly the sort of thing that
/// should be unreadable to anything that copies the file.
///
/// A separate database from the CRM's on purpose — different data, different
/// key, so one being open never implies the other.
public final class ExpenseStore {
    public static let shared = ExpenseStore()

    private static let keychainAccount = "atlas.expenses.db.key"

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.atlas.app.expensestore")
    public let databaseURL: URL
    public private(set) var openFailure: String?

    public init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL()
        queue.sync { open() }
    }

    deinit { if let db { sqlite3_close(db) } }

    private static func defaultDatabaseURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ATLAS", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("expenses.sqlite")
    }

    // MARK: - Open

    private func databaseKey() -> String? {
        DatabaseKey.resolve(account: Self.keychainAccount,
                            databaseURL: databaseURL,
                            name: "expenses",
                            failure: &openFailure)
    }

    private func open() {
        guard let key = databaseKey() else {
            openFailure = "Could not create or read the expenses encryption key in the Keychain."
            return
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            openFailure = "Could not open \(databaseURL.lastPathComponent)."
            if let handle { sqlite3_close(handle) }
            return
        }
        db = handle
        guard exec("PRAGMA key = \"x'\(key)'\";") else {
            openFailure = "Could not unlock the expenses database."
            close(); return
        }
        guard exec("SELECT count(*) FROM sqlite_master;") else {
            openFailure = DatabaseKey.mismatchMessage(name: "expenses", fileName: "expenses.sqlite")
            close(); return
        }
        _ = exec("PRAGMA foreign_keys = ON;")
        _ = exec("PRAGMA journal_mode = WAL;")
        migrate()
    }

    private func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    // MARK: - Migrations

    /// One schema step.
    ///
    /// `addColumn` exists because `ALTER TABLE ADD COLUMN` is not idempotent —
    /// replaying it against a table that already has the column is an error,
    /// which would strand a database halfway through an upgrade. Checking
    /// `table_info` first makes every step safe to run twice.
    enum Migration {
        case sql(String)
        case addColumn(table: String, column: String, definition: String)
    }

    /// Ordered, additive schema steps.
    ///
    /// Only CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS and
    /// `addColumn` — never a DROP, never a table rewrite, so anything already in
    /// the file that these do not mention is left alone. The index of a step is
    /// its version. Append; never reorder or edit one that has shipped.
    static let migrations: [Migration] = [
        // 1 — subscriptions and one-off expenses.
        .sql("""
        CREATE TABLE IF NOT EXISTS subscriptions (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            amountMinorUnits INTEGER NOT NULL DEFAULT 0,
            currency TEXT NOT NULL DEFAULT 'usd',
            cadence TEXT NOT NULL DEFAULT 'monthly',
            nextDueOn REAL NOT NULL,
            category TEXT NOT NULL DEFAULT 'software',
            source TEXT NOT NULL DEFAULT 'manual',
            providerKey TEXT NOT NULL DEFAULT '',
            notes TEXT NOT NULL DEFAULT '',
            isActive INTEGER NOT NULL DEFAULT 1,
            previousAmountMinorUnits INTEGER,
            priceChangedAt REAL,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS expenses (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            amountMinorUnits INTEGER NOT NULL DEFAULT 0,
            currency TEXT NOT NULL DEFAULT 'usd',
            category TEXT NOT NULL DEFAULT 'other',
            spentOn REAL NOT NULL,
            notes TEXT NOT NULL DEFAULT '',
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL
        );
        """),

        // 2 — indexes for the three queries the UI runs: due-soon, the month
        // rollup, and finding a pre-filled provider row again.
        .sql("""
        CREATE INDEX IF NOT EXISTS subscriptions_by_due ON subscriptions (isActive, nextDueOn);
        CREATE INDEX IF NOT EXISTS subscriptions_by_provider ON subscriptions (providerKey);
        CREATE INDEX IF NOT EXISTS expenses_by_date ON expenses (spentOn DESC);
        """),

        // 3 — the identifiers of the reminder and event ATLAS created for a due
        // date, so a sync updates what it made last time instead of stacking up
        // duplicates.
        .addColumn(table: "subscriptions", column: "reminderId",
                   definition: "TEXT NOT NULL DEFAULT ''"),
        .addColumn(table: "subscriptions", column: "eventId",
                   definition: "TEXT NOT NULL DEFAULT ''"),
        .addColumn(table: "subscriptions", column: "syncedDueOn", definition: "REAL"),

        // 4 — a price rise you already know about, recorded before it lands.
        .addColumn(table: "subscriptions", column: "scheduledAmountMinorUnits",
                   definition: "INTEGER"),
        .addColumn(table: "subscriptions", column: "scheduledFrom", definition: "REAL"),

        // 5 — credit planning and the user's small set of cash-flow assumptions.
        // These tables intentionally contain no account numbers or credentials.
        .sql("""
        CREATE TABLE IF NOT EXISTS credit_accounts (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            balanceMinorUnits INTEGER NOT NULL DEFAULT 0,
            creditLimitMinorUnits INTEGER NOT NULL DEFAULT 0,
            aprBasisPoints INTEGER NOT NULL DEFAULT 0,
            minimumPaymentMinorUnits INTEGER NOT NULL DEFAULT 0,
            plannedPaymentMinorUnits INTEGER NOT NULL DEFAULT 0,
            paymentDueOn REAL NOT NULL,
            statementClosesOn REAL NOT NULL,
            autopayEnabled INTEGER NOT NULL DEFAULT 0,
            openedOn REAL NOT NULL,
            isActive INTEGER NOT NULL DEFAULT 1,
            notes TEXT NOT NULL DEFAULT '',
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS credit_accounts_by_due
            ON credit_accounts (isActive, paymentDueOn);
        CREATE TABLE IF NOT EXISTS finance_profile (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            openingCashMinorUnits INTEGER NOT NULL DEFAULT 0,
            recurringIncomeMinorUnits INTEGER NOT NULL DEFAULT 0,
            nextIncomeOn REAL NOT NULL,
            monthlyDebtBudgetMinorUnits INTEGER NOT NULL DEFAULT 0,
            bufferMinorUnits INTEGER NOT NULL DEFAULT 0,
            updatedAt REAL NOT NULL
        );
        """)
    ]

    /// True when `table` already has `column`.
    private func hasColumn(_ table: String, _ column: String) -> Bool {
        // PRAGMA will not take a bound parameter; the table name is a literal
        // from the migration list above, never anything a caller supplied.
        query("PRAGMA table_info(\(table));", []) { text($0, 1) }.contains(column)
    }

    private func apply(_ migration: Migration) -> Bool {
        switch migration {
        case .sql(let statements):
            return exec(statements)
        case .addColumn(let table, let column, let definition):
            if hasColumn(table, column) { return true }
            return exec("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
        }
    }

    public static var currentSchemaVersion: Int { migrations.count }

    @discardableResult
    func migrate() -> Bool {
        let from = schemaVersion()
        guard from < Self.migrations.count else { return true }
        for version in from..<Self.migrations.count {
            guard apply(Self.migrations[version]) else {
                NSLog("[ATLAS Expenses] migration %d failed; stopping at %d", version + 1, version)
                setSchemaVersion(version)
                openFailure = "The expenses database could not be upgraded past version \(version)."
                return false
            }
        }
        setSchemaVersion(Self.migrations.count)
        return true
    }

    public func schemaVersion() -> Int {
        guard let statement = prepare("PRAGMA user_version;", []) else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func setSchemaVersion(_ version: Int) {
        _ = exec("PRAGMA user_version = \(version);")
    }

    // MARK: - Statement helpers

    private var lastError: String {
        guard let db, let message = sqlite3_errmsg(db) else { return "no database" }
        return String(cString: message)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var error: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK
        if let error {
            NSLog("[ATLAS Expenses] sql error: %@", String(cString: error))
            sqlite3_free(error)
        }
        return ok
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ bindings: [Any?]) -> OpaquePointer? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            NSLog("[ATLAS Expenses] prepare failed: %@ — %@", sql, lastError)
            return nil
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case let flag as Bool: sqlite3_bind_int64(statement, index, flag ? 1 : 0)
            case let number as Int: sqlite3_bind_int64(statement, index, Int64(number))
            case let number as Double: sqlite3_bind_double(statement, index, number)
            case let date as Date: sqlite3_bind_double(statement, index, date.timeIntervalSince1970)
            default: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    @discardableResult
    private func run(_ sql: String, _ bindings: [Any?] = []) -> Bool {
        guard let statement = prepare(sql, bindings) else { return false }
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code != SQLITE_DONE && code != SQLITE_ROW {
            NSLog("[ATLAS Expenses] step failed: %@ — %@", sql, lastError)
            return false
        }
        return true
    }

    private func query<T>(_ sql: String, _ bindings: [Any?] = [], _ row: (OpaquePointer) -> T) -> [T] {
        guard let statement = prepare(sql, bindings) else { return [] }
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { results.append(row(statement)) }
        return results
    }

    private func count(_ sql: String, _ bindings: [Any?] = []) -> Int {
        query(sql, bindings) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    private func text(_ s: OpaquePointer, _ c: Int32) -> String {
        guard let v = sqlite3_column_text(s, c) else { return "" }
        return String(cString: v)
    }

    private func optionalInt(_ s: OpaquePointer, _ c: Int32) -> Int? {
        sqlite3_column_type(s, c) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, c))
    }

    private func optionalDate(_ s: OpaquePointer, _ c: Int32) -> Date? {
        sqlite3_column_type(s, c) == SQLITE_NULL ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(s, c))
    }

    private func date(_ s: OpaquePointer, _ c: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(s, c))
    }

    public func revealDatabaseKey() -> String? {
        KeychainManager.shared.get(key: Self.keychainAccount)
    }

    // MARK: - Subscriptions

    /// Saves a subscription.
    ///
    /// When the amount differs from what is already stored, the old figure is
    /// kept in `previousAmountMinorUnits` so a silent price rise is visible
    /// rather than simply overwritten. Pass `acknowledgingPriceChange` to clear
    /// that flag once it has been seen.
    @discardableResult
    public func upsert(_ subscription: Subscription,
                       acknowledgingPriceChange: Bool = false) -> Subscription {
        queue.sync {
            var record = subscription
            record.updatedAt = Date()

            let existing = loadSubscription(record.id)
            if acknowledgingPriceChange {
                record.previousAmountMinorUnits = nil
                record.priceChangedAt = nil
            } else if let existing, existing.amountMinorUnits != record.amountMinorUnits {
                record.previousAmountMinorUnits = existing.amountMinorUnits
                record.priceChangedAt = Date()
            } else if let existing {
                record.previousAmountMinorUnits = existing.previousAmountMinorUnits
                record.priceChangedAt = existing.priceChangedAt
            }

            run("""
            INSERT INTO subscriptions
              (id, name, amountMinorUnits, currency, cadence, nextDueOn, category, source,
               providerKey, notes, isActive, previousAmountMinorUnits, priceChangedAt,
               scheduledAmountMinorUnits, scheduledFrom, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name, amountMinorUnits = excluded.amountMinorUnits,
              currency = excluded.currency, cadence = excluded.cadence,
              nextDueOn = excluded.nextDueOn, category = excluded.category,
              source = excluded.source, providerKey = excluded.providerKey,
              notes = excluded.notes, isActive = excluded.isActive,
              previousAmountMinorUnits = excluded.previousAmountMinorUnits,
              priceChangedAt = excluded.priceChangedAt,
              scheduledAmountMinorUnits = excluded.scheduledAmountMinorUnits,
              scheduledFrom = excluded.scheduledFrom, updatedAt = excluded.updatedAt;
            """, [record.id, record.name, record.amountMinorUnits, record.currency,
                  record.cadence.rawValue, record.nextDueOn, record.category.rawValue,
                  record.source.rawValue, record.providerKey, record.notes, record.isActive,
                  record.previousAmountMinorUnits, record.priceChangedAt,
                  record.scheduledAmountMinorUnits, record.scheduledFrom,
                  record.createdAt, record.updatedAt])
            return record
        }
    }

    private func loadSubscription(_ id: String) -> Subscription? {
        query("SELECT * FROM subscriptions WHERE id = ?;", [id], Self.readSubscription(self)).first
    }

    private static func readSubscription(_ store: ExpenseStore) -> (OpaquePointer) -> Subscription {
        { row in
            Subscription(
                id: store.text(row, 0),
                name: store.text(row, 1),
                amountMinorUnits: Int(sqlite3_column_int64(row, 2)),
                currency: store.text(row, 3),
                cadence: BillingCadence(rawValue: store.text(row, 4)) ?? .monthly,
                nextDueOn: store.date(row, 5),
                category: ExpenseCategory(rawValue: store.text(row, 6)) ?? .software,
                source: ExpenseSource(rawValue: store.text(row, 7)) ?? .manual,
                providerKey: store.text(row, 8),
                notes: store.text(row, 9),
                isActive: sqlite3_column_int64(row, 10) != 0,
                previousAmountMinorUnits: store.optionalInt(row, 11),
                priceChangedAt: store.optionalDate(row, 12),
                scheduledAmountMinorUnits: store.optionalInt(row, 18),
                scheduledFrom: store.optionalDate(row, 19),
                createdAt: store.date(row, 13),
                updatedAt: store.date(row, 14)
            )
        }
    }

    public func subscriptions(includeInactive: Bool = true) -> [Subscription] {
        queue.sync {
            let sql = includeInactive
                ? "SELECT * FROM subscriptions ORDER BY nextDueOn ASC;"
                : "SELECT * FROM subscriptions WHERE isActive = 1 ORDER BY nextDueOn ASC;"
            return query(sql, [], Self.readSubscription(self))
        }
    }

    public func subscription(providerKey: String) -> Subscription? {
        guard !providerKey.isEmpty else { return nil }
        return queue.sync {
            query("SELECT * FROM subscriptions WHERE providerKey = ? LIMIT 1;",
                  [providerKey], Self.readSubscription(self)).first
        }
    }

    @discardableResult
    public func deleteSubscription(_ id: String) -> DeleteOutcome {
        queue.sync {
            guard count("SELECT count(*) FROM subscriptions WHERE id = ?;", [id]) > 0 else {
                return .notFound
            }
            run("DELETE FROM subscriptions WHERE id = ?;", [id])
            return .deleted
        }
    }

    /// Records that a bill was paid: rolls the due date forward one cadence step.
    @discardableResult
    public func markPaid(_ id: String, asOf now: Date = Date(),
                         calendar: Calendar = .current) -> Subscription? {
        guard var record = subscriptions().first(where: { $0.id == id }) else { return nil }
        record.nextDueOn = BillSchedule.advance(record.nextDueOn, by: record.cadence,
                                                calendar: calendar)
        // A long-dormant bill can still be behind after one step; catch it up.
        record.nextDueOn = BillSchedule.nextDue(from: record.nextDueOn, cadence: record.cadence,
                                                asOf: now, calendar: calendar)
        return upsert(record)
    }

    /// Stores the calendar identifiers a sync produced.
    public func recordSync(_ id: String, reminderId: String, eventId: String, dueOn: Date) {
        queue.sync {
            run("UPDATE subscriptions SET reminderId = ?, eventId = ?, syncedDueOn = ? WHERE id = ?;",
                [reminderId, eventId, dueOn, id])
        }
    }

    /// The identifiers a previous sync wrote, so it can update rather than duplicate.
    public func syncState(_ id: String) -> (reminderId: String, eventId: String, dueOn: Date?)? {
        queue.sync {
            query("SELECT reminderId, eventId, syncedDueOn FROM subscriptions WHERE id = ?;", [id]) {
                (text($0, 0), text($0, 1), optionalDate($0, 2))
            }.first
        }
    }

    /// Applies any scheduled change whose date has arrived.
    ///
    /// The new amount simply becomes the amount — no "price changed" flag,
    /// because this one was expected and recorded in advance. That flag is for
    /// rises nobody told you about.
    @discardableResult
    public func settleScheduledPriceChanges(asOf now: Date = Date(),
                                            calendar: Calendar = .current) -> Int {
        var applied = 0
        for var record in subscriptions() where record.scheduledChangeIsDue(asOf: now, calendar: calendar) {
            guard let scheduled = record.scheduledAmountMinorUnits else { continue }
            record.amountMinorUnits = scheduled
            record.scheduledAmountMinorUnits = nil
            record.scheduledFrom = nil
            upsert(record, acknowledgingPriceChange: true)
            applied += 1
        }
        return applied
    }

    // MARK: - Expenses

    @discardableResult
    public func upsert(_ expense: Expense) -> Expense {
        queue.sync {
            var record = expense
            record.updatedAt = Date()
            run("""
            INSERT INTO expenses (id, name, amountMinorUnits, currency, category, spentOn,
                                  notes, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name, amountMinorUnits = excluded.amountMinorUnits,
              currency = excluded.currency, category = excluded.category,
              spentOn = excluded.spentOn, notes = excluded.notes,
              updatedAt = excluded.updatedAt;
            """, [record.id, record.name, record.amountMinorUnits, record.currency,
                  record.category.rawValue, record.spentOn, record.notes,
                  record.createdAt, record.updatedAt])
            return record
        }
    }

    public func expenses(from start: Date? = nil, to end: Date? = nil, limit: Int = 500) -> [Expense] {
        queue.sync {
            var sql = "SELECT * FROM expenses"
            var clauses: [String] = []
            var bindings: [Any?] = []
            if let start { clauses.append("spentOn >= ?"); bindings.append(start) }
            if let end { clauses.append("spentOn < ?"); bindings.append(end) }
            if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
            sql += " ORDER BY spentOn DESC LIMIT ?;"
            bindings.append(limit)

            return query(sql, bindings) { row in
                Expense(id: text(row, 0), name: text(row, 1),
                        amountMinorUnits: Int(sqlite3_column_int64(row, 2)),
                        currency: text(row, 3),
                        category: ExpenseCategory(rawValue: text(row, 4)) ?? .other,
                        spentOn: date(row, 5), notes: text(row, 6),
                        createdAt: date(row, 7), updatedAt: date(row, 8))
            }
        }
    }

    @discardableResult
    public func deleteExpense(_ id: String) -> DeleteOutcome {
        queue.sync {
            guard count("SELECT count(*) FROM expenses WHERE id = ?;", [id]) > 0 else { return .notFound }
            run("DELETE FROM expenses WHERE id = ?;", [id])
            return .deleted
        }
    }

    // MARK: - Credit planning

    @discardableResult
    public func upsert(_ account: CreditAccount) -> CreditAccount {
        queue.sync {
            var record = account
            record.balanceMinorUnits = max(0, record.balanceMinorUnits)
            record.creditLimitMinorUnits = max(0, record.creditLimitMinorUnits)
            record.aprBasisPoints = max(0, record.aprBasisPoints)
            record.minimumPaymentMinorUnits = max(0, record.minimumPaymentMinorUnits)
            record.plannedPaymentMinorUnits = max(0, record.plannedPaymentMinorUnits)
            record.updatedAt = Date()
            run("""
            INSERT INTO credit_accounts
              (id, name, balanceMinorUnits, creditLimitMinorUnits, aprBasisPoints,
               minimumPaymentMinorUnits, plannedPaymentMinorUnits, paymentDueOn,
               statementClosesOn, autopayEnabled, openedOn, isActive, notes, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name, balanceMinorUnits = excluded.balanceMinorUnits,
              creditLimitMinorUnits = excluded.creditLimitMinorUnits,
              aprBasisPoints = excluded.aprBasisPoints,
              minimumPaymentMinorUnits = excluded.minimumPaymentMinorUnits,
              plannedPaymentMinorUnits = excluded.plannedPaymentMinorUnits,
              paymentDueOn = excluded.paymentDueOn,
              statementClosesOn = excluded.statementClosesOn,
              autopayEnabled = excluded.autopayEnabled, openedOn = excluded.openedOn,
              isActive = excluded.isActive, notes = excluded.notes,
              updatedAt = excluded.updatedAt;
            """, [record.id, record.name, record.balanceMinorUnits,
                  record.creditLimitMinorUnits, record.aprBasisPoints,
                  record.minimumPaymentMinorUnits, record.plannedPaymentMinorUnits,
                  record.paymentDueOn, record.statementClosesOn, record.autopayEnabled,
                  record.openedOn, record.isActive, record.notes,
                  record.createdAt, record.updatedAt])
            return record
        }
    }

    public func creditAccounts(includeInactive: Bool = true) -> [CreditAccount] {
        queue.sync {
            let sql = includeInactive
                ? "SELECT * FROM credit_accounts ORDER BY paymentDueOn ASC;"
                : "SELECT * FROM credit_accounts WHERE isActive = 1 ORDER BY paymentDueOn ASC;"
            return query(sql) { row in
                CreditAccount(id: text(row, 0), name: text(row, 1),
                              balanceMinorUnits: Int(sqlite3_column_int64(row, 2)),
                              creditLimitMinorUnits: Int(sqlite3_column_int64(row, 3)),
                              aprBasisPoints: Int(sqlite3_column_int64(row, 4)),
                              minimumPaymentMinorUnits: Int(sqlite3_column_int64(row, 5)),
                              plannedPaymentMinorUnits: Int(sqlite3_column_int64(row, 6)),
                              paymentDueOn: date(row, 7), statementClosesOn: date(row, 8),
                              autopayEnabled: sqlite3_column_int64(row, 9) != 0,
                              openedOn: date(row, 10),
                              isActive: sqlite3_column_int64(row, 11) != 0,
                              notes: text(row, 12), createdAt: date(row, 13),
                              updatedAt: date(row, 14))
            }
        }
    }

    @discardableResult
    public func saveFinanceProfile(_ profile: FinanceProfile) -> FinanceProfile {
        queue.sync {
            var record = profile
            record.openingCashMinorUnits = max(0, record.openingCashMinorUnits)
            record.recurringIncomeMinorUnits = max(0, record.recurringIncomeMinorUnits)
            record.monthlyDebtBudgetMinorUnits = max(0, record.monthlyDebtBudgetMinorUnits)
            record.bufferMinorUnits = max(0, record.bufferMinorUnits)
            record.updatedAt = Date()
            run("""
            INSERT INTO finance_profile
              (id, openingCashMinorUnits, recurringIncomeMinorUnits, nextIncomeOn,
               monthlyDebtBudgetMinorUnits, bufferMinorUnits, updatedAt)
            VALUES (1, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              openingCashMinorUnits = excluded.openingCashMinorUnits,
              recurringIncomeMinorUnits = excluded.recurringIncomeMinorUnits,
              nextIncomeOn = excluded.nextIncomeOn,
              monthlyDebtBudgetMinorUnits = excluded.monthlyDebtBudgetMinorUnits,
              bufferMinorUnits = excluded.bufferMinorUnits,
              updatedAt = excluded.updatedAt;
            """, [record.openingCashMinorUnits, record.recurringIncomeMinorUnits,
                  record.nextIncomeOn, record.monthlyDebtBudgetMinorUnits,
                  record.bufferMinorUnits, record.updatedAt])
            return record
        }
    }

    public func financeProfile() -> FinanceProfile {
        queue.sync {
            query("SELECT openingCashMinorUnits, recurringIncomeMinorUnits, nextIncomeOn, "
                  + "monthlyDebtBudgetMinorUnits, bufferMinorUnits, updatedAt "
                  + "FROM finance_profile WHERE id = 1;") { row in
                FinanceProfile(openingCashMinorUnits: Int(sqlite3_column_int64(row, 0)),
                               recurringIncomeMinorUnits: Int(sqlite3_column_int64(row, 1)),
                               nextIncomeOn: date(row, 2),
                               monthlyDebtBudgetMinorUnits: Int(sqlite3_column_int64(row, 3)),
                               bufferMinorUnits: Int(sqlite3_column_int64(row, 4)),
                               updatedAt: date(row, 5))
            }.first ?? FinanceProfile()
        }
    }

    // MARK: - Rollups

    public func summary(asOf now: Date = Date(), dueWithinDays: Int = 14,
                        calendar: Calendar = .current) -> SpendSummary {
        let active = subscriptions().filter(\.isActive)
        let dueSoon = active.filter {
            let days = BillSchedule.daysUntil($0.nextDueOn, asOf: now, calendar: calendar)
            return days >= 0 && days <= dueWithinDays
        }
        let overdue = active.filter {
            BillSchedule.daysUntil($0.nextDueOn, asOf: now, calendar: calendar) < 0
        }
        return SpendSummary(
            activeSubscriptions: active.count,
            monthlyCommittedMinorUnits: active.reduce(0) { $0 + $1.monthlyEquivalentMinorUnits },
            yearlyCommittedMinorUnits: active.reduce(0) { $0 + $1.yearlyMinorUnits },
            dueSoonCount: dueSoon.count,
            dueSoonMinorUnits: dueSoon.reduce(0) { $0 + $1.amountMinorUnits },
            overdueCount: overdue.count,
            priceChangeCount: active.filter(\.hasUnacknowledgedPriceChange).count,
            futureMonthlyMinorUnits: active.reduce(0) { $0 + $1.futureMonthlyEquivalentMinorUnits },
            pendingPriceChangeCount: active.filter {
                $0.hasPendingPriceChange(asOf: now, calendar: calendar)
            }.count
        )
    }

    /// Subscriptions due within the window, soonest first, overdue included.
    public func dueSoon(within days: Int = 14, asOf now: Date = Date(),
                        calendar: Calendar = .current) -> [Subscription] {
        subscriptions()
            .filter(\.isActive)
            .filter { BillSchedule.daysUntil($0.nextDueOn, asOf: now, calendar: calendar) <= days }
            .sorted { $0.nextDueOn < $1.nextDueOn }
    }

    /// One month of money out, with income left nil for the caller to fill from
    /// the Stripe snapshot — this store knows nothing about revenue.
    public func cashFlow(for month: Date, calendar: Calendar = .current) -> CashFlowMonth {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start

        // Each occurrence is costed at the price effective on its own date, so
        // a month that straddles a rise is right rather than averaged.
        let subs = subscriptions().filter(\.isActive).reduce(0) { total, subscription in
            BillSchedule.occurrences(of: subscription, from: start, to: end, calendar: calendar)
                .reduce(total) { $0 + subscription.amountMinorUnits(on: $1, calendar: calendar) }
        }
        let spent = expenses(from: start, to: end).reduce(0) { $0 + $1.amountMinorUnits }
        return CashFlowMonth(month: start, subscriptionsMinorUnits: subs, expensesMinorUnits: spent)
    }
}
