import XCTest

@testable import AtlasCore

/// Checks the boundary between `crm.html` and the store.
///
/// Two things are being proved. First, that only the allowlisted vocabulary
/// decodes at all — a message asking for anything else never becomes an action.
/// Second, that everything which *does* decode is validated again here, because
/// a web view can be handed any message and the page's own checks are a
/// convenience for the person typing, not a defence.
final class CRMBridgeTests: XCTestCase {

    private func decode(_ json: String) -> CRMAction? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CRMAction.self, from: data)
    }

    // MARK: - The allowlist

    func testOnlyAllowlistedActionsDecode() {
        for kind in CRMActionKind.allCases {
            XCTAssertNotNil(decode(#"{"action":"\#(kind.rawValue)"}"#),
                            "\(kind.rawValue) is in the allowlist and must decode")
        }
    }

    func testMessagesOutsideTheAllowlistAreRejected() {
        let hostile = [
            #"{"action":"eval","code":"fetch('https://example.com')"}"#,
            #"{"action":"exec"}"#,
            #"{"action":"query","sql":"DROP TABLE companies"}"#,
            #"{"action":"readFile","path":"~/.ssh/id_rsa"}"#,
            #"{"action":"saveCompany ; DROP TABLE companies"}"#,
            #"{"action":"SAVECOMPANY"}"#,          // the enum is case sensitive
            #"{"action":""}"#,
            #"{"action":null}"#,
            #"{"notAnAction":"load"}"#,
            #"{}"#,
            #"[]"#,
            #""load""#,
            "not json at all"
        ]
        for message in hostile {
            XCTAssertNil(decode(message), "should not decode: \(message)")
        }
    }

    func testUnknownExtraFieldsAreIgnoredRatherThanHonoured() {
        // A message may carry junk; it just never becomes anything.
        let action = decode(#"{"action":"load","sql":"DROP TABLE companies","__proto__":{"x":1}}"#)
        XCTAssertEqual(action?.action, .load)
    }

    // MARK: - Company validation

    func testCompanyRequiresANonBlankName() {
        for json in [#"{"action":"saveCompany"}"#,
                     #"{"action":"saveCompany","name":""}"#,
                     #"{"action":"saveCompany","name":"   \n  "}"#] {
            let action = try! XCTUnwrap(decode(json))
            XCTAssertEqual(CRMActionValidator.company(from: action),
                           .failure(.missing("Company name")))
        }
    }

    func testCompanyRejectsAnUnknownStatus() {
        let action = try! XCTUnwrap(decode(#"{"action":"saveCompany","name":"X","status":"superuser"}"#))
        XCTAssertEqual(CRMActionValidator.company(from: action),
                       .failure(.unknownValue("status", "superuser")))
    }

    func testCompanyRejectsAnOverlongField() {
        let long = String(repeating: "a", count: CRMActionValidator.maxShortField + 1)
        let action = try! XCTUnwrap(decode(#"{"action":"saveCompany","name":"X","website":"\#(long)"}"#))
        XCTAssertEqual(CRMActionValidator.company(from: action),
                       .failure(.tooLong("website", max: CRMActionValidator.maxShortField)))
    }

    func testValidCompanyPassesAndTrimsItsName() throws {
        let action = try XCTUnwrap(decode(#"{"action":"saveCompany","name":"  Aurora  ","status":"active"}"#))
        let company = try XCTUnwrap(try? CRMActionValidator.company(from: action).get())
        XCTAssertEqual(company.name, "Aurora")
        XCTAssertEqual(company.status, .active)
        XCTAssertFalse(company.id.isEmpty, "a create gets a fresh id")
    }

    // MARK: - Opportunity validation

    func testOpportunityRejectsProbabilityOutsideZeroToOneHundred() {
        for value in [-1, 101, 999_999] {
            let action = try! XCTUnwrap(decode(#"{"action":"saveOpportunity","title":"X","probability":\#(value)}"#))
            XCTAssertEqual(CRMActionValidator.opportunity(from: action),
                           .failure(.outOfRange("probability")),
                           "probability \(value) should be refused")
        }
    }

    func testOpportunityRejectsNegativeOrAbsurdValue() {
        let negative = try! XCTUnwrap(decode(#"{"action":"saveOpportunity","title":"X","valueCents":-500}"#))
        XCTAssertEqual(CRMActionValidator.opportunity(from: negative),
                       .failure(.outOfRange("estimated value")))

        let absurd = try! XCTUnwrap(decode(#"{"action":"saveOpportunity","title":"X","valueCents":999999999999}"#))
        XCTAssertEqual(CRMActionValidator.opportunity(from: absurd),
                       .failure(.outOfRange("estimated value")))
    }

    func testOpportunityRejectsAnUnknownStage() {
        let action = try! XCTUnwrap(decode(#"{"action":"saveOpportunity","title":"X","stage":"closed-forever"}"#))
        XCTAssertEqual(CRMActionValidator.opportunity(from: action),
                       .failure(.unknownValue("stage", "closed-forever")))
    }

    func testValidOpportunityPasses() throws {
        let json = #"{"action":"saveOpportunity","title":"Retrofit","stage":"proposal","probability":65,"valueCents":1250000,"nextFollowUpAt":1800000000}"#
        let action = try XCTUnwrap(decode(json))
        let deal = try XCTUnwrap(try? CRMActionValidator.opportunity(from: action).get())
        XCTAssertEqual(deal.title, "Retrofit")
        XCTAssertEqual(deal.stage, .proposal)
        XCTAssertEqual(deal.probability, 65)
        XCTAssertEqual(deal.estimatedValueCents, 1_250_000)
        XCTAssertEqual(deal.nextFollowUpAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: - Contact and activity validation

    func testContactRejectsAnUnknownPreferredMethod() {
        let action = try! XCTUnwrap(decode(#"{"action":"saveContact","name":"X","preferredContact":"telepathy"}"#))
        XCTAssertEqual(CRMActionValidator.contact(from: action),
                       .failure(.unknownValue("preferred contact method", "telepathy")))
    }

    func testActivityRejectsAnUnknownKindAndABlankSummary() {
        let blank = try! XCTUnwrap(decode(#"{"action":"logActivity","summary":"  "}"#))
        XCTAssertEqual(CRMActionValidator.activity(from: blank), .failure(.missing("Activity summary")))

        let kind = try! XCTUnwrap(decode(#"{"action":"logActivity","summary":"hi","kind":"telepathy"}"#))
        XCTAssertEqual(CRMActionValidator.activity(from: kind),
                       .failure(.unknownValue("activity type", "telepathy")))
    }

    func testStageMoveNeedsBothAnIdAndAKnownStage() {
        let noId = try! XCTUnwrap(decode(#"{"action":"setStage","stage":"won"}"#))
        XCTAssertEqual(CRMActionValidator.stage(from: noId), .failure(.missing("Opportunity id")))

        let noStage = try! XCTUnwrap(decode(#"{"action":"setStage","id":"abc"}"#))
        XCTAssertEqual(CRMActionValidator.stage(from: noStage), .failure(.missing("stage")))

        let bogus = try! XCTUnwrap(decode(#"{"action":"setStage","id":"abc","stage":"ascended"}"#))
        XCTAssertEqual(CRMActionValidator.stage(from: bogus), .failure(.unknownValue("stage", "ascended")))
    }

    // MARK: - Saved views

    func testASavedViewNeedsAName() {
        let action = try! XCTUnwrap(decode(#"{"action":"saveView"}"#))
        XCTAssertEqual(CRMActionValidator.savedView(from: action), .failure(.missing("View name")))
    }

    func testASavedViewRejectsUnknownScopeStageAndSort() {
        let scope = try! XCTUnwrap(decode(#"{"action":"saveView","name":"X","scope":"everything"}"#))
        XCTAssertEqual(CRMActionValidator.savedView(from: scope),
                       .failure(.unknownValue("scope", "everything")))

        let stage = try! XCTUnwrap(decode(#"{"action":"saveView","name":"X","stage":"ascended"}"#))
        XCTAssertEqual(CRMActionValidator.savedView(from: stage),
                       .failure(.unknownValue("stage", "ascended")))

        let sort = try! XCTUnwrap(decode(#"{"action":"saveView","name":"X","sortField":"vibes"}"#))
        XCTAssertEqual(CRMActionValidator.savedView(from: sort),
                       .failure(.unknownValue("sort field", "vibes")))
    }

    func testASavedViewRejectsAbsurdFilters() {
        let negative = try! XCTUnwrap(decode(#"{"action":"saveView","name":"X","minValueCents":-1}"#))
        XCTAssertEqual(CRMActionValidator.savedView(from: negative),
                       .failure(.outOfRange("minimum value")))

        let stale = try! XCTUnwrap(decode(#"{"action":"saveView","name":"X","staleDays":99999}"#))
        XCTAssertEqual(CRMActionValidator.savedView(from: stale),
                       .failure(.outOfRange("stale days")))
    }

    func testAValidSavedViewPasses() throws {
        let json = #"{"action":"saveView","name":"Big proposals","scope":"opportunities","stage":"proposal","minValueCents":1000000,"staleDays":30,"sortField":"value","sortAscending":false,"query":"pier"}"#
        let action = try XCTUnwrap(decode(json))
        let view = try XCTUnwrap(try? CRMActionValidator.savedView(from: action).get())
        XCTAssertEqual(view.name, "Big proposals")
        XCTAssertEqual(view.stage, .proposal)
        XCTAssertEqual(view.minValueMinorUnits, 1_000_000)
        XCTAssertEqual(view.staleDays, 30)
        XCTAssertEqual(view.sortField, .value)
        XCTAssertTrue(view.isFiltered)
    }

    // MARK: - Relationships

    func testBlankRelationshipIdsBecomeNilNotEmptyStrings() throws {
        let action = try XCTUnwrap(decode(#"{"action":"saveContact","name":"X","companyId":"   "}"#))
        let contact = try XCTUnwrap(try? CRMActionValidator.contact(from: action).get())
        XCTAssertNil(contact.companyId, "a cleared field means no relationship, not a key of \"\"")
    }

    // MARK: - Injection attempts survive as ordinary text

    /// Nothing here is executed anywhere — the value goes into a bound
    /// parameter and comes back out byte for byte. The page is responsible for
    /// escaping it at render time, which `crm_view_test.js` covers.
    func testHostileTextIsStoredVerbatimRatherThanInterpreted() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AtlasCRMBridgeTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CRMStore(databaseURL: directory.appendingPathComponent("crm.sqlite"))

        let payloads = [
            "<script>alert(1)</script>",
            "Robert'); DROP TABLE companies;--",
            "\" onmouseover=\"alert(1)",
            "100% of _everything_"
        ]
        for text in payloads {
            store.upsert(Company(name: text))
        }
        XCTAssertEqual(store.companies().count, payloads.count,
                       "the companies table still exists and holds every row")
        XCTAssertEqual(Set(store.companies().map(\.name)), Set(payloads),
                       "text comes back exactly as it went in")
    }
}
