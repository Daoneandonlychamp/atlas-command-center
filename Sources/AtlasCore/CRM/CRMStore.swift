import Foundation
import SQLCipher

/// Encrypted local store for the CRM.
///
/// Same construction as `ChatStore`: a SQLCipher database unlocked with a raw
/// 256-bit key held in the login Keychain, never a passphrase and never a file
/// on disk. Client names, deal sizes and notes are exactly the kind of thing
/// that should be unreadable to anything that copies the file, Time Machine
/// included.
///
/// This is a separate database from `chat.sqlite` on purpose — a different kind
/// of data with a different key, so one being opened never implies the other.
public final class CRMStore {
    public static let shared = CRMStore()

    /// Keychain account holding the hex-encoded 256-bit database key.
    private static let keychainAccount = "atlas.crm.db.key"

    private var db: OpaquePointer?
    /// Every statement runs here; the C handle is not thread-safe across queues.
    private let queue = DispatchQueue(label: "com.atlas.app.crmstore")
    public let databaseURL: URL
    /// Set when the store could not be opened, so the UI can say why rather than
    /// looking like an empty CRM.
    public private(set) var openFailure: String?

    public init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL()
        queue.sync { open() }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private static func defaultDatabaseURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ATLAS", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("crm.sqlite")
    }

    // MARK: - Open

    /// Returns the raw database key, minting one on first run.
    private func databaseKey() -> String? {
        DatabaseKey.resolve(account: Self.keychainAccount,
                            databaseURL: databaseURL,
                            name: "CRM",
                            failure: &openFailure)
    }

    private func open() {
        guard let key = databaseKey() else {
            openFailure = "Could not create or read the CRM encryption key in the Keychain."
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

        // Must be the first statement on the connection.
        guard exec("PRAGMA key = \"x'\(key)'\";") else {
            openFailure = "Could not unlock the CRM database."
            close()
            return
        }
        guard exec("SELECT count(*) FROM sqlite_master;") else {
            openFailure = DatabaseKey.mismatchMessage(name: "CRM", fileName: "crm.sqlite")
            close()
            return
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

    /// Ordered, additive schema steps.
    ///
    /// Rules, so an upgrade can never cost someone their data:
    ///   * only CREATE TABLE IF NOT EXISTS, ALTER TABLE ADD COLUMN, CREATE INDEX
    ///   * never DROP, never rewrite a table, never rename a column
    ///   * anything already in the file that these do not mention is left alone
    ///
    /// The index of a step is its version. Append; never reorder or edit a
    /// shipped one.
    static let migrations: [String] = [
        // 1 — the core records.
        """
        CREATE TABLE IF NOT EXISTS companies (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            website TEXT NOT NULL DEFAULT '',
            phone TEXT NOT NULL DEFAULT '',
            address TEXT NOT NULL DEFAULT '',
            industry TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'prospect',
            notes TEXT NOT NULL DEFAULT '',
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS contacts (
            id TEXT PRIMARY KEY,
            companyId TEXT REFERENCES companies(id) ON DELETE SET NULL,
            name TEXT NOT NULL,
            email TEXT NOT NULL DEFAULT '',
            phone TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            preferredContact TEXT NOT NULL DEFAULT 'unknown',
            notes TEXT NOT NULL DEFAULT '',
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS opportunities (
            id TEXT PRIMARY KEY,
            companyId TEXT REFERENCES companies(id) ON DELETE SET NULL,
            title TEXT NOT NULL,
            estimatedValueCents INTEGER NOT NULL DEFAULT 0,
            stage TEXT NOT NULL DEFAULT 'lead',
            probability INTEGER NOT NULL DEFAULT 0,
            nextFollowUpAt REAL,
            projectPath TEXT NOT NULL DEFAULT '',
            notes TEXT NOT NULL DEFAULT '',
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS activities (
            id TEXT PRIMARY KEY,
            companyId TEXT REFERENCES companies(id) ON DELETE CASCADE,
            contactId TEXT REFERENCES contacts(id) ON DELETE SET NULL,
            opportunityId TEXT REFERENCES opportunities(id) ON DELETE CASCADE,
            kind TEXT NOT NULL DEFAULT 'note',
            summary TEXT NOT NULL,
            occurredAt REAL NOT NULL
        );
        """,

        // 2 — indexes for the three queries the UI actually runs: the board,
        // the follow-up list, and a record's activity feed.
        """
        CREATE INDEX IF NOT EXISTS opportunities_by_stage ON opportunities (stage, updatedAt DESC);
        CREATE INDEX IF NOT EXISTS opportunities_by_followup ON opportunities (nextFollowUpAt);
        CREATE INDEX IF NOT EXISTS contacts_by_company ON contacts (companyId);
        CREATE INDEX IF NOT EXISTS activities_by_time ON activities (occurredAt DESC);
        CREATE INDEX IF NOT EXISTS activities_by_company ON activities (companyId, occurredAt DESC);
        CREATE INDEX IF NOT EXISTS activities_by_opportunity ON activities (opportunityId, occurredAt DESC);
        """,

        // 3 — named filters, so a question you ask often does not have to be
        // retyped into the search box every time.
        """
        CREATE TABLE IF NOT EXISTS saved_views (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            scope TEXT NOT NULL DEFAULT 'opportunities',
            query TEXT NOT NULL DEFAULT '',
            stage TEXT,
            minValueMinorUnits INTEGER,
            staleDays INTEGER,
            sortField TEXT NOT NULL DEFAULT 'updated',
            sortAscending INTEGER NOT NULL DEFAULT 0,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS saved_views_by_name ON saved_views (name COLLATE NOCASE);
        """,

        // 4 — business ideas and side hustles. Their own table rather than a
        // Company with a special status: an idea has no counterparty, and
        // keeping it out of `companies` is what stops it being counted in the
        // pipeline figures. promotedOpportunityId links an idea that graduated
        // into a real deal, and is SET NULL rather than CASCADE so deleting the
        // deal does not take the idea's history with it.
        """
        CREATE TABLE IF NOT EXISTS ideas (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            pitch TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'spark',
            category TEXT NOT NULL DEFAULT 'sideHustle',
            effort TEXT NOT NULL DEFAULT 'unknown',
            potential TEXT NOT NULL DEFAULT 'unknown',
            nextStep TEXT NOT NULL DEFAULT '',
            notes TEXT NOT NULL DEFAULT '',
            promotedOpportunityId TEXT REFERENCES opportunities(id) ON DELETE SET NULL,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS ideas_by_status ON ideas (status, updatedAt DESC);
        """
    ]

    /// The schema version this build expects.
    public static var currentSchemaVersion: Int { migrations.count }

    /// Applies every step the file has not seen yet, in order.
    ///
    /// `user_version` is the record of how far it got. Steps already applied are
    /// skipped, so opening an up-to-date file touches nothing.
    @discardableResult
    func migrate() -> Bool {
        let from = schemaVersion()
        guard from < Self.migrations.count else { return true }

        for version in from..<Self.migrations.count {
            guard exec(Self.migrations[version]) else {
                NSLog("[ATLAS CRM] migration %d failed; stopping at %d", version + 1, version)
                setSchemaVersion(version)
                openFailure = "The CRM database could not be upgraded past version \(version)."
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
        // PRAGMA will not take a bound parameter, and this value is an Int we
        // produced, never anything from the page.
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
            NSLog("[ATLAS CRM] sql error: %@", String(cString: error))
            sqlite3_free(error)
        }
        return ok
    }

    /// SQLITE_TRANSIENT — SQLite copies the bound bytes, because the Swift
    /// String backing them is gone by the time the statement runs.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ bindings: [Any?]) -> OpaquePointer? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            NSLog("[ATLAS CRM] prepare failed: %@ — %@", sql, lastError)
            return nil
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let text as String:
                sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case let flag as Bool:
                sqlite3_bind_int64(statement, index, flag ? 1 : 0)
            case let number as Int:
                sqlite3_bind_int64(statement, index, Int64(number))
            case let number as Double:
                sqlite3_bind_double(statement, index, number)
            case let date as Date:
                sqlite3_bind_double(statement, index, date.timeIntervalSince1970)
            default:
                sqlite3_bind_null(statement, index)
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
            NSLog("[ATLAS CRM] step failed: %@ — %@", sql, lastError)
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

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    /// NULL-preserving read: an empty foreign key must stay nil, not "".
    private func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func optionalDate(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private func date(_ statement: OpaquePointer, _ column: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    /// The raw database key, for the user to copy somewhere safe. Losing the
    /// Keychain item loses the CRM with no way back.
    public func revealDatabaseKey() -> String? {
        KeychainManager.shared.get(key: Self.keychainAccount)
    }

    // MARK: - Companies

    @discardableResult
    public func upsert(_ company: Company) -> Company {
        queue.sync {
            var record = company
            record.updatedAt = Date()
            run("""
            INSERT INTO companies (id, name, website, phone, address, industry, status, notes, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name, website = excluded.website, phone = excluded.phone,
                address = excluded.address, industry = excluded.industry, status = excluded.status,
                notes = excluded.notes, updatedAt = excluded.updatedAt;
            """, [record.id, record.name, record.website, record.phone, record.address,
                  record.industry, record.status.rawValue, record.notes,
                  record.createdAt, record.updatedAt])
            return record
        }
    }

    public func companies(matching search: String = "") -> [Company] {
        queue.sync {
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let sql: String
            let bindings: [Any?]
            if trimmed.isEmpty {
                sql = "SELECT * FROM companies ORDER BY name COLLATE NOCASE ASC;"
                bindings = []
            } else {
                // LIKE with an escaped pattern: the search text is data, never
                // part of the statement.
                sql = """
                SELECT * FROM companies
                WHERE name LIKE ?1 ESCAPE '\\' OR industry LIKE ?1 ESCAPE '\\'
                   OR website LIKE ?1 ESCAPE '\\' OR notes LIKE ?1 ESCAPE '\\'
                ORDER BY name COLLATE NOCASE ASC;
                """
                bindings = [Self.likePattern(trimmed)]
            }
            return query(sql, bindings) { row in
                Company(id: text(row, 0), name: text(row, 1), website: text(row, 2),
                        phone: text(row, 3), address: text(row, 4), industry: text(row, 5),
                        status: CompanyStatus(rawValue: text(row, 6)) ?? .prospect,
                        notes: text(row, 7),
                        createdAt: date(row, 8), updatedAt: date(row, 9))
            }
        }
    }

    public func company(_ id: String) -> Company? {
        companies().first { $0.id == id }
    }

    /// What deleting this company would also remove.
    public func deletionImpact(forCompany id: String) -> DeletionImpact {
        queue.sync { impact(forCompany: id) }
    }

    private func impact(forCompany id: String) -> DeletionImpact {
        DeletionImpact(
            contacts: count("SELECT count(*) FROM contacts WHERE companyId = ?;", [id]),
            opportunities: count("SELECT count(*) FROM opportunities WHERE companyId = ?;", [id]),
            activities: count("SELECT count(*) FROM activities WHERE companyId = ?;", [id])
        )
    }

    /// Removes a company.
    ///
    /// Restricts by default: if anything hangs off it, nothing is deleted and
    /// the counts come back so the UI can say what is at stake. Call again with
    /// `cascade: true` once the person has agreed.
    @discardableResult
    public func deleteCompany(_ id: String, cascade: Bool = false) -> DeleteOutcome {
        queue.sync {
            guard count("SELECT count(*) FROM companies WHERE id = ?;", [id]) > 0 else {
                return .notFound
            }
            let dependents = impact(forCompany: id)
            if !dependents.isEmpty && !cascade {
                return .restricted(dependents)
            }
            // Explicit rather than relying on ON DELETE, so the behaviour is the
            // same whether or not foreign_keys happens to be on.
            run("DELETE FROM activities WHERE companyId = ?;", [id])
            run("DELETE FROM activities WHERE opportunityId IN (SELECT id FROM opportunities WHERE companyId = ?);", [id])
            run("DELETE FROM opportunities WHERE companyId = ?;", [id])
            // People outlive the company record; they just lose the link.
            run("UPDATE contacts SET companyId = NULL, updatedAt = ? WHERE companyId = ?;", [Date(), id])
            run("DELETE FROM companies WHERE id = ?;", [id])
            return .deleted
        }
    }

    // MARK: - Contacts

    @discardableResult
    public func upsert(_ contact: Contact) -> Contact {
        queue.sync {
            var record = contact
            record.updatedAt = Date()
            run("""
            INSERT INTO contacts (id, companyId, name, email, phone, title, preferredContact, notes, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                companyId = excluded.companyId, name = excluded.name, email = excluded.email,
                phone = excluded.phone, title = excluded.title,
                preferredContact = excluded.preferredContact, notes = excluded.notes,
                updatedAt = excluded.updatedAt;
            """, [record.id, record.companyId, record.name, record.email, record.phone,
                  record.title, record.preferredContact.rawValue, record.notes,
                  record.createdAt, record.updatedAt])
            return record
        }
    }

    public func contacts(matching search: String = "", companyId: String? = nil) -> [Contact] {
        queue.sync {
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            var sql = "SELECT * FROM contacts"
            var clauses: [String] = []
            var bindings: [Any?] = []
            if !trimmed.isEmpty {
                clauses.append("(name LIKE ? ESCAPE '\\' OR email LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\' OR notes LIKE ? ESCAPE '\\')")
                let pattern = Self.likePattern(trimmed)
                bindings.append(contentsOf: [pattern, pattern, pattern, pattern])
            }
            if let companyId {
                clauses.append("companyId = ?")
                bindings.append(companyId)
            }
            if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
            sql += " ORDER BY name COLLATE NOCASE ASC;"

            return query(sql, bindings) { row in
                Contact(id: text(row, 0), companyId: optionalText(row, 1), name: text(row, 2),
                        email: text(row, 3), phone: text(row, 4), title: text(row, 5),
                        preferredContact: ContactMethod(rawValue: text(row, 6)) ?? .unknown,
                        notes: text(row, 7),
                        createdAt: date(row, 8), updatedAt: date(row, 9))
            }
        }
    }

    @discardableResult
    public func deleteContact(_ id: String) -> DeleteOutcome {
        queue.sync {
            guard count("SELECT count(*) FROM contacts WHERE id = ?;", [id]) > 0 else { return .notFound }
            // The history stays; it just stops pointing at a person who is gone.
            run("UPDATE activities SET contactId = NULL WHERE contactId = ?;", [id])
            run("DELETE FROM contacts WHERE id = ?;", [id])
            return .deleted
        }
    }

    // MARK: - Opportunities

    @discardableResult
    public func upsert(_ opportunity: Opportunity) -> Opportunity {
        queue.sync {
            var record = opportunity
            record.updatedAt = Date()
            record.probability = min(max(record.probability, 0), 100)
            run("""
            INSERT INTO opportunities (id, companyId, title, estimatedValueCents, stage, probability,
                                       nextFollowUpAt, projectPath, notes, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                companyId = excluded.companyId, title = excluded.title,
                estimatedValueCents = excluded.estimatedValueCents, stage = excluded.stage,
                probability = excluded.probability, nextFollowUpAt = excluded.nextFollowUpAt,
                projectPath = excluded.projectPath, notes = excluded.notes,
                updatedAt = excluded.updatedAt;
            """, [record.id, record.companyId, record.title, record.estimatedValueCents,
                  record.stage.rawValue, record.probability, record.nextFollowUpAt,
                  record.projectPath, record.notes, record.createdAt, record.updatedAt])
            return record
        }
    }

    public func opportunities(matching search: String = "", companyId: String? = nil) -> [Opportunity] {
        queue.sync {
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            var sql = "SELECT * FROM opportunities"
            var clauses: [String] = []
            var bindings: [Any?] = []
            if !trimmed.isEmpty {
                clauses.append("(title LIKE ? ESCAPE '\\' OR notes LIKE ? ESCAPE '\\' OR projectPath LIKE ? ESCAPE '\\')")
                let pattern = Self.likePattern(trimmed)
                bindings.append(contentsOf: [pattern, pattern, pattern])
            }
            if let companyId {
                clauses.append("companyId = ?")
                bindings.append(companyId)
            }
            if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
            sql += " ORDER BY updatedAt DESC;"

            return query(sql, bindings) { row in
                Opportunity(id: text(row, 0), companyId: optionalText(row, 1), title: text(row, 2),
                            estimatedValueCents: Int(sqlite3_column_int64(row, 3)),
                            stage: OpportunityStage(rawValue: text(row, 4)) ?? .lead,
                            probability: Int(sqlite3_column_int64(row, 5)),
                            nextFollowUpAt: optionalDate(row, 6),
                            projectPath: text(row, 7), notes: text(row, 8),
                            createdAt: date(row, 9), updatedAt: date(row, 10))
            }
        }
    }

    /// Moves a card on the board. Returns the saved record, or nil if the id is
    /// unknown — a drag onto a deleted deal should fail visibly.
    @discardableResult
    public func setStage(_ id: String, to stage: OpportunityStage) -> Opportunity? {
        guard var record = opportunities().first(where: { $0.id == id }) else { return nil }
        let previous = record.stage
        guard previous != stage else { return record }
        record.stage = stage
        let saved = upsert(record)
        log(Activity(companyId: record.companyId, opportunityId: record.id, kind: .statusChange,
                     summary: "Stage moved from \(previous.title) to \(stage.title)"))
        return saved
    }

    @discardableResult
    public func deleteOpportunity(_ id: String) -> DeleteOutcome {
        queue.sync {
            guard count("SELECT count(*) FROM opportunities WHERE id = ?;", [id]) > 0 else { return .notFound }
            run("DELETE FROM activities WHERE opportunityId = ?;", [id])
            run("DELETE FROM opportunities WHERE id = ?;", [id])
            return .deleted
        }
    }

    /// Open deals whose follow-up date has arrived, soonest first.
    public func needingFollowUp(asOf now: Date = Date()) -> [Opportunity] {
        opportunities()
            .filter { $0.needsFollowUp(asOf: now) }
            .sorted { ($0.nextFollowUpAt ?? .distantFuture) < ($1.nextFollowUpAt ?? .distantFuture) }
    }

    // MARK: - Activities

    @discardableResult
    public func log(_ activity: Activity) -> Activity {
        queue.sync {
            run("""
            INSERT INTO activities (id, companyId, contactId, opportunityId, kind, summary, occurredAt)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                companyId = excluded.companyId, contactId = excluded.contactId,
                opportunityId = excluded.opportunityId, kind = excluded.kind,
                summary = excluded.summary, occurredAt = excluded.occurredAt;
            """, [activity.id, activity.companyId, activity.contactId, activity.opportunityId,
                  activity.kind.rawValue, activity.summary, activity.occurredAt])
            return activity
        }
    }

    public func activities(companyId: String? = nil, contactId: String? = nil,
                           opportunityId: String? = nil, limit: Int = 100) -> [Activity] {
        queue.sync {
            var sql = "SELECT * FROM activities"
            var clauses: [String] = []
            var bindings: [Any?] = []
            if let companyId { clauses.append("companyId = ?"); bindings.append(companyId) }
            if let contactId { clauses.append("contactId = ?"); bindings.append(contactId) }
            if let opportunityId { clauses.append("opportunityId = ?"); bindings.append(opportunityId) }
            if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " OR ") }
            sql += " ORDER BY occurredAt DESC LIMIT ?;"
            bindings.append(limit)

            return query(sql, bindings) { row in
                Activity(id: text(row, 0), companyId: optionalText(row, 1),
                         contactId: optionalText(row, 2), opportunityId: optionalText(row, 3),
                         kind: ActivityKind(rawValue: text(row, 4)) ?? .note,
                         summary: text(row, 5), occurredAt: date(row, 6))
            }
        }
    }

    @discardableResult
    public func deleteActivity(_ id: String) -> DeleteOutcome {
        queue.sync {
            guard count("SELECT count(*) FROM activities WHERE id = ?;", [id]) > 0 else { return .notFound }
            run("DELETE FROM activities WHERE id = ?;", [id])
            return .deleted
        }
    }

    // MARK: - Ideas

    @discardableResult
    public func upsert(_ idea: Idea) -> Idea {
        queue.sync {
            var record = idea
            record.updatedAt = Date()
            run("""
            INSERT INTO ideas (id, title, pitch, status, category, effort, potential,
                               nextStep, notes, promotedOpportunityId, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title, pitch = excluded.pitch, status = excluded.status,
                category = excluded.category, effort = excluded.effort,
                potential = excluded.potential, nextStep = excluded.nextStep,
                notes = excluded.notes,
                promotedOpportunityId = excluded.promotedOpportunityId,
                updatedAt = excluded.updatedAt;
            """, [record.id, record.title, record.pitch, record.status.rawValue,
                  record.category.rawValue, record.effort.rawValue, record.potential.rawValue,
                  record.nextStep, record.notes, record.promotedOpportunityId,
                  record.createdAt, record.updatedAt])
            return record
        }
    }

    /// Ideas, newest activity first.
    ///
    /// Parked ones sort last rather than being hidden: setting something down
    /// on purpose is different from abandoning it, and it should still be
    /// findable without a filter.
    public func ideas(matching search: String = "") -> [Idea] {
        queue.sync {
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let ordering = " ORDER BY (status = 'parked') ASC, updatedAt DESC;"
            let sql: String
            let bindings: [Any?]
            if trimmed.isEmpty {
                sql = "SELECT * FROM ideas" + ordering
                bindings = []
            } else {
                // The search text is data, never part of the statement.
                sql = """
                SELECT * FROM ideas
                WHERE title LIKE ?1 ESCAPE '\\' OR pitch LIKE ?1 ESCAPE '\\'
                   OR notes LIKE ?1 ESCAPE '\\' OR nextStep LIKE ?1 ESCAPE '\\'
                """ + ordering
                bindings = [Self.likePattern(trimmed)]
            }
            return query(sql, bindings) { row in
                Idea(id: text(row, 0), title: text(row, 1), pitch: text(row, 2),
                     status: IdeaStatus(rawValue: text(row, 3)) ?? .spark,
                     category: IdeaCategory(rawValue: text(row, 4)) ?? .sideHustle,
                     effort: IdeaSizing(rawValue: text(row, 5)) ?? .unknown,
                     potential: IdeaSizing(rawValue: text(row, 6)) ?? .unknown,
                     nextStep: text(row, 7), notes: text(row, 8),
                     promotedOpportunityId: optionalText(row, 9),
                     createdAt: date(row, 10), updatedAt: date(row, 11))
            }
        }
    }

    public func idea(_ id: String) -> Idea? {
        ideas().first { $0.id == id }
    }

    @discardableResult
    public func deleteIdea(_ id: String) -> DeleteOutcome {
        queue.sync {
            guard count("SELECT count(*) FROM ideas WHERE id = ?;", [id]) > 0 else {
                return .notFound
            }
            run("DELETE FROM ideas WHERE id = ?;", [id])
            return .deleted
        }
    }

    /// What promoting an idea produced.
    public struct Promotion: Equatable, Sendable {
        public let idea: Idea
        public let company: Company
        public let opportunity: Opportunity
    }

    /// Graduates an idea into the pipeline.
    ///
    /// Creates the Company and Opportunity the idea becomes, records the
    /// origin as an activity, and links the idea to the new deal. The idea is
    /// kept rather than consumed — where something came from is worth more than
    /// the row it occupied — and its status moves to `running`.
    ///
    /// Returns nil if the idea is unknown or has already been promoted, so a
    /// double click cannot create two deals.
    public func promote(ideaId: String,
                        companyName: String? = nil,
                        estimatedValueCents: Int = 0) -> Promotion? {
        guard var idea = idea(ideaId), !idea.isPromoted else { return nil }

        let company = upsert(Company(
            name: (companyName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? idea.title,
            industry: idea.category.rawValue,
            status: .prospect,
            notes: idea.pitch
        ))

        let opportunity = upsert(Opportunity(
            companyId: company.id,
            title: idea.title,
            estimatedValueCents: estimatedValueCents,
            stage: .lead,
            notes: idea.notes
        ))

        _ = log(Activity(companyId: company.id,
                         opportunityId: opportunity.id,
                         kind: .note,
                         summary: "Promoted from idea: \(idea.title)"))

        idea.promotedOpportunityId = opportunity.id
        idea.status = .running
        let saved = upsert(idea)

        return Promotion(idea: saved, company: company, opportunity: opportunity)
    }

    // MARK: - Saved views

    @discardableResult
    public func upsert(_ view: SavedView) -> SavedView {
        queue.sync {
            var record = view
            record.updatedAt = Date()
            run("""
            INSERT INTO saved_views (id, name, scope, query, stage, minValueMinorUnits,
                                     staleDays, sortField, sortAscending, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name, scope = excluded.scope, query = excluded.query,
                stage = excluded.stage, minValueMinorUnits = excluded.minValueMinorUnits,
                staleDays = excluded.staleDays, sortField = excluded.sortField,
                sortAscending = excluded.sortAscending, updatedAt = excluded.updatedAt;
            """, [record.id, record.name, record.scope.rawValue, record.query,
                  record.stage?.rawValue, record.minValueMinorUnits, record.staleDays,
                  record.sortField.rawValue, record.sortAscending,
                  record.createdAt, record.updatedAt])
            return record
        }
    }

    public func savedViews() -> [SavedView] {
        queue.sync {
            query("SELECT * FROM saved_views ORDER BY name COLLATE NOCASE ASC;", []) { row in
                SavedView(
                    id: text(row, 0),
                    name: text(row, 1),
                    scope: ViewScope(rawValue: text(row, 2)) ?? .opportunities,
                    query: text(row, 3),
                    stage: optionalText(row, 4).flatMap { OpportunityStage(rawValue: $0) },
                    minValueMinorUnits: sqlite3_column_type(row, 5) == SQLITE_NULL
                        ? nil : Int(sqlite3_column_int64(row, 5)),
                    staleDays: sqlite3_column_type(row, 6) == SQLITE_NULL
                        ? nil : Int(sqlite3_column_int64(row, 6)),
                    sortField: SortField(rawValue: text(row, 7)) ?? .updated,
                    sortAscending: sqlite3_column_int64(row, 8) != 0,
                    createdAt: date(row, 9),
                    updatedAt: date(row, 10)
                )
            }
        }
    }

    @discardableResult
    public func deleteSavedView(_ id: String) -> DeleteOutcome {
        queue.sync {
            guard count("SELECT count(*) FROM saved_views WHERE id = ?;", [id]) > 0 else {
                return .notFound
            }
            run("DELETE FROM saved_views WHERE id = ?;", [id])
            return .deleted
        }
    }

    /// The deals a view describes, filtered and sorted.
    public func opportunities(in view: SavedView, asOf now: Date = Date(),
                              calendar: Calendar = .current) -> [Opportunity] {
        ViewFilter.apply(view, to: opportunities(matching: view.query),
                         asOf: now, calendar: calendar)
    }

    // MARK: - Overview

    public func summary(asOf now: Date = Date()) -> PipelineSummary {
        let deals = opportunities()
        let open = deals.filter { $0.stage.isOpen }
        let won = deals.filter { $0.stage == .won }
        return PipelineSummary(
            openCount: open.count,
            openValueCents: open.reduce(0) { $0 + $1.estimatedValueCents },
            weightedValueCents: open.reduce(0) { $0 + $1.weightedValueCents },
            wonCount: won.count,
            wonValueCents: won.reduce(0) { $0 + $1.estimatedValueCents },
            needingFollowUp: deals.filter { $0.needsFollowUp(asOf: now) }.count,
            companyCount: companies().count,
            contactCount: contacts().count
        )
    }

    // MARK: - Search helpers

    /// Escapes the LIKE wildcards so a search for "100%" means what it says.
    static func likePattern(_ term: String) -> String {
        let escaped = term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }
}
