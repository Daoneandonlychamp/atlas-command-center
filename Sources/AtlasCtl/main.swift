import Foundation
import AtlasCore

/// A command line way into the Money out database.
///
/// The Finances page is the normal way in, but a form is a poor fit when
/// several records are already written down somewhere else — a pile of
/// subscriptions after a reinstall, a year of invoices. This writes the same
/// records through the same `ExpenseStore`, so the schema, the migrations and
/// the encryption are shared and there is no second code path to keep honest.
///
/// It ships inside Atlas.app and is signed with it, so macOS sees one identity
/// and the Keychain grant is asked for once rather than after every rebuild.

// MARK: - Arguments

/// `--flag value` pairs, which is all this needs.
///
/// No argument-parsing dependency: the whole grammar is flags with values, and
/// a hand-rolled dictionary is smaller than the code to configure a library.
struct Args {
    private var values: [String: String] = [:]
    let positional: [String]

    init(_ argv: [String]) {
        var positional: [String] = []
        var index = 0
        while index < argv.count {
            let token = argv[index]
            if token.hasPrefix("--") {
                let name = String(token.dropFirst(2))
                let next = index + 1 < argv.count ? argv[index + 1] : nil
                if let next, !next.hasPrefix("--") {
                    values[name] = next
                    index += 2
                    continue
                }
                values[name] = "true"          // a bare flag
            } else {
                positional.append(token)
            }
            index += 1
        }
        self.positional = positional
    }

    func string(_ name: String) -> String? { values[name] }
    func flag(_ name: String) -> Bool { values[name] == "true" }

    func require(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else {
            throw Failure("--\(name) is required")
        }
        return value
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Parsing

func minorUnits(_ text: String) throws -> Int {
    guard let value = Money.minorUnits(text), value >= 0 else {
        throw Failure("\(text) is not an amount")
    }
    return value
}

let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = .current
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

func day(_ text: String) throws -> Date {
    guard let date = dayFormatter.date(from: text) else {
        throw Failure("\(text) is not a date — use yyyy-MM-dd")
    }
    return date
}

func cadence(_ text: String?) throws -> BillingCadence {
    guard let text else { return .monthly }
    guard let value = BillingCadence(rawValue: text.lowercased()) else {
        throw Failure("unknown cadence \(text) — one of "
                      + BillingCadence.allCases.map(\.rawValue).joined(separator: ", "))
    }
    return value
}

func category(_ text: String?) throws -> ExpenseCategory {
    guard let text else { return .software }
    guard let value = ExpenseCategory(rawValue: text.lowercased()) else {
        throw Failure("unknown category \(text) — one of "
                      + ExpenseCategory.allCases.map(\.rawValue).joined(separator: ", "))
    }
    return value
}

func money(_ minor: Int) -> String { Money.format(minor) }

// MARK: - Commands

let usage = """
atlasctl — write to the ATLAS Money out database

  sub add --name NAME --amount 21.28 --due 2026-09-14
          [--cadence monthly] [--category software] [--notes TEXT]
  sub list [--all]
  sub rm --id ID

  expense add --what TEXT --amount 12.34 --on 2026-09-01 [--category software]
  expense list [--limit 50]
  expense rm --id ID

Amounts are plain numbers. Dates are yyyy-MM-dd.
Cadences: \(BillingCadence.allCases.map(\.rawValue).joined(separator: ", "))
Categories: \(ExpenseCategory.allCases.map(\.rawValue).joined(separator: ", "))
"""

func run() throws {
    let argv = Array(CommandLine.arguments.dropFirst())
    let args = Args(argv)
    guard args.positional.count >= 2 else { throw Failure(usage) }

    let store = ExpenseStore()
    if let failure = store.openFailure {
        throw Failure("Could not open the expenses database.\n\(failure)")
    }

    switch (args.positional[0], args.positional[1]) {

    case ("sub", "add"):
        let subscription = Subscription(
            name: try args.require("name"),
            amountMinorUnits: try minorUnits(try args.require("amount")),
            cadence: try cadence(args.string("cadence")),
            nextDueOn: try day(try args.require("due")),
            category: try category(args.string("category")),
            notes: args.string("notes") ?? "")
        let saved = store.upsert(subscription)
        print("added \(saved.name) — \(money(saved.amountMinorUnits)) "
              + "\(saved.cadence.title.lowercased()), next \(dayFormatter.string(from: saved.nextDueOn))")

    case ("sub", "list"):
        let subs = store.subscriptions(includeInactive: args.flag("all"))
        guard !subs.isEmpty else { return print("no subscriptions") }
        for sub in subs {
            print("\(sub.id.prefix(8))  \(money(sub.amountMinorUnits).padding(toLength: 10, withPad: " ", startingAt: 0))"
                  + "\(dayFormatter.string(from: sub.nextDueOn))  \(sub.name)")
        }
        let monthly = subs.filter(\.isActive).reduce(0.0) {
            $0 + Double($1.amountMinorUnits) * $1.cadence.timesPerYear / 12
        }
        print(String(format: "monthly total $%.2f", monthly / 100))

    case ("sub", "rm"):
        let id = try args.require("id")
        // Accept the short id the list prints, so nobody has to paste a UUID.
        guard let match = store.subscriptions(includeInactive: true)
            .first(where: { $0.id == id || $0.id.hasPrefix(id) }) else {
            throw Failure("no subscription starting \(id)")
        }
        _ = store.deleteSubscription(match.id)
        print("removed \(match.name)")

    case ("expense", "add"):
        let expense = Expense(
            name: try args.require("what"),
            amountMinorUnits: try minorUnits(try args.require("amount")),
            category: try category(args.string("category")),
            spentOn: try day(try args.require("on")))
        let saved = store.upsert(expense)
        print("added \(saved.name) — \(money(saved.amountMinorUnits)) "
              + "on \(dayFormatter.string(from: saved.spentOn))")

    case ("expense", "rm"):
        let id = try args.require("id")
        guard let match = store.expenses(limit: 5000)
            .first(where: { $0.id == id || $0.id.hasPrefix(id) }) else {
            throw Failure("no expense starting \(id)")
        }
        _ = store.deleteExpense(match.id)
        print("removed \(match.name) — \(money(match.amountMinorUnits))")

    case ("expense", "list"):
        let limit = Int(args.string("limit") ?? "50") ?? 50
        let expenses = store.expenses(limit: limit)
        guard !expenses.isEmpty else { return print("no expenses") }
        for expense in expenses {
            print("\(expense.id.prefix(8))  \(money(expense.amountMinorUnits).padding(toLength: 10, withPad: " ", startingAt: 0))"
                  + "\(dayFormatter.string(from: expense.spentOn))  \(expense.name)")
        }

    default:
        throw Failure(usage)
    }
}

do {
    try run()
} catch let failure as Failure {
    FileHandle.standardError.write(Data((failure.description + "\n").utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data(("\(error)\n").utf8))
    exit(1)
}
