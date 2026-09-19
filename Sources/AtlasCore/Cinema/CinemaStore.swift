import Foundation
import SQLCipher

/// Durable home for what Cinema remembers: the library, playback progress,
/// per-title source preferences and the Jellyfin connection.
///
/// All of it used to live in the web view's `localStorage`. That looked fine
/// until the app ran without a bundle identifier once, whereupon WebKit handed
/// the page a different, empty container and the whole library appeared to be
/// gone. Nothing had been deleted — but a store that vanishes when the process
/// identity changes is not a store, and it sat outside every backup a person
/// would think to make.
///
/// Encrypted the same way as chat, CRM and expenses, in the same Application
/// Support directory, so Cinema is finally backed up and restored with the rest
/// of ATLAS rather than out of reach in `~/Library/WebKit`.
///
/// Documents, not rows. The page treats the library as one JSON value and never
/// queries across items, so a key/value table keeps the TMDB payloads exactly as
/// the page produced them and leaves no schema to migrate when TMDB adds a
/// field.
// ponytail: whole-document writes — a favourite toggle rewrites ~50KB. Fine at
// a few hundred titles; split into per-item rows if the library gets big enough
// to feel it.
public final class CinemaStore {
    public static let shared = CinemaStore()

    /// Keychain account holding the hex-encoded 256-bit database key.
    private static let keychainAccount = "atlas.cinema.db.key"

    /// Everything the page is allowed to persist.
    ///
    /// A fixed set rather than any key the page names: this is storage the page
    /// drives, and an allowlist means a bug in the page cannot fill the database
    /// with junk keys.
    public enum Key: String, CaseIterable, Sendable {
        case library = "atlas_cinema_library_v1"
        case progress = "atlas_cinema_progress"
        case sources = "atlas_cinema_sources"
        case source = "atlas_cinema_source"
        case jellyfin = "atlas_jellyfin_v1"
        case device = "atlas_device"
        case tmdbKey = "atlas_tmdb_key"
        /// Display-only renames, keyed by source id. The id and its URLs are
        /// untouched — this only changes what the pill says.
        case sourceNames = "atlas_cinema_source_names"
    }

    private var db: OpaquePointer?
    /// Every statement runs here; the C handle is not thread-safe across queues.
    private let queue = DispatchQueue(label: "com.atlas.app.cinemastore")
    public let databaseURL: URL
    /// Set when the store could not be opened, so the page can say why instead
    /// of silently losing a library.
    public private(set) var openFailure: String?

    public init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL()
        queue.sync { open() }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private static func defaultDatabaseURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ATLAS", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("cinema.sqlite")
    }

    // MARK: - Open

    private func databaseKey() -> String? {
        DatabaseKey.resolve(account: Self.keychainAccount,
                            databaseURL: databaseURL,
                            name: "cinema",
                            failure: &openFailure)
    }

    private func open() {
        guard let key = databaseKey() else {
            openFailure = "Could not create or read the cinema encryption key in the Keychain."
            return
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            openFailure = "Could not open \(databaseURL.lastPathComponent)."
            if let handle { sqlite3_close(handle) }
            return
        }
        db = handle

        // Must be the first statement on the connection.
        guard exec("PRAGMA key = \"x'\(key)'\";") else {
            openFailure = "Could not unlock the cinema database."
            close()
            return
        }
        guard exec("SELECT count(*) FROM sqlite_master;") else {
            openFailure = DatabaseKey.mismatchMessage(name: "cinema", fileName: "cinema.sqlite")
            close()
            return
        }
        _ = exec("PRAGMA journal_mode = WAL;")
        createSchema()
    }

    private func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    private func createSchema() {
        _ = exec("""
        CREATE TABLE IF NOT EXISTS cinema_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updatedAt REAL NOT NULL
        );
        """)
    }

    // MARK: - Reading and writing

    /// Every stored value, for hydrating the page in one call.
    public func all() -> [String: String] {
        queue.sync {
            var out: [String: String] = [:]
            guard let db else { return out }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT key, value FROM cinema_state;", -1,
                                     &statement, nil) == SQLITE_OK else { return out }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let k = sqlite3_column_text(statement, 0),
                      let v = sqlite3_column_text(statement, 1) else { continue }
                out[String(cString: k)] = String(cString: v)
            }
            return out
        }
    }

    public func value(for key: Key) -> String? {
        all()[key.rawValue]
    }

    /// True when nothing has ever been stored — the signal that the page should
    /// hand over whatever `localStorage` still holds so it can be adopted.
    public var isEmpty: Bool { all().isEmpty }

    @discardableResult
    public func set(_ key: Key, _ value: String) -> Bool {
        queue.sync {
            run("""
            INSERT INTO cinema_state (key, value, updatedAt) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value,
                                           updatedAt = excluded.updatedAt;
            """, [key.rawValue, value, Date().timeIntervalSince1970])
        }
    }

    @discardableResult
    public func remove(_ key: Key) -> Bool {
        queue.sync { run("DELETE FROM cinema_state WHERE key = ?;", [key.rawValue]) }
    }

    // MARK: - Statement helpers

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var error: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK
        if let error { sqlite3_free(error) }
        return ok
    }

    @discardableResult
    private func run(_ sql: String, _ bindings: [Any?]) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }

        // SQLITE_TRANSIENT: the text is copied, so a Swift String that goes out
        // of scope before step() cannot leave the statement pointing at freed
        // memory.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch binding {
            case let text as String: sqlite3_bind_text(statement, position, text, -1, transient)
            case let number as Double: sqlite3_bind_double(statement, position, number)
            case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
            case nil: sqlite3_bind_null(statement, position)
            default: sqlite3_bind_null(statement, position)
            }
        }
        return sqlite3_step(statement) == SQLITE_DONE
    }
}
