import XCTest
@testable import AtlasCore

/// Checks the invoice paste parser against the shape a real billing console
/// produces — Vercel's, in this case, including the rows that are easy to get
/// wrong: a period in the description, a marketplace line, a zero charge, and
/// an upcoming estimate that has not been billed yet.
final class InvoiceImportTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// Transcribed from a real Vercel billing page.
    private let vercel = """
    Upcoming Invoice Upcoming August 8 - September 8 Estimated Total $20.00
    August 2026 Paid Infrastructure usage & Vercel platform Total Due $29.59 Invoiced Aug 8, 2026
    June 2026 Paid [Marketplace: Neon] for 7/1/2026 - 8/1/2026 + VERO's projects Total Due $21.14 Invoiced Aug 1, 2026
    July 2026 Paid Infrastructure usage & Vercel platform Total Due $21.32 Invoiced Jul 8, 2026
    May 2026 Paid [Marketplace: Neon] for 6/1/2026 - 7/1/2026 + VERO's projects Total Due $20.41 Invoiced Jul 4, 2026
    June 2026 Paid Infrastructure usage & Vercel platform Total Due $21.32 Invoiced Jun 8, 2026
    May 2026 Paid Pro Total Due $21.32 Invoiced May 8, 2026
    May 2026 Paid Observability Plus Total Due $0.00 Invoiced May 7, 2026
    April 2026 Paid Infrastructure usage & Vercel platform Total Due $73.04 Invoiced Apr 5, 2026
    February 2026 Paid Pro Total Due $21.32 Invoiced Feb 5, 2026
    """

    // MARK: - Amounts

    func testTheAmountIsTheLastFigureNotOneFromTheDescription() {
        // "for 7/1/2026 - 8/1/2026" carries numbers that must not be mistaken
        // for money, and the total sits at the end.
        let line = "June 2026 Paid [Marketplace: Neon] for 7/1/2026 - 8/1/2026 Total Due $21.14 Invoiced Aug 1, 2026"
        XCTAssertEqual(InvoiceImport.amountMinorUnits(in: line), 2114)
    }

    func testAmountsWithThousandsSeparatorsAndNoCentsParse() {
        XCTAssertEqual(InvoiceImport.amountMinorUnits(in: "Total $1,250.50"), 125050)
        XCTAssertEqual(InvoiceImport.amountMinorUnits(in: "Total $20"), 2000)
        XCTAssertEqual(InvoiceImport.amountMinorUnits(in: "Total $0.00"), 0)
        XCTAssertNil(InvoiceImport.amountMinorUnits(in: "no money here"))
    }

    // MARK: - Dates

    func testTheBilledDateWinsOverThePeriodItCovers() {
        let line = "June 2026 [Marketplace: Neon] for 7/1/2026 - 8/1/2026 $21.14 Invoiced Aug 1, 2026"
        XCTAssertEqual(InvoiceImport.date(in: line, calendar: calendar), day(2026, 8, 1),
                       "the day it was billed, not the day the period opened")
    }

    func testANumericDateParsesWhenThereIsNoNamedOne() {
        XCTAssertEqual(InvoiceImport.date(in: "Charge 8/14/2026 $9.00", calendar: calendar),
                       day(2026, 8, 14))
    }

    /// "August 2026" on its own is the period, not a billing date. Matching it
    /// would silently put every row on the 1st.
    func testABareMonthAndYearIsNotTreatedAsADate() {
        XCTAssertNil(InvoiceImport.date(in: "August 2026 Paid Total Due $29.59", calendar: calendar))
    }

    // MARK: - Descriptions

    func testTheDescriptionLosesAmountsDatesAndConsoleChrome() {
        let line = "August 2026 Paid Infrastructure usage & Vercel platform Total Due $29.59 Invoiced Aug 8, 2026"
        let description = InvoiceImport.describe(line)
        XCTAssertTrue(description.contains("Infrastructure usage & Vercel platform"), description)
        XCTAssertFalse(description.contains("$"))
        XCTAssertFalse(description.lowercased().contains("invoiced"))
        XCTAssertFalse(description.lowercased().contains("total due"))
        XCTAssertFalse(description.lowercased().contains("paid"))
    }

    // MARK: - The whole paste

    func testTheVercelPasteParsesEveryBilledRow() {
        let rows = InvoiceImport.parse(vercel, calendar: calendar)

        // Nine billed lines. The "Upcoming Invoice" estimate has no billed date
        // and is correctly left out rather than booked as spend.
        XCTAssertEqual(rows.count, 9, rows.map(\.description).joined(separator: " | "))
        XCTAssertFalse(rows.contains { $0.description.lowercased().contains("upcoming") })
    }

    func testRowsComeBackNewestFirstWithTheRightMoney() {
        let rows = InvoiceImport.parse(vercel, calendar: calendar)
        XCTAssertEqual(rows.first?.date, day(2026, 8, 8))
        XCTAssertEqual(rows.first?.amountMinorUnits, 2959)
        XCTAssertEqual(rows.last?.date, day(2026, 2, 5))
        XCTAssertEqual(rows.map(\.amountMinorUnits).reduce(0, +),
                       2959 + 2114 + 2132 + 2041 + 2132 + 2132 + 0 + 7304 + 2132)
    }

    func testAZeroChargeIsKeptButFlagged() {
        let rows = InvoiceImport.parse(vercel, calendar: calendar)
        let zero = rows.first { $0.amountMinorUnits == 0 }
        XCTAssertNotNil(zero, "a $0.00 line is real and should not vanish")
        XCTAssertEqual(zero?.warning, "Zero amount")
    }

    func testTheSameChargeListedTwiceOnlyImportsOnce() {
        let doubled = """
        July 2026 Paid Pro Total Due $21.32 Invoiced Jul 8, 2026
        July 2026 Paid Pro Total Due $21.32 Invoiced Jul 8, 2026
        """
        XCTAssertEqual(InvoiceImport.parse(doubled, calendar: calendar).count, 1)
    }

    func testJunkAndBlankLinesAreIgnored() {
        let messy = """

        Billing history
        August 2026 Paid Pro Total Due $21.32 Invoiced Aug 8, 2026
        Download all invoices
        $ not a real charge
        """
        let rows = InvoiceImport.parse(messy, calendar: calendar)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.amountMinorUnits, 2132)
    }

    // MARK: - Helpers on top

    func testCategoriesAreGuessedFromTheWords() {
        XCTAssertEqual(InvoiceImport.category(for: "Infrastructure usage & Vercel platform"),
                       .infrastructure)
        XCTAssertEqual(InvoiceImport.category(for: "[Marketplace: Neon] for VERO's projects"),
                       .infrastructure)
        XCTAssertEqual(InvoiceImport.category(for: "Pro"), .software)
        XCTAssertEqual(InvoiceImport.category(for: "Something else entirely"), .other)
    }

    /// "Pro" bills $21.32 every month — that is a plan, and worth offering as a
    /// subscription rather than a pile of identical expenses.
    func testASteadyMonthlyChargeIsSuggestedAsASubscription() {
        let steady = """
        Pro Total Due $21.32 Invoiced Aug 8, 2026
        Pro Total Due $21.32 Invoiced Jul 8, 2026
        Pro Total Due $21.32 Invoiced Jun 8, 2026
        Infrastructure usage Total Due $29.59 Invoiced Aug 8, 2026
        Infrastructure usage Total Due $73.04 Invoiced Jul 8, 2026
        Infrastructure usage Total Due $21.32 Invoiced Jun 8, 2026
        """
        let suggestions = InvoiceImport.recurringSuggestions(
            InvoiceImport.parse(steady, calendar: calendar), calendar: calendar)
        XCTAssertEqual(suggestions, ["pro"],
                       "usage that swings from $21 to $73 is not a fixed plan")
    }

    func testNothingInMeansNothingOut() {
        XCTAssertTrue(InvoiceImport.parse("", calendar: calendar).isEmpty)
        XCTAssertTrue(InvoiceImport.parse("   \n  \n", calendar: calendar).isEmpty)
    }
}
