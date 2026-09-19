import XCTest
@testable import AtlasCore

/// Ideas exist to stay out of the pipeline until they earn their way in, so the
/// separation and the promotion path are what these cover.
final class IdeaStoreTests: XCTestCase {
    private var store: CRMStore!
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("idea-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = CRMStore(databaseURL: folder.appendingPathComponent("crm.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: folder)
    }

    func testAnIdeaRoundTrips() {
        let saved = store.upsert(Idea(title: "Food truck POS",
                                      pitch: "Card reader that works with no signal",
                                      category: .product,
                                      nextStep: "Ask Reyes what they use now"))
        let loaded = store.idea(saved.id)
        XCTAssertEqual(loaded?.title, "Food truck POS")
        XCTAssertEqual(loaded?.status, .spark)
        XCTAssertEqual(loaded?.nextStep, "Ask Reyes what they use now")
        XCTAssertFalse(loaded?.isPromoted ?? true)
    }

    /// The whole reason ideas are not Companies: they must not reach the
    /// pipeline figures until promoted.
    func testIdeasStayOutOfThePipeline() {
        store.upsert(Idea(title: "Newsletter", potential: .high))
        store.upsert(Idea(title: "Consulting"))

        XCTAssertTrue(store.companies().isEmpty)
        XCTAssertTrue(store.opportunities().isEmpty)
        XCTAssertEqual(store.ideas().count, 2)
    }

    func testParkedIdeasSortLastButAreStillThere() {
        store.upsert(Idea(title: "Parked one", status: .parked))
        let live = store.upsert(Idea(title: "Live one", status: .exploring))

        let all = store.ideas()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.id, live.id)
        XCTAssertEqual(all.last?.title, "Parked one")
    }

    func testSearchCoversPitchAndNextStep() {
        store.upsert(Idea(title: "Unrelated", pitch: "solar panels"))
        store.upsert(Idea(title: "Also unrelated", nextStep: "call the solar guy"))
        store.upsert(Idea(title: "Nothing here", pitch: "bakery"))

        XCTAssertEqual(store.ideas(matching: "solar").count, 2)
    }

    // MARK: - promotion

    func testPromotionCreatesACompanyAndAnOpportunity() throws {
        let idea = store.upsert(Idea(title: "Mobile detailing",
                                     pitch: "Come to them",
                                     category: .service,
                                     notes: "Weekends only at first"))

        let promotion = try XCTUnwrap(store.promote(ideaId: idea.id, estimatedValueCents: 250_000))

        XCTAssertEqual(promotion.company.name, "Mobile detailing")
        XCTAssertEqual(promotion.opportunity.title, "Mobile detailing")
        XCTAssertEqual(promotion.opportunity.estimatedValueCents, 250_000)
        XCTAssertEqual(promotion.opportunity.stage, .lead)
        XCTAssertEqual(promotion.opportunity.companyId, promotion.company.id)
        // The notes travel, so context is not lost at the boundary.
        XCTAssertEqual(promotion.opportunity.notes, "Weekends only at first")
    }

    func testPromotionKeepsTheIdeaAndLinksIt() throws {
        let idea = store.upsert(Idea(title: "Zine subscription"))
        let promotion = try XCTUnwrap(store.promote(ideaId: idea.id))

        let after = try XCTUnwrap(store.idea(idea.id))
        XCTAssertTrue(after.isPromoted)
        XCTAssertEqual(after.promotedOpportunityId, promotion.opportunity.id)
        XCTAssertEqual(after.status, .running)
    }

    /// A double click must not create two deals.
    func testAnIdeaCannotBePromotedTwice() throws {
        let idea = store.upsert(Idea(title: "Only once"))
        XCTAssertNotNil(store.promote(ideaId: idea.id))
        XCTAssertNil(store.promote(ideaId: idea.id))
        XCTAssertEqual(store.opportunities().count, 1)
    }

    func testPromotingSomethingThatDoesNotExistIsNotACrash() {
        XCTAssertNil(store.promote(ideaId: "no-such-idea"))
    }

    func testPromotionCanNameTheCompanySomethingElse() throws {
        let idea = store.upsert(Idea(title: "Coffee cart"))
        let promotion = try XCTUnwrap(store.promote(ideaId: idea.id, companyName: "Reyes Coffee Co"))
        XCTAssertEqual(promotion.company.name, "Reyes Coffee Co")
        // The idea keeps its own name.
        XCTAssertEqual(promotion.opportunity.title, "Coffee cart")
    }

    func testPromotionIsRecordedAsActivity() throws {
        let idea = store.upsert(Idea(title: "Print shop"))
        let promotion = try XCTUnwrap(store.promote(ideaId: idea.id))

        let entries = store.activities(companyId: promotion.company.id)
        XCTAssertTrue(entries.contains { $0.summary.contains("Print shop") },
                      "the deal should say where it came from")
    }

    /// Deleting the deal must not take the idea's history with it.
    func testDeletingThePromotedDealLeavesTheIdea() throws {
        let idea = store.upsert(Idea(title: "Survives"))
        let promotion = try XCTUnwrap(store.promote(ideaId: idea.id))

        _ = store.deleteOpportunity(promotion.opportunity.id)

        let after = try XCTUnwrap(store.idea(idea.id))
        XCTAssertEqual(after.title, "Survives")
        XCTAssertNil(after.promotedOpportunityId, "the dangling link should clear, not orphan")
    }

    func testDeletingAnIdea() {
        let idea = store.upsert(Idea(title: "Temporary"))
        XCTAssertEqual(store.deleteIdea(idea.id), .deleted)
        XCTAssertEqual(store.deleteIdea(idea.id), .notFound)
    }
}
