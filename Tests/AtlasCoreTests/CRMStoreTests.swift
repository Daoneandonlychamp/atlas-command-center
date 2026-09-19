import XCTest
import SQLCipher
@testable import AtlasCore

/// Checks the CRM store: round trips, search, pipeline maths, the delete rules,
/// and — the two that would cost real data if they were wrong — that the file on
/// disk is encrypted, and that a migration never eats anything it did not write.
///
/// Every test runs against a database in a temporary directory. The real
/// `crm.sqlite` in Application Support is never opened here.
final class CRMStoreTests: XCTestCase {
    private var directory: URL!
    private var store: CRMStore!
    /// A fixed calendar so day arithmetic does not depend on where this runs.
    private var calendar: Calendar!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AtlasCRMTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = CRMStore(databaseURL: directory.appendingPathComponent("crm.sqlite"))
        XCTAssertNil(store.openFailure, "store should open: \(store.openFailure ?? "")")

        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Models

    func testModelsRoundTripThroughJSON() throws {
        let company = Company(name: "Northwind", website: "northwind.example",
                              industry: "Logistics", status: .active, notes: "Met at the docks")
        let contact = Contact(companyId: company.id, name: "R. Vega", email: "r@northwind.example",
                              title: "Ops lead", preferredContact: .phone)
        let deal = Opportunity(companyId: company.id, title: "Fleet retrofit",
                               estimatedValueCents: 1_250_000, stage: .proposal, probability: 60,
                               nextFollowUpAt: Date(timeIntervalSince1970: 1_800_000_000),
                               projectPath: "~/Developer/retrofit")
        let activity = Activity(companyId: company.id, kind: .meeting, summary: "Walked the yard")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(Company.self, from: encoder.encode(company)), company)
        XCTAssertEqual(try decoder.decode(Contact.self, from: encoder.encode(contact)), contact)
        XCTAssertEqual(try decoder.decode(Opportunity.self, from: encoder.encode(deal)), deal)
        XCTAssertEqual(try decoder.decode(Activity.self, from: encoder.encode(activity)), activity)
    }

    func testProbabilityIsClampedOnTheWayIn() {
        XCTAssertEqual(Opportunity(title: "High", probability: 480).probability, 100)
        XCTAssertEqual(Opportunity(title: "Low", probability: -20).probability, 0)

        let saved = store.upsert(Opportunity(title: "Clamped", probability: 250))
        XCTAssertEqual(saved.probability, 100)
        XCTAssertEqual(store.opportunities().first?.probability, 100)
    }

    func testWeightedValueAndFollowUpFlag() {
        let deal = Opportunity(title: "Half likely", estimatedValueCents: 1_000_000,
                               stage: .qualified, probability: 40)
        XCTAssertEqual(deal.weightedValueCents, 400_000)

        let now = Date()
        let overdue = Opportunity(title: "Overdue", stage: .lead,
                                  nextFollowUpAt: now.addingTimeInterval(-3600))
        let later = Opportunity(title: "Later", stage: .lead,
                                nextFollowUpAt: now.addingTimeInterval(3600))
        let closed = Opportunity(title: "Closed", stage: .won,
                                 nextFollowUpAt: now.addingTimeInterval(-3600))
        XCTAssertTrue(overdue.needsFollowUp(asOf: now))
        XCTAssertFalse(later.needsFollowUp(asOf: now))
        XCTAssertFalse(closed.needsFollowUp(asOf: now), "a won deal stops asking for follow-up")
    }

    // MARK: - CRUD

    func testCompanyCRUD() {
        let created = store.upsert(Company(name: "Aurora Metals", industry: "Fabrication"))
        XCTAssertEqual(store.companies().count, 1)

        var edited = created
        edited.name = "Aurora Metals Ltd"
        edited.status = .active
        store.upsert(edited)

        let loaded = store.companies()
        XCTAssertEqual(loaded.count, 1, "an update must not insert a second row")
        XCTAssertEqual(loaded.first?.name, "Aurora Metals Ltd")
        XCTAssertEqual(loaded.first?.status, .active)
        XCTAssertEqual(loaded.first?.id, created.id)

        XCTAssertEqual(store.deleteCompany(created.id), .deleted)
        XCTAssertTrue(store.companies().isEmpty)
        XCTAssertEqual(store.deleteCompany(created.id), .notFound)
    }

    func testContactAndOpportunityCRUD() {
        let company = store.upsert(Company(name: "Harbour Co"))
        let contact = store.upsert(Contact(companyId: company.id, name: "J. Ito", email: "j@harbour.example"))
        let deal = store.upsert(Opportunity(companyId: company.id, title: "Dock refit",
                                            estimatedValueCents: 500_000, stage: .lead))

        XCTAssertEqual(store.contacts().count, 1)
        XCTAssertEqual(store.contacts(companyId: company.id).first?.id, contact.id)
        XCTAssertEqual(store.opportunities(companyId: company.id).first?.id, deal.id)

        XCTAssertEqual(store.deleteContact(contact.id), .deleted)
        XCTAssertEqual(store.deleteOpportunity(deal.id), .deleted)
        XCTAssertTrue(store.contacts().isEmpty)
        XCTAssertTrue(store.opportunities().isEmpty)
    }

    func testNilCompanyRelationshipSurvivesTheRoundTrip() {
        store.upsert(Contact(companyId: nil, name: "Unattached"))
        XCTAssertNil(store.contacts().first?.companyId,
                     "a missing relationship must come back nil, not an empty string")
    }

    // MARK: - Relationships

    func testDeletingACompanyIsRestrictedUntilConfirmed() {
        let company = store.upsert(Company(name: "Cascade Test"))
        store.upsert(Contact(companyId: company.id, name: "Someone"))
        store.upsert(Opportunity(companyId: company.id, title: "Something"))
        store.log(Activity(companyId: company.id, summary: "Talked"))

        let outcome = store.deleteCompany(company.id)
        XCTAssertEqual(outcome, .restricted(DeletionImpact(contacts: 1, opportunities: 1, activities: 1)))
        XCTAssertEqual(store.companies().count, 1, "a restricted delete must change nothing")
        XCTAssertEqual(store.contacts().count, 1)
    }

    func testCascadingDeleteRemovesDealsAndKeepsPeople() {
        let company = store.upsert(Company(name: "Cascade Test"))
        let contact = store.upsert(Contact(companyId: company.id, name: "Survivor"))
        let deal = store.upsert(Opportunity(companyId: company.id, title: "Doomed"))
        store.log(Activity(companyId: company.id, opportunityId: deal.id, summary: "Kickoff"))

        XCTAssertEqual(store.deleteCompany(company.id, cascade: true), .deleted)
        XCTAssertTrue(store.companies().isEmpty)
        XCTAssertTrue(store.opportunities().isEmpty, "the company's deals go with it")
        XCTAssertTrue(store.activities().isEmpty, "so does its history")

        // The person is not the company's property; they lose the link and stay.
        let people = store.contacts()
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people.first?.id, contact.id)
        XCTAssertNil(people.first?.companyId)
    }

    func testDeletingAContactKeepsTheirHistory() {
        let contact = store.upsert(Contact(name: "Departing"))
        store.log(Activity(contactId: contact.id, kind: .call, summary: "Last call"))

        XCTAssertEqual(store.deleteContact(contact.id), .deleted)
        let remaining = store.activities()
        XCTAssertEqual(remaining.count, 1, "history outlives the person record")
        XCTAssertNil(remaining.first?.contactId)
    }

    func testDeletingAnOpportunityRemovesItsActivities() {
        let deal = store.upsert(Opportunity(title: "Short lived"))
        store.log(Activity(opportunityId: deal.id, summary: "Opened"))
        XCTAssertEqual(store.deleteOpportunity(deal.id), .deleted)
        XCTAssertTrue(store.activities().isEmpty)
    }

    // MARK: - Pipeline

    func testStageChangeLogsAnActivity() {
        let deal = store.upsert(Opportunity(title: "Moving", stage: .lead))
        let moved = store.setStage(deal.id, to: .qualified)
        XCTAssertEqual(moved?.stage, .qualified)

        let history = store.activities(opportunityId: deal.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.kind, .statusChange)
        XCTAssertTrue(history.first?.summary.contains("Lead") == true)
        XCTAssertTrue(history.first?.summary.contains("Qualified") == true)
    }

    func testStageChangeToTheSameStageIsNotLogged() {
        let deal = store.upsert(Opportunity(title: "Still", stage: .lead))
        XCTAssertEqual(store.setStage(deal.id, to: .lead)?.stage, .lead)
        XCTAssertTrue(store.activities(opportunityId: deal.id).isEmpty)
    }

    func testStageChangeOnAMissingDealFails() {
        XCTAssertNil(store.setStage("no-such-id", to: .won))
    }

    func testSummaryCountsOnlyOpenValue() {
        let now = Date()
        store.upsert(Company(name: "One"))
        store.upsert(Opportunity(title: "Open A", estimatedValueCents: 100_000, stage: .lead, probability: 50))
        store.upsert(Opportunity(title: "Open B", estimatedValueCents: 300_000, stage: .proposal, probability: 100))
        store.upsert(Opportunity(title: "Closed", estimatedValueCents: 900_000, stage: .won, probability: 100))
        store.upsert(Opportunity(title: "Gone", estimatedValueCents: 900_000, stage: .lost))
        store.upsert(Opportunity(title: "Chase me", estimatedValueCents: 1000, stage: .lead,
                                 probability: 10, nextFollowUpAt: now.addingTimeInterval(-60)))

        let summary = store.summary(asOf: now)
        XCTAssertEqual(summary.openCount, 3)
        XCTAssertEqual(summary.openValueCents, 401_000)
        XCTAssertEqual(summary.weightedValueCents, 50_000 + 300_000 + 100)
        XCTAssertEqual(summary.wonCount, 1)
        XCTAssertEqual(summary.wonValueCents, 900_000)
        XCTAssertEqual(summary.needingFollowUp, 1)
        XCTAssertEqual(summary.companyCount, 1)
    }

    func testNeedingFollowUpIsSoonestFirst() {
        let now = Date()
        store.upsert(Opportunity(title: "Later", stage: .lead, nextFollowUpAt: now.addingTimeInterval(-60)))
        store.upsert(Opportunity(title: "Sooner", stage: .lead, nextFollowUpAt: now.addingTimeInterval(-6000)))
        XCTAssertEqual(store.needingFollowUp(asOf: now).map(\.title), ["Sooner", "Later"])
    }

    // MARK: - Search

    func testSearchMatchesAcrossFieldsAndIsCaseInsensitive() {
        store.upsert(Company(name: "Blue Harbour", industry: "Shipping"))
        store.upsert(Company(name: "Red Rock", industry: "Mining"))

        XCTAssertEqual(store.companies(matching: "harbour").map(\.name), ["Blue Harbour"])
        XCTAssertEqual(store.companies(matching: "HARBOUR").map(\.name), ["Blue Harbour"])
        XCTAssertEqual(store.companies(matching: "mining").map(\.name), ["Red Rock"])
        XCTAssertEqual(store.companies(matching: "  ").count, 2, "a blank search is not a filter")
        XCTAssertTrue(store.companies(matching: "nothing here").isEmpty)
    }

    func testSearchTreatsWildcardsAsLiteralText() {
        store.upsert(Company(name: "Ten Percent", notes: "asked for 10% off"))
        store.upsert(Company(name: "Nothing Special"))

        // Without escaping, "%" matches everything and this returns both.
        XCTAssertEqual(store.companies(matching: "10%").map(\.name), ["Ten Percent"])
        XCTAssertTrue(store.companies(matching: "_____").isEmpty,
                      "underscore is a LIKE wildcard and must be escaped too")
    }

    func testContactAndOpportunitySearch() {
        let company = store.upsert(Company(name: "Searchable"))
        store.upsert(Contact(companyId: company.id, name: "Dana Vue", email: "dana@x.example", title: "CTO"))
        store.upsert(Contact(name: "Other Person"))
        store.upsert(Opportunity(companyId: company.id, title: "Rebuild the pier"))
        store.upsert(Opportunity(title: "Unrelated"))

        XCTAssertEqual(store.contacts(matching: "cto").map(\.name), ["Dana Vue"])
        XCTAssertEqual(store.contacts(matching: "dana@x").map(\.name), ["Dana Vue"])
        XCTAssertEqual(store.opportunities(matching: "pier").map(\.title), ["Rebuild the pier"])
        XCTAssertEqual(store.contacts(matching: "", companyId: company.id).count, 1)
    }

    // MARK: - Saved views

    private func deal(_ title: String, _ cents: Int, _ stage: OpportunityStage,
                      updated: Date = Date()) -> Opportunity {
        Opportunity(title: title, estimatedValueCents: cents, stage: stage, updatedAt: updated)
    }

    func testSavedViewCRUD() {
        let created = store.upsert(SavedView(name: "Big proposals", scope: .opportunities,
                                             stage: .proposal, minValueMinorUnits: 1_000_00))
        XCTAssertEqual(store.savedViews().count, 1)

        var edited = created
        edited.name = "Bigger proposals"
        store.upsert(edited)
        XCTAssertEqual(store.savedViews().count, 1, "an update must not insert a second row")
        XCTAssertEqual(store.savedViews().first?.name, "Bigger proposals")
        XCTAssertEqual(store.savedViews().first?.stage, .proposal)
        XCTAssertEqual(store.savedViews().first?.minValueMinorUnits, 1_000_00)

        XCTAssertEqual(store.deleteSavedView(created.id), .deleted)
        XCTAssertEqual(store.deleteSavedView(created.id), .notFound)
    }

    func testAnEmptyFilterStaysNilRatherThanBecomingZero() {
        store.upsert(SavedView(name: "Everything"))
        let loaded = store.savedViews().first
        XCTAssertNil(loaded?.stage, "no stage filter is not the first stage")
        XCTAssertNil(loaded?.minValueMinorUnits, "no floor is not a floor of zero")
        XCTAssertNil(loaded?.staleDays)
        XCTAssertFalse(loaded?.isFiltered ?? true)
    }

    func testAViewFiltersByStageAndValue() {
        let deals = [deal("Small lead", 50_00, .lead),
                     deal("Big proposal", 20_000_00, .proposal),
                     deal("Small proposal", 100_00, .proposal)]
        let view = SavedView(name: "Proposals over $100",
                             stage: .proposal, minValueMinorUnits: 150_00)
        XCTAssertEqual(ViewFilter.apply(view, to: deals).map(\.title), ["Big proposal"])
    }

    func testAViewCanFindWorkNobodyHasTouched() {
        let now = day(2026, 9, 7)
        let deals = [deal("Fresh", 100, .lead, updated: day(2026, 9, 5)),
                     deal("Stale", 100, .lead, updated: day(2026, 7, 1))]
        let view = SavedView(name: "Untouched for 30 days", staleDays: 30)
        XCTAssertEqual(ViewFilter.apply(view, to: deals, asOf: now, calendar: calendar)
                        .map(\.title), ["Stale"])
    }

    func testSortingRunsEveryColumnBothWays() {
        let deals = [deal("B", 300, .won), deal("A", 100, .lead), deal("C", 200, .proposal)]

        XCTAssertEqual(ViewFilter.sort(deals, by: .name, ascending: true).map(\.title),
                       ["A", "B", "C"])
        XCTAssertEqual(ViewFilter.sort(deals, by: .name, ascending: false).map(\.title),
                       ["C", "B", "A"])
        XCTAssertEqual(ViewFilter.sort(deals, by: .value, ascending: true).map(\.title),
                       ["A", "C", "B"])
        XCTAssertEqual(ViewFilter.sort(deals, by: .stage, ascending: true).map(\.title),
                       ["A", "C", "B"], "board order, not alphabetical")
    }

    /// A deal with no follow-up date is not "due soonest" — it has no date at
    /// all, and sorting it to the top would bury the ones that do.
    func testDealsWithNoFollowUpDateSortLast() {
        let withDate = Opportunity(title: "Has date", nextFollowUpAt: day(2026, 9, 10))
        let without = Opportunity(title: "No date")
        XCTAssertEqual(ViewFilter.sort([without, withDate], by: .followUp, ascending: true)
                        .map(\.title), ["Has date", "No date"])
    }

    func testTheStoreAppliesAViewEndToEnd() {
        store.upsert(Opportunity(title: "Pier rebuild", estimatedValueCents: 50_000_00,
                                 stage: .proposal))
        store.upsert(Opportunity(title: "Pier signage", estimatedValueCents: 100_00,
                                 stage: .proposal))
        store.upsert(Opportunity(title: "Unrelated", estimatedValueCents: 90_000_00, stage: .lead))

        let view = SavedView(name: "Big pier work", query: "pier",
                             stage: .proposal, minValueMinorUnits: 1_000_00)
        XCTAssertEqual(store.opportunities(in: view).map(\.title), ["Pier rebuild"],
                       "search, stage and value all narrow together")
    }

    // MARK: - Migration

    func testSchemaIsAtTheCurrentVersion() {
        XCTAssertEqual(store.schemaVersion(), CRMStore.currentSchemaVersion)
        XCTAssertGreaterThan(CRMStore.currentSchemaVersion, 0)
    }

    func testReopeningAnUpToDateDatabaseKeepsItsData() {
        let company = store.upsert(Company(name: "Persistent"))
        store.upsert(Opportunity(companyId: company.id, title: "Still here", estimatedValueCents: 4200))
        let url = store.databaseURL
        store = nil

        let reopened = CRMStore(databaseURL: url)
        XCTAssertNil(reopened.openFailure)
        XCTAssertEqual(reopened.schemaVersion(), CRMStore.currentSchemaVersion)
        XCTAssertEqual(reopened.companies().map(\.name), ["Persistent"])
        XCTAssertEqual(reopened.opportunities().first?.estimatedValueCents, 4200)
    }

    /// The migration runner must be additive. This puts a table the CRM has
    /// never heard of into the file, winds the version back so every step runs
    /// again, and checks that both the unknown table and the real records are
    /// still there afterwards.
    func testMigrationPreservesUnknownDataAndReplaysCleanly() throws {
        let company = store.upsert(Company(name: "Keep Me"))
        store.log(Activity(companyId: company.id, summary: "Keep this too"))
        let url = store.databaseURL
        let key = try XCTUnwrap(store.revealDatabaseKey())
        store = nil

        // Reach into the file directly as some other tool might have.
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

        // Opening runs every migration from scratch against a populated file.
        let migrated = CRMStore(databaseURL: url)
        XCTAssertNil(migrated.openFailure)
        XCTAssertEqual(migrated.schemaVersion(), CRMStore.currentSchemaVersion)
        XCTAssertEqual(migrated.companies().map(\.name), ["Keep Me"])
        XCTAssertEqual(migrated.activities().count, 1)

        // And the table nothing in the CRM knows about is untouched.
        var check: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &check,
                                       SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        let reader = try XCTUnwrap(check)
        XCTAssertEqual(sqlite3_exec(reader, "PRAGMA key = \"x'\(key)'\";", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(reader, "SELECT payload FROM future_feature WHERE id = 'a';",
                                          -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "do not lose me")
        sqlite3_finalize(statement)
        sqlite3_close(reader)
    }

    // MARK: - Encryption

    func testDatabaseFileIsNotReadableAsPlainSQLite() throws {
        store.upsert(Company(name: "Confidential Holdings", notes: "sensitive-marker-string"))
        let url = store.databaseURL
        store = nil

        let bytes = try Data(contentsOf: url)
        XCTAssertFalse(bytes.starts(with: Array("SQLite format 3".utf8)),
                       "an encrypted database must not begin with the SQLite header")
        XCTAssertNil(bytes.range(of: Data("sensitive-marker-string".utf8)),
                     "record text must not be readable in the file on disk")
        XCTAssertNil(bytes.range(of: Data("Confidential Holdings".utf8)))
    }

    func testEmptyStoreReportsEmptyRatherThanFailing() {
        XCTAssertTrue(store.companies().isEmpty)
        XCTAssertTrue(store.contacts().isEmpty)
        XCTAssertTrue(store.opportunities().isEmpty)
        XCTAssertTrue(store.activities().isEmpty)
        XCTAssertTrue(store.needingFollowUp().isEmpty)

        let summary = store.summary()
        XCTAssertEqual(summary.openCount, 0)
        XCTAssertEqual(summary.openValueCents, 0)
        XCTAssertEqual(summary.companyCount, 0)
    }
}
