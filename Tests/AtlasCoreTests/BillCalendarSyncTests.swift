import XCTest
@testable import AtlasCore

/// Checks what a calendar sync *would* do, without EventKit in the room.
///
/// `BillCalendarSync.plan` is where every decision is made — whether to create,
/// update, remove or leave alone. Testing it directly means the rules that keep
/// this from duplicating or churning the user's real Reminders are covered
/// without a single write.
final class BillCalendarSyncTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func sub(due: Date, active: Bool = true, amount: Int = 5999) -> Subscription {
        Subscription(name: "Adobe CC", amountMinorUnits: amount, cadence: .monthly,
                     nextDueOn: due, isActive: active)
    }

    // MARK: - Deciding

    func testAFreshSubscriptionIsCreated() {
        let action = BillCalendarSync.plan(for: sub(due: day(2026, 9, 12)), calendar: calendar)
        guard case .create(let title, let due, _) = action else {
            return XCTFail("expected create, got \(action)")
        }
        XCTAssertEqual(title, "Adobe CC — $59.99")
        XCTAssertEqual(due, day(2026, 9, 12))
    }

    /// The check that stops a repeat sync churning the user's Reminders.
    func testNothingHappensWhenTheDueDateHasNotMoved() {
        let due = day(2026, 9, 12)
        let action = BillCalendarSync.plan(for: sub(due: due), reminderId: "r1", eventId: "e1",
                                           syncedDueOn: due, calendar: calendar)
        XCTAssertEqual(action, .upToDate)
    }

    func testTheSameDayAtADifferentTimeStillCountsAsUpToDate() {
        let due = day(2026, 9, 12)
        let laterThatDay = due.addingTimeInterval(60 * 60 * 9)
        let action = BillCalendarSync.plan(for: sub(due: laterThatDay), reminderId: "r1",
                                           eventId: "e1", syncedDueOn: due, calendar: calendar)
        XCTAssertEqual(action, .upToDate, "a time-of-day difference is not a reschedule")
    }

    func testAMovedDueDateUpdatesWhatWasAlreadyWritten() {
        let action = BillCalendarSync.plan(for: sub(due: day(2026, 10, 12)), reminderId: "r1",
                                           eventId: "e1", syncedDueOn: day(2026, 9, 12),
                                           calendar: calendar)
        guard case .update(let reminderId, let eventId, _, let due, _) = action else {
            return XCTFail("expected update, got \(action)")
        }
        XCTAssertEqual(reminderId, "r1", "it edits the entry it made, rather than adding another")
        XCTAssertEqual(eventId, "e1")
        XCTAssertEqual(due, day(2026, 10, 12))
    }

    func testArchivingASubscriptionTakesItsBillOffTheCalendar() {
        let action = BillCalendarSync.plan(for: sub(due: day(2026, 9, 12), active: false),
                                           reminderId: "r1", eventId: "e1",
                                           syncedDueOn: day(2026, 9, 12), calendar: calendar)
        XCTAssertEqual(action, .remove(reminderId: "r1", eventId: "e1"))
    }

    func testAnArchivedSubscriptionThatWasNeverSyncedDoesNothing() {
        let action = BillCalendarSync.plan(for: sub(due: day(2026, 9, 12), active: false),
                                           calendar: calendar)
        XCTAssertEqual(action, .upToDate, "nothing was written, so there is nothing to remove")
    }

    func testAPartiallySyncedSubscriptionIsRepairedRatherThanDuplicated() {
        // The reminder landed but the event did not, on a due date that moved.
        let action = BillCalendarSync.plan(for: sub(due: day(2026, 10, 1)), reminderId: "r1",
                                           eventId: "", syncedDueOn: day(2026, 9, 1),
                                           calendar: calendar)
        guard case .update = action else { return XCTFail("expected update, got \(action)") }
    }

    // MARK: - What it writes

    func testTheTitleCarriesTheAmountBecauseAPhoneShowsLittleElse() {
        XCTAssertEqual(BillCalendarSync.title(for: sub(due: day(2026, 9, 1), amount: 5999)),
                       "Adobe CC — $59.99")
        XCTAssertEqual(BillCalendarSync.title(for: sub(due: day(2026, 9, 1), amount: 800)),
                       "Adobe CC — $8")
    }

    func testNotesNameTheCadenceAndFlagAPriceRise() {
        var record = sub(due: day(2026, 9, 12), amount: 1200)
        record.previousAmountMinorUnits = 1000
        let notes = BillCalendarSync.notes(for: record)
        XCTAssertTrue(notes.contains("Monthly"))
        XCTAssertTrue(notes.contains("Price up $2"), notes)
        XCTAssertTrue(notes.contains("Tracked by ATLAS."))
    }

    func testNotesSayNothingAboutPriceWhenItNeverMoved() {
        XCTAssertFalse(BillCalendarSync.notes(for: sub(due: day(2026, 9, 1))).contains("Price"))
    }

    func testMoneyFormatsWholeUnitsWithoutTrailingZeroes() {
        XCTAssertEqual(BillCalendarSync.money(0), "$0")
        XCTAssertEqual(BillCalendarSync.money(900), "$9")
        XCTAssertEqual(BillCalendarSync.money(125050), "$1,250.50")
        XCTAssertEqual(BillCalendarSync.money(-2500), "-$25")
        XCTAssertEqual(BillCalendarSync.money(1999, "eur"), "EUR 19.99")
    }

    // MARK: - The boundary

    /// ATLAS writes only into containers it made and named. If these constants
    /// ever change to something generic, a sync could start editing a list the
    /// user already had.
    func testItOnlyEverOwnsItsOwnNamedContainers() {
        XCTAssertEqual(BillCalendarSync.listName, "ATLAS Bills")
        XCTAssertEqual(BillCalendarSync.calendarName, "ATLAS Bills")
        XCTAssertTrue(BillCalendarSync.listName.hasPrefix("ATLAS"))
        XCTAssertTrue(BillCalendarSync.calendarName.hasPrefix("ATLAS"))
    }
}
