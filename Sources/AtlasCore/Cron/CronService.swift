import Foundation

/// Reads the Hermes Sovereign cron scheduler's on-disk state.
///
/// Why this lives in ATLAS: the scheduler already records everything worth
/// knowing — `jobs.json` carries each job's schedule, next fire, last status
/// and failure streak, and `executions.db` carries the full run history plus
/// an incident table. Until now none of it was visible anywhere except by
/// opening files by hand.
///
/// Strictly read-only. ATLAS never edits jobs or writes to the database;
/// pausing or firing a job stays a Hermes-side action.
public struct CronJob: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let scheduleDisplay: String
    public let enabled: Bool
    public let state: String
    public let lastStatus: String?
    public let lastError: String?
    public let failureStreak: Int
    public let lastRunAt: Date?
    public let nextRunAt: Date?
    public let model: String?
    public let deliver: String?

    /// Amber for a paused or disabled job, red for one that is currently
    /// failing, green only when the last run actually succeeded.
    public enum Health { case healthy, failing, paused, unknown }

    public var health: Health {
        if !enabled || state == "paused" { return .paused }
        if failureStreak > 0 { return .failing }
        switch lastStatus {
        case "ok", "completed": return .healthy
        case .some(let s) where !s.isEmpty: return .failing
        default: return .unknown
        }
    }
}

public struct CronIncident: Identifiable, Hashable {
    public let id: String
    public let jobId: String
    public let state: String
    public let failureType: String
    public let error: String
    public let lastSeenAt: Date?
    public let closedAt: Date?
    public let outputFile: String?

    /// Faithful to the schema, but see `CronService.activeIncidents(for:)` —
    /// nothing in Hermes ever sets `closed_at`, so this alone means very little.
    public var isUnclosed: Bool { closedAt == nil }
}

/// One job's recent run outcomes, newest first — enough for a pass/fail strip.
public struct CronRunSummary: Hashable {
    public let jobId: String
    public let recentStatuses: [String]

    public var failureCount: Int { recentStatuses.filter { $0 == "failed" }.count }
    public var total: Int { recentStatuses.count }
}

public final class CronService: ObservableObject {
    public static let shared = CronService()

    @Published public private(set) var jobs: [CronJob] = []
    @Published public private(set) var incidents: [CronIncident] = []
    @Published public private(set) var runs: [String: CronRunSummary] = [:]
    @Published public private(set) var lastError: String?

    /// How many recent executions to pull. The table is small (hundreds of
    /// rows) so one bounded query beats a query per job.
    private let recentRunLimit = 400

    private let jobsFile: URL
    private let executionsDB: URL

    public init(
        jobsFile: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes/profiles/sovereign/cron/jobs.json"),
        executionsDB: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes/profiles/sovereign/cron/executions.db")
    ) {
        self.jobsFile = jobsFile
        self.executionsDB = executionsDB
    }

    public var failingCount: Int { jobs.filter { $0.health == .failing }.count }
    public var healthyCount: Int { jobs.filter { $0.health == .healthy }.count }

    /// Incidents that still describe reality.
    ///
    /// Hermes records incidents but never closes them — every row in the table
    /// has a null `closed_at`, including failures from weeks ago on jobs that
    /// have run green many times since. Counting those as open would put a
    /// scary number next to a healthy fleet, so an incident only counts while
    /// the job is still failing, or while it is newer than the job's last
    /// successful run.
    public func activeIncidents(for job: CronJob) -> [CronIncident] {
        incidents.filter { incident in
            guard incident.jobId == job.id, incident.isUnclosed else { return false }
            if job.health == .failing { return true }
            guard let lastGood = job.lastRunAt, let seen = incident.lastSeenAt else { return true }
            return seen >= lastGood
        }
    }

    public var activeIncidents: [CronIncident] { jobs.flatMap(activeIncidents(for:)) }

    /// Everything unclosed, active or not — the raw failure log.
    public var loggedIncidents: [CronIncident] { incidents.filter(\.isUnclosed) }

    public func refresh() {
        loadJobs()
        loadExecutions()
    }

    // MARK: - jobs.json

