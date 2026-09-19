import XCTest
@testable import AtlasCore

final class CronServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cron-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeJobs(_ json: String) throws -> URL {
        let url = tempDir.appendingPathComponent("jobs.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Mirrors the real scheduler file: microsecond timestamps, a nested
    /// schedule object, and jobs in each health state.
    private let fixture = """
    {"updated_at":"2026-09-05T17:15:00-04:00","jobs":[
      {"id":"aaa","name":"morning-brief","schedule":{"kind":"cron","expr":"0 7 * * *","display":"0 7 * * *"},
       "schedule_display":"0 7 * * *","enabled":true,"state":"scheduled","last_status":"ok",
       "failure_streak":0,"last_run_at":"2026-09-05T13:09:27.316732-04:00",
       "next_run_at":"2026-09-06T07:00:00-04:00","model":"gpt-5.6-sol","deliver":"local"},
      {"id":"bbb","name":"deploy-watch","schedule":{"kind":"cron","expr":"*/15 * * * *","display":"*/15 * * * *"},
       "enabled":true,"state":"scheduled","last_status":"error","last_error":"script exited 1",
       "failure_streak":3,"last_run_at":"2026-09-05T17:15:00-04:00","next_run_at":null},
      {"id":"ccc","name":"paused-job","schedule_display":"0 3 * * *","enabled":false,
       "state":"paused","last_status":"ok","failure_streak":0}
    ]}
    """

    func testParsesJobsAndClassifiesHealth() throws {
        let service = CronService(
            jobsFile: try writeJobs(fixture),
            executionsDB: tempDir.appendingPathComponent("missing.db")
        )
        service.refresh()

        XCTAssertNil(service.lastError)
        XCTAssertEqual(service.jobs.count, 3)

        // Sorted by name, so deploy-watch comes first.
        let byId = Dictionary(uniqueKeysWithValues: service.jobs.map { ($0.id, $0) })
        XCTAssertEqual(byId["aaa"]?.health, .healthy)
        XCTAssertEqual(byId["bbb"]?.health, .failing)
        XCTAssertEqual(byId["ccc"]?.health, .paused)
        XCTAssertEqual(service.failingCount, 1)
        XCTAssertEqual(service.healthyCount, 1)

        // Schedule falls back to the nested object when the flat key is absent.
        XCTAssertEqual(byId["bbb"]?.scheduleDisplay, "*/15 * * * *")
    }

    func testParsesBothTimestampShapes() {
        // Microsecond precision, as the scheduler actually writes it.
        XCTAssertNotNil(CronService.parseDate("2026-09-05T13:09:27.316732-04:00"))
        // No fractional part at all.
        XCTAssertNotNil(CronService.parseDate("2026-09-06T08:00:00-04:00"))
        XCTAssertNil(CronService.parseDate(nil))
        XCTAssertNil(CronService.parseDate(""))
        XCTAssertNil(CronService.parseDate("not a date"))
    }

    func testMissingFilesDoNotCrashOrLie() throws {
        let service = CronService(
            jobsFile: tempDir.appendingPathComponent("nope.json"),
            executionsDB: tempDir.appendingPathComponent("nope.db")
        )
        service.refresh()

        XCTAssertTrue(service.jobs.isEmpty)
        XCTAssertTrue(service.incidents.isEmpty)
        XCTAssertTrue(service.runs.isEmpty)
        XCTAssertNotNil(service.lastError, "a missing scheduler file must surface, not read as zero jobs")
    }

    func testReadsRunHistoryAndIncidentsFromDatabase() throws {
        let db = tempDir.appendingPathComponent("executions.db")
        let sql = """
        CREATE TABLE executions (id TEXT PRIMARY KEY, job_id TEXT NOT NULL, source TEXT NOT NULL,
          process_id TEXT NOT NULL, pid INTEGER NOT NULL, process_started_at INTEGER,
          status TEXT NOT NULL, claimed_at TEXT NOT NULL, started_at TEXT, finished_at TEXT, error TEXT);
        CREATE TABLE cron_incidents (id TEXT PRIMARY KEY, job_id TEXT NOT NULL, error_sig TEXT NOT NULL,
          state TEXT NOT NULL, failure_type TEXT NOT NULL, first_seen_at TEXT NOT NULL,
          last_seen_at TEXT NOT NULL, acked_at TEXT, closed_at TEXT, error TEXT NOT NULL, output_file TEXT);
        INSERT INTO executions VALUES ('e1','bbb','builtin','p',1,1,'failed','2026-09-05T17:15:00-04:00',NULL,NULL,'boom');
        INSERT INTO executions VALUES ('e2','bbb','builtin','p',1,1,'completed','2026-09-05T17:00:00-04:00',NULL,NULL,NULL);
        INSERT INTO executions VALUES ('e3','aaa','builtin','p',1,1,'completed','2026-09-05T13:09:00-04:00',NULL,NULL,NULL);
        INSERT INTO cron_incidents VALUES ('i1','bbb','sig','detected','script','2026-09-03T09:15:01-04:00',
          '2026-09-03T09:15:01-04:00',NULL,NULL,'exit 1 | stderr had a pipe in it','/tmp/out.log');
        INSERT INTO cron_incidents VALUES ('i2','aaa','sig','detected','agent','2026-09-01T09:15:01-04:00',
          '2026-09-01T09:15:01-04:00',NULL,NULL,'old failure',NULL);
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = [db.path, sql]
        try task.run()
        task.waitUntilExit()
        try XCTSkipIf(task.terminationStatus != 0, "sqlite3 unavailable")

        let service = CronService(jobsFile: try writeJobs(fixture), executionsDB: db)
        service.refresh()

        XCTAssertEqual(service.runs["bbb"]?.total, 2)
        XCTAssertEqual(service.runs["bbb"]?.failureCount, 1)
        XCTAssertEqual(service.runs["aaa"]?.failureCount, 0)

        // Both incidents are unclosed, because Hermes never closes any.
        XCTAssertEqual(service.loggedIncidents.count, 2)
        // A pipe inside the error text must survive the read.
        XCTAssertTrue(service.loggedIncidents.first?.error.contains("|") == true)

        let byId = Dictionary(uniqueKeysWithValues: service.jobs.map { ($0.id, $0) })
        // bbb is failing, so its incident is active.
        XCTAssertEqual(service.activeIncidents(for: byId["bbb"]!).count, 1)
        // aaa's incident is from Sept 1 but it ran green on Sept 5, so it is
        // stale and must not be counted against a healthy job.
        XCTAssertEqual(service.activeIncidents(for: byId["aaa"]!).count, 0)
        XCTAssertEqual(service.activeIncidents.count, 1)
    }
}
