import Foundation

/// Reads the Claude Code session transcripts in `~/.claude/projects` and turns
/// them into token and cost totals.
///
/// The transcripts are large — roughly 640 MB across 150 files for a month —
/// so this parses on a background queue and caches per file. A file is only
/// re-read when its size or modification date changes, which makes every
/// refresh after the first one nearly free.
///
/// The dollar figures are **equivalent API cost**, not a bill. Claude Code
/// subscriptions are not metered per token; this is what the same traffic
/// would have cost through the API, which is the only honest thing the
/// transcripts can tell us.
public struct ModelPricing {
    public let input: Double
    public let cacheWrite: Double
    public let cacheRead: Double
    public let output: Double

    /// Published per-million-token rates. Cache writes bill at 1.25× input and
    /// cache reads at 0.1× input.
    public static let table: [String: ModelPricing] = [
        "claude-opus-5":    ModelPricing(input: 5,  cacheWrite: 6.25,  cacheRead: 0.50, output: 25),
        "claude-opus-4-8":  ModelPricing(input: 5,  cacheWrite: 6.25,  cacheRead: 0.50, output: 25),
        "claude-opus-4-7":  ModelPricing(input: 5,  cacheWrite: 6.25,  cacheRead: 0.50, output: 25),
        "claude-opus-4-6":  ModelPricing(input: 5,  cacheWrite: 6.25,  cacheRead: 0.50, output: 25),
        "claude-fable-5":   ModelPricing(input: 10, cacheWrite: 12.50, cacheRead: 1.00, output: 50),
        "claude-fable-5-1": ModelPricing(input: 10, cacheWrite: 12.50, cacheRead: 1.00, output: 50),
        "claude-sonnet-5":  ModelPricing(input: 2,  cacheWrite: 2.50,  cacheRead: 0.20, output: 10),
        "claude-sonnet-4-6":ModelPricing(input: 3,  cacheWrite: 3.75,  cacheRead: 0.30, output: 15),
        "claude-haiku-4-5": ModelPricing(input: 1,  cacheWrite: 1.25,  cacheRead: 0.10, output: 5),
    ]

    func cost(input i: Int, cacheWrite cw: Int, cacheRead cr: Int, output o: Int) -> Double {
        (Double(i) * input + Double(cw) * cacheWrite + Double(cr) * cacheRead + Double(o) * output) / 1_000_000
    }
}

public struct SessionTokens: Codable, Hashable {
    public var input = 0
    public var cacheWrite = 0
    public var cacheRead = 0
    public var output = 0

    public var total: Int { input + cacheWrite + cacheRead + output }

    static func + (a: SessionTokens, b: SessionTokens) -> SessionTokens {
        SessionTokens(input: a.input + b.input,
                      cacheWrite: a.cacheWrite + b.cacheWrite,
                      cacheRead: a.cacheRead + b.cacheRead,
                      output: a.output + b.output)
    }
}

/// What one transcript file contributed, cached between runs.
struct FileUsage: Codable {
    var modifiedAt: Double
    var size: Int
    var tokens: SessionTokens
    var costByDay: [String: Double]
    var messagesByModel: [String: Int]
    var costByModel: [String: Double]
    var unpricedModels: [String: Int]
}

public final class ClaudeSessionScanner: ObservableObject {
    public static let shared = ClaudeSessionScanner()

    @Published public private(set) var tokens = SessionTokens()
    @Published public private(set) var costByDay: [String: Double] = [:]
    @Published public private(set) var messagesByModel: [String: Int] = [:]
    @Published public private(set) var costByModel: [String: Double] = [:]
    /// Models seen in the transcripts with no published rate — counted, never
    /// guessed at, so the total never silently absorbs an invented price.
    @Published public private(set) var unpricedModels: [String: Int] = [:]
    @Published public private(set) var sessionCount = 0
    @Published public private(set) var isScanning = false
    @Published public private(set) var lastScanDuration: TimeInterval = 0

    private let projectsDir: URL
    private let cacheFile: URL
    private let windowDays: Int
    private var cache: [String: FileUsage] = [:]
    private let queue = DispatchQueue(label: "atlas.sessions", qos: .utility)

    public init(
        projectsDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects"),
        cacheFile: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ATLAS/session_usage_cache.json"),
        windowDays: Int = 30
    ) {
        self.projectsDir = projectsDir
        self.cacheFile = cacheFile
        self.windowDays = windowDays
        loadCache()
    }

    public var totalCost: Double { costByDay.values.reduce(0, +) }

    public func cost(onDay day: String) -> Double { costByDay[day] ?? 0 }

    public var todayCost: Double { cost(onDay: Self.dayFormatter.string(from: Date())) }

