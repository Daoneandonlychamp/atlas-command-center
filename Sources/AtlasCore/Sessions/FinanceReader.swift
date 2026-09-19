import Foundation

/// Reads the sanitised financial snapshot written by Foxtrot.
///
/// ATLAS reads the same file the agent does, for the same reason: the file
/// contains numbers, enums and opaque ids only, because every free-text field is
/// stripped before it is written. Nothing here ever talks to Stripe.
///
/// The honesty rules in Foxtrot's SOUL are enforced here too — test-mode figures
/// are never presented as revenue, an incomplete fetch is labelled a floor rather
/// than a total, and a source that is not wired is reported as missing rather
/// than as zero.
public struct FinanceSnapshot: Codable, Hashable {

    public struct Totals: Codable, Hashable {
        public var complete = false
        public var chargesSeen = 0
        public var paidCount = 0
        public var grossMinorUnits = 0
        public var refundedMinorUnits = 0
        public var netMinorUnits = 0
        public var disputedCount = 0
        public var openDisputeCount = 0
        public var openDisputeMinorUnits = 0
        public var failedPaymentCount = 0
        public var currency = "usd"
        public var activeSubscriptions = 0
        public var payoutCount = 0
        public var unpaidInvoiceCount = 0
    }

    public let generatedAt: Date
    /// "live" or "test". Test figures are not revenue and must never read as such.
    public let mode: String
    public let ok: Bool
    /// False when the fetch stopped at its page ceiling — totals are then a floor.
    public let complete: Bool
    public let droppedTextFields: Int
    public let totals: Totals
    /// Resources the key was not granted, keyed by resource name.
    public let unavailable: [String]

    public var isLive: Bool { mode == "live" }
    public var isStale: Bool { Date().timeIntervalSince(generatedAt) > 86_400 }

    public func amount(_ minorUnits: Int) -> Double { Double(minorUnits) / 100 }
}

/// Infrastructure spend, deliberately partial.
///
/// Only Railway reports a usable figure. Vercel's API exposes a rate card with
/// no usage quantities, and Neon has no key yet — both are named as unreadable
/// rather than counted as zero.
public struct InfraSnapshot: Codable, Hashable {
    public struct Provider: Codable, Hashable {
        public let name: String
        public let available: Bool
        public let currentUSD: Double?
        public let estimatedUSD: Double?
        public let plan: String?
        public let note: String?
        public let uncapped: Bool
    }

    public let generatedAt: Date
    public let knownCurrentUSD: Double
    public let providersCounted: Int
    public let unreadable: [String]
    public let complete: Bool
    public let providers: [Provider]
}

public final class FinanceReader: ObservableObject {
    public static let shared = FinanceReader()

    @Published public private(set) var snapshot: FinanceSnapshot?
    @Published public private(set) var infra: InfraSnapshot?
    /// False when the file has never been produced — Foxtrot has not run yet.
    @Published public private(set) var isConfigured = true

    private let file: URL
    private let infraFile: URL

    public init(file: URL = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent(".hermes/profiles/foxtrot/finance/sanitised.json"),
                infraFile: URL = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent(".hermes/profiles/foxtrot/finance/infra.json")) {
        self.file = file
        self.infraFile = infraFile
    }

    public func refresh() {
        refreshInfra()
        guard FileManager.default.fileExists(atPath: file.path) else {
            isConfigured = false
            snapshot = nil
            return
        }
        isConfigured = true

        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let rawTotals = root["totals"] as? [String: Any] ?? [:]
        var totals = FinanceSnapshot.Totals()
        totals.complete = rawTotals["complete"] as? Bool ?? false
        totals.chargesSeen = rawTotals["charges_seen"] as? Int ?? 0
        totals.paidCount = rawTotals["paid_count"] as? Int ?? 0
        totals.grossMinorUnits = rawTotals["gross_minor_units"] as? Int ?? 0
        totals.refundedMinorUnits = rawTotals["refunded_minor_units"] as? Int ?? 0
        totals.netMinorUnits = rawTotals["net_minor_units"] as? Int ?? 0
        totals.disputedCount = rawTotals["disputed_count"] as? Int ?? 0
        totals.openDisputeCount = rawTotals["open_dispute_count"] as? Int ?? 0
        totals.openDisputeMinorUnits = rawTotals["open_dispute_minor_units"] as? Int ?? 0
        totals.failedPaymentCount = rawTotals["failed_payment_count"] as? Int ?? 0
        totals.currency = rawTotals["currency"] as? String ?? "usd"
        totals.activeSubscriptions = rawTotals["active_subscriptions"] as? Int ?? 0
        totals.payoutCount = rawTotals["payout_count"] as? Int ?? 0
        totals.unpaidInvoiceCount = rawTotals["unpaid_invoice_count"] as? Int ?? 0

        // A `<resource>_error` key means that resource was not fetched. A 403 is
        // a deliberate scope decision, not a fault — either way the UI must say
        // the data is absent rather than show a zero.
        let unavailable = root.keys
            .filter { $0.hasSuffix("_error") }
            .map { String($0.dropLast("_error".count)) }
            .sorted()

        let generated = (root["generated_at"] as? String)
            .flatMap(Self.iso.date(from:))
            ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            ?? Date()

        snapshot = FinanceSnapshot(
            generatedAt: generated,
            mode: root["mode"] as? String ?? "unknown",
            ok: root["ok"] as? Bool ?? false,
            complete: root["complete"] as? Bool ?? totals.complete,
            droppedTextFields: root["dropped_text_fields"] as? Int ?? 0,
            totals: totals,
            unavailable: unavailable
        )
    }

    private func refreshInfra() {
        guard let data = try? Data(contentsOf: infraFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { infra = nil; return }

        let totals = root["totals"] as? [String: Any] ?? [:]
        let rawProviders = root["providers"] as? [String: Any] ?? [:]

        let providers: [InfraSnapshot.Provider] = rawProviders
            .map { name, value in
                let p = value as? [String: Any] ?? [:]
                return InfraSnapshot.Provider(
                    name: name,
                    available: p["available"] as? Bool ?? false,
                    currentUSD: p["current_usd"] as? Double,
                    estimatedUSD: p["estimated_usd"] as? Double,
                    plan: p["plan"] as? String,
                    note: (p["spend_note"] as? String) ?? (p["reason"] as? String),
                    uncapped: p["uncapped"] as? Bool ?? false
                )
            }
            .sorted { $0.name < $1.name }

        infra = InfraSnapshot(
            generatedAt: (root["generated_at"] as? String).flatMap(Self.iso.date(from:)) ?? Date(),
            knownCurrentUSD: totals["known_current_usd"] as? Double ?? 0,
            providersCounted: totals["providers_counted"] as? Int ?? 0,
            unreadable: totals["providers_unreadable"] as? [String] ?? [],
            complete: totals["complete"] as? Bool ?? false,
            providers: providers
        )
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