    /// Hand-decoded rather than Codable: the scheduler writes 30+ keys, many
    /// of them null or shaped differently per job, and a struct that has to
    /// match all of them breaks every time Hermes adds a field.
    private func loadJobs() {
        do {
            let data = try Data(contentsOf: jobsFile)
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let raw = root?["jobs"] as? [[String: Any]] ?? []

            jobs = raw.compactMap { j -> CronJob? in
                guard let id = j["id"] as? String, let name = j["name"] as? String else { return nil }
                let schedule = (j["schedule_display"] as? String)
                    ?? ((j["schedule"] as? [String: Any])?["display"] as? String)
                    ?? "—"
                return CronJob(
                    id: id,
                    name: name,
                    scheduleDisplay: schedule,
                    enabled: j["enabled"] as? Bool ?? false,
                    state: j["state"] as? String ?? "unknown",
                    lastStatus: j["last_status"] as? String,
                    lastError: j["last_error"] as? String,
                    failureStreak: j["failure_streak"] as? Int ?? 0,
                    lastRunAt: Self.parseDate(j["last_run_at"] as? String),
                    nextRunAt: Self.parseDate(j["next_run_at"] as? String),
                    model: j["model"] as? String,
                    deliver: j["deliver"] as? String
                )
            }
            .sorted { ($0.name) < ($1.name) }
            lastError = nil
        } catch {
            jobs = []
            lastError = "Could not read the cron scheduler: \(error.localizedDescription)"
        }
    }

    // MARK: - executions.db

    private func loadExecutions() {
        guard FileManager.default.fileExists(atPath: executionsDB.path) else {
            runs = [:]
            incidents = []
            return
        }

        let rows = query("""
            SELECT job_id, status FROM executions
            ORDER BY claimed_at DESC, id DESC LIMIT \(recentRunLimit);
            """)
        var grouped: [String: [String]] = [:]
        for row in rows {
            guard let job = row["job_id"] as? String, let status = row["status"] as? String else { continue }
            grouped[job, default: []].append(status)
        }
        runs = grouped.reduce(into: [:]) { acc, pair in
            acc[pair.key] = CronRunSummary(jobId: pair.key, recentStatuses: pair.value)
        }

        let incidentRows = query("""
            SELECT id, job_id, state, failure_type, error, last_seen_at, closed_at, output_file
            FROM cron_incidents ORDER BY last_seen_at DESC LIMIT 50;
            """)
        incidents = incidentRows.compactMap { row in
            guard let id = row["id"] as? String, let job = row["job_id"] as? String else { return nil }
            return CronIncident(
                id: id,
                jobId: job,
                state: row["state"] as? String ?? "unknown",
                failureType: row["failure_type"] as? String ?? "unknown",
                error: row["error"] as? String ?? "",
                lastSeenAt: Self.parseDate(row["last_seen_at"] as? String),
                closedAt: Self.parseDate(row["closed_at"] as? String),
                outputFile: row["output_file"] as? String
            )
        }
    }

    /// Shelling out to the system `sqlite3` in JSON mode: the database is
    /// owned and actively written by the Hermes gateway, so ATLAS opening its
    /// own handle would mean fighting over WAL locks for read-only data.
    /// JSON mode rather than the default pipe separator because error text in
    /// the incident table contains pipes.
    private func query(_ sql: String) -> [[String: Any]] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        // Deliberately a plain connection. `-readonly` is not a flag the
        // macOS sqlite3 understands (it takes it as the filename and returns
        // nothing), and the `?mode=ro` URI form fails intermittently because a
        // read-only connection cannot create the shared-memory index a
        // WAL database needs while the Hermes gateway is writing to it.
        // Only SELECTs are ever issued here.
        task.arguments = ["-json", executionsDB.path, sql]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0, !out.isEmpty else { return [] }
            return (try? JSONSerialization.jsonObject(with: out)) as? [[String: Any]] ?? []
        } catch {
            lastError = "Could not read the execution history: \(error.localizedDescription)"
            return []
        }
    }

    // MARK: - Dates

    /// The scheduler writes both `...T08:00:00-04:00` and
    /// `...T13:09:27.316732-04:00`, so both have to parse.
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let d = fractional.date(from: raw) ?? plain.date(from: raw) { return d }
        // Hermes writes microsecond precision; ISO8601DateFormatter only takes
        // milliseconds, so trim the fraction to three digits and retry.
        let trimmed = raw.replacingOccurrences(
            of: #"\.(\d{3})\d+"#,
            with: ".$1",
            options: .regularExpression
        )
        return fractional.date(from: trimmed) ?? plain.date(from: trimmed)
    }
}