    /// Newest day last, one entry per day in the window including empty days,
    /// so a heatmap or sparkline can render without filling gaps itself.
    public var dailySeries: [(day: String, cost: Double)] {
        let cal = Calendar.current
        return (0..<windowDays).reversed().compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            let key = Self.dayFormatter.string(from: date)
            return (key, costByDay[key] ?? 0)
        }
    }

    public func refresh(completion: (() -> Void)? = nil) {
        guard !isScanning else { completion?(); return }
        isScanning = true

        queue.async { [self] in
            let started = Date()
            let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86400)
            let files = transcripts(modifiedAfter: cutoff)

            var updated: [String: FileUsage] = [:]
            for file in files {
                let path = file.path
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                      let size = attrs[.size] as? Int else { continue }

                if let hit = cache[path], hit.modifiedAt == modified, hit.size == size {
                    updated[path] = hit
                    continue
                }
                updated[path] = parse(file, modifiedAt: modified, size: size)
            }

            var totals = SessionTokens()
            var days: [String: Double] = [:]
            var byModel: [String: Int] = [:]
            var costModel: [String: Double] = [:]
            var unpriced: [String: Int] = [:]
            for usage in updated.values {
                totals = totals + usage.tokens
                usage.costByDay.forEach { days[$0.key, default: 0] += $0.value }
                usage.messagesByModel.forEach { byModel[$0.key, default: 0] += $0.value }
                usage.costByModel.forEach { costModel[$0.key, default: 0] += $0.value }
                usage.unpricedModels.forEach { unpriced[$0.key, default: 0] += $0.value }
            }

            let elapsed = Date().timeIntervalSince(started)
            cache = updated
            saveCache()

            DispatchQueue.main.async {
                self.tokens = totals
                self.costByDay = days
                self.messagesByModel = byModel
                self.costByModel = costModel
                self.unpricedModels = unpriced
                self.sessionCount = updated.count
                self.lastScanDuration = elapsed
                self.isScanning = false
                completion?()
            }
        }
    }

    // MARK: - Parsing

    private func transcripts(modifiedAfter cutoff: Date) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate, modified > cutoff else { continue }
            found.append(url)
        }
        return found
    }

    /// Scans line by line and only decodes the lines that can carry usage.
    /// A transcript is mostly tool output, so the substring check skips the
    /// large majority of the bytes without ever building a JSON object.
    private func parse(_ file: URL, modifiedAt: Double, size: Int) -> FileUsage {
        var usage = FileUsage(modifiedAt: modifiedAt, size: size, tokens: SessionTokens(),
                              costByDay: [:], messagesByModel: [:], costByModel: [:], unpricedModels: [:])
        guard let handle = try? FileHandle(forReadingFrom: file) else { return usage }
        defer { try? handle.close() }

        let assistantMarker = Array("\"type\":\"assistant\"".utf8)
        let usageMarker = Array("\"usage\"".utf8)
        let newline = UInt8(0x0A)

        // Only the tail of a chunk that has no newline yet is ever copied.
        // Re-slicing one growing buffer per line is quadratic and costs about
        // eight times as much wall clock on a month of transcripts.
        var partial = Data()

        func consume(_ line: Data) {
            guard Self.contains(line, usageMarker), Self.contains(line, assistantMarker) else { return }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let raw = message["usage"] as? [String: Any] else { return }

            let model = message["model"] as? String ?? "unknown"
            let input = raw["input_tokens"] as? Int ?? 0
            let cacheWrite = raw["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead = raw["cache_read_input_tokens"] as? Int ?? 0
            let output = raw["output_tokens"] as? Int ?? 0

            guard let pricing = ModelPricing.table[model] else {
                usage.unpricedModels[model, default: 0] += 1
                return
            }

            usage.tokens.input += input
            usage.tokens.cacheWrite += cacheWrite
            usage.tokens.cacheRead += cacheRead
            usage.tokens.output += output
            usage.messagesByModel[model, default: 0] += 1

            let cost = pricing.cost(input: input, cacheWrite: cacheWrite, cacheRead: cacheRead, output: output)
            usage.costByModel[model, default: 0] += cost
            if let stamp = object["timestamp"] as? String, stamp.count >= 10 {
                usage.costByDay[String(stamp.prefix(10)), default: 0] += cost
            }
        }

        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty else { return false }
            var cursor = chunk.startIndex
            while let breakIndex = chunk[cursor...].firstIndex(of: newline) {
                if partial.isEmpty {
                    consume(chunk[cursor..<breakIndex])
                } else {
                    partial.append(chunk[cursor..<breakIndex])
                    consume(partial)
                    partial = Data()
                }
                cursor = chunk.index(after: breakIndex)
            }
            if cursor < chunk.endIndex { partial.append(chunk[cursor...]) }
            return true
        }) {}
        if !partial.isEmpty { consume(partial) }

        return usage
    }

    /// `Data.range(of:)` walks the buffer through Foundation's generic path and
    /// dominates the scan; `memmem` does the same search several times faster.
    private static func contains(_ haystack: Data, _ needle: [UInt8]) -> Bool {
        haystack.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress, raw.count >= needle.count else { return false }
            return needle.withUnsafeBufferPointer { pattern in
                memmem(base, raw.count, pattern.baseAddress!, pattern.count) != nil
            }
        }
    }

    // MARK: - Cache

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheFile),
              let decoded = try? JSONDecoder().decode([String: FileUsage].self, from: data) else { return }
        cache = decoded
    }

    private func saveCache() {
        let dir = cacheFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
