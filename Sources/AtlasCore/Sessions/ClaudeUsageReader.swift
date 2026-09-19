import Foundation

/// Reads the Claude Code rate-limit windows.
///
/// These numbers exist only inside a running Claude Code process, which pipes
/// them to the status line on stdin and persists them nowhere. The status line
/// hook now writes that payload to `~/.claude/atlas-statusline.json`, and this
/// reads it back — the only route to remaining headroom from outside.
///
/// Because the file is written by the status line, it is only fresh while
/// Claude Code is actually running. Age is reported alongside the values so the
/// HUD can say the numbers are stale rather than quietly showing old ones.
public struct ClaudeUsageWindow: Codable, Hashable {
    public let usedPercentage: Double
    public let resetsAt: Date?

    public var remainingPercentage: Double { max(0, 100 - usedPercentage) }

    /// Time until the window rolls over, if it is in the future.
    public var timeUntilReset: TimeInterval? {
        guard let resetsAt else { return nil }
        let interval = resetsAt.timeIntervalSinceNow
        return interval > 0 ? interval : nil
    }
}

public struct ClaudeUsageSnapshot: Codable, Hashable {
    public let fiveHour: ClaudeUsageWindow?
    public let sevenDay: ClaudeUsageWindow?
    public let contextPercentage: Double?
    public let sessionCostUSD: Double?
    public let modelName: String?
    public let capturedAt: Date

    /// Anything older than this reflects a Claude Code session that has since
    /// stopped, so the windows have likely moved on without us.
    public var isStale: Bool { Date().timeIntervalSince(capturedAt) > 300 }
    public var age: TimeInterval { Date().timeIntervalSince(capturedAt) }
}

public final class ClaudeUsageReader: ObservableObject {
    public static let shared = ClaudeUsageReader()

    @Published public private(set) var snapshot: ClaudeUsageSnapshot?
    /// Set when the file has never appeared — meaning the status line hook is
    /// not writing it, which is a setup problem rather than an empty reading.
    @Published public private(set) var isConfigured = true

    private let file: URL

    public init(file: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/atlas-statusline.json")) {
        self.file = file
    }

    public func refresh() {
        guard FileManager.default.fileExists(atPath: file.path) else {
            isConfigured = false
            snapshot = nil
            return
        }
        isConfigured = true

        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // The write is atomic, but the file's own timestamp is the honest
        // measure of how current these numbers are.
        let captured = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()

        let limits = root["rate_limits"] as? [String: Any]
        snapshot = ClaudeUsageSnapshot(
            fiveHour: Self.window(limits?["five_hour"] as? [String: Any]),
            sevenDay: Self.window(limits?["seven_day"] as? [String: Any]),
            contextPercentage: (root["context_window"] as? [String: Any])?["used_percentage"] as? Double
                ?? ((root["context_window"] as? [String: Any])?["used_percentage"] as? Int).map(Double.init),
            sessionCostUSD: (root["cost"] as? [String: Any])?["total_cost_usd"] as? Double,
            modelName: (root["model"] as? [String: Any])?["display_name"] as? String,
            capturedAt: captured
        )
    }

    private static func window(_ raw: [String: Any]?) -> ClaudeUsageWindow? {
        guard let raw else { return nil }
        let used = (raw["used_percentage"] as? Double)
            ?? (raw["used_percentage"] as? Int).map(Double.init)
        guard let used else { return nil }
        let resets = (raw["resets_at"] as? Double) ?? (raw["resets_at"] as? Int).map(Double.init)
        return ClaudeUsageWindow(
            usedPercentage: used,
            resetsAt: resets.map { Date(timeIntervalSince1970: $0) }
        )
    }
}
