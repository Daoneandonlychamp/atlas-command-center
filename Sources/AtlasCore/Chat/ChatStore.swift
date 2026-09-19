import Foundation
import SQLCipher

/// Encrypted transcript store for Direct mode.
///
/// Direct mode talks to unaligned models, so these transcripts are the ones that
/// most deserve to stay private. The database is SQLCipher-encrypted end to end —
/// a raw 256-bit key held in the Keychain, never a passphrase — so search still
/// works normally (the pages decrypt in memory) while the file on disk is opaque
/// to anything that copies it, Time Machine included.
///
/// Sovereign missions keep going to `ActivityLedger`. Nothing here is written
/// there but counts; see `ChatSession` for the metadata that does get logged.
public final class ChatStore {
    public static let shared = ChatStore()

    /// Keychain account holding the hex-encoded 256-bit database key.
    private static let keychainAccount = "atlas.chat.db.key"

    private var db: OpaquePointer?
    /// Every statement runs here; the C handle is not thread-safe across queues.
    private let queue = DispatchQueue(label: "com.atlas.app.chatstore")
    public let databaseURL: URL
    /// Set when the store could not be opened, so the UI can say why instead of
    /// silently losing conversations.
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
        return support.appendingPathComponent("chat.sqlite")
    }

    // MARK: - Open

    /// Returns the raw database key, minting one on first run.
    ///
    /// A random 32-byte key stored as hex and handed to SQLCipher as a raw key
    /// skips the KDF entirely — there is no human passphrase to derive from, and
    /// no quoting hazard in the PRAGMA.
    private func databaseKey() -> String? {
        DatabaseKey.resolve(account: Self.keychainAccount,
                            databaseURL: databaseURL,
                            name: "transcript",
                            failure: &openFailure)
    }

    private func open() {
        guard let key = databaseKey() else {
            openFailure = "Could not create or read the transcript encryption key in the Keychain."
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
            openFailure = "Could not unlock the transcript database."
            close()
            return
        }
        // Proves the key is right: on a wrong key the first read fails here
        // rather than somewhere confusing later.
        guard exec("SELECT count(*) FROM sqlite_master;") else {
            openFailure = DatabaseKey.mismatchMessage(name: "transcript", fileName: "chat.sqlite")
            close()
            return
        }
        _ = exec("PRAGMA foreign_keys = ON;")
        _ = exec("PRAGMA journal_mode = WAL;")
        createSchema()
    }

    private func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    private func createSchema() {
        _ = exec("""
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            model TEXT NOT NULL,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL,
            summary TEXT NOT NULL DEFAULT '',
            summarizedThrough INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            conversationId TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            reasoning TEXT NOT NULL DEFAULT '',
            model TEXT NOT NULL DEFAULT '',
            createdAt REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS messages_by_conversation ON messages (conversationId, seq);
        """)
    }

    // MARK: - Statement helpers

    private var lastError: String {
        guard let db, let message = sqlite3_errmsg(db) else { return "no database" }
        return String(cString: message)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var error: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK
        if let error {
            NSLog("[ATLAS Chat] sql error: %@", String(cString: error))
            sqlite3_free(error)
        }
        return ok
    }

    /// SQLITE_TRANSIENT — tells SQLite to copy the bound bytes, because the Swift
    /// String backing them is gone by the time the statement runs.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ bindings: [Any]) -> OpaquePointer? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            NSLog("[ATLAS Chat] prepare failed: %@ — %@", sql, lastError)
            return nil
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let text as String:
                sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case let number as Double:
                sqlite3_bind_double(statement, index, number)
            case let number as Int:
                sqlite3_bind_int64(statement, index, Int64(number))
            case let date as Date:
                sqlite3_bind_double(statement, index, date.timeIntervalSince1970)
            default:
                sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    @discardableResult
    private func run(_ sql: String, _ bindings: [Any] = []) -> Bool {
        guard let statement = prepare(sql, bindings) else { return false }
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code != SQLITE_DONE && code != SQLITE_ROW {
            NSLog("[ATLAS Chat] step failed: %@ — %@", sql, lastError)
            return false
        }
        return true
    }

    private func query<T>(_ sql: String, _ bindings: [Any] = [], _ row: (OpaquePointer) -> T) -> [T] {
        guard let statement = prepare(sql, bindings) else { return [] }
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { results.append(row(statement)) }
        return results
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    /// The raw database key, for the user to copy somewhere safe.
    ///
    /// It exists only in the login Keychain, so losing that item loses every
    /// transcript with no way back. Handing it over is a deliberate tradeoff the
    /// Settings panel spells out before showing it.
    public func revealDatabaseKey() -> String? {
        KeychainManager.shared.get(key: Self.keychainAccount)
    }

    // MARK: - Conversations

    /// Starts a conversation and returns its id.
    @discardableResult
    public func createConversation(title: String, model: String, id: String = UUID().uuidString) -> String {
        queue.sync {
            let now = Date()
            run("""
            INSERT INTO conversations (id, title, model, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?);
            """, [id, title, model, now, now])
            return id
        }
    }

    public func renameConversation(_ id: String, to title: String) {
        queue.sync {
            run("UPDATE conversations SET title = ?, updatedAt = ? WHERE id = ?;", [title, Date(), id])
        }
    }

    public func deleteConversation(_ id: String) {
        queue.sync {
            // The cascade needs foreign_keys ON, which open() sets; deleting the
            // messages explicitly keeps this correct even if that ever changes.
            run("DELETE FROM messages WHERE conversationId = ?;", [id])
            run("DELETE FROM conversations WHERE id = ?;", [id])
        }
    }

    /// Newest first, for the conversation rail.
    public func conversations(limit: Int = 200) -> [ChatConversation] {
        queue.sync {
            query("""
            SELECT c.id, c.title, c.model, c.createdAt, c.updatedAt,
                   (SELECT count(*) FROM messages m WHERE m.conversationId = c.id)
            FROM conversations c
            ORDER BY c.updatedAt DESC
            LIMIT ?;
            """, [limit]) { row in
                ChatConversation(
                    id: text(row, 0),
                    title: text(row, 1),
                    model: text(row, 2),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 3)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 4)),
                    messageCount: Int(sqlite3_column_int64(row, 5))
                )
            }
        }
    }

    /// Substring match over titles and message text. The whole database is
    /// encrypted, so this runs against decrypted pages in memory — fine at a
    /// personal scale.
    /// ponytail: LIKE scan, swap for FTS5 if the transcript count ever gets big.
    public func search(_ term: String, limit: Int = 50) -> [ChatConversation] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return conversations(limit: limit) }
        // Escape the LIKE wildcards so searching for "100%" means what it says.
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        return queue.sync {
            query("""
            SELECT c.id, c.title, c.model, c.createdAt, c.updatedAt,
                   (SELECT count(*) FROM messages m WHERE m.conversationId = c.id)
            FROM conversations c
            WHERE c.title LIKE ? ESCAPE '\\'
               OR EXISTS (SELECT 1 FROM messages m
                          WHERE m.conversationId = c.id AND m.text LIKE ? ESCAPE '\\')
            ORDER BY c.updatedAt DESC
            LIMIT ?;
            """, [pattern, pattern, limit]) { row in
                ChatConversation(
                    id: text(row, 0),
                    title: text(row, 1),
                    model: text(row, 2),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 3)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 4)),
                    messageCount: Int(sqlite3_column_int64(row, 5))
                )
            }
        }
    }

    // MARK: - Messages

    /// Writes a message, or overwrites it if the id is already there. Streaming
    /// calls this once at the end rather than per token — a token-rate write
    /// would spin the disk for nothing.
    public func save(_ message: ChatMessage, in conversationID: String, model: String = "") {
        queue.sync {
            let next = query("SELECT COALESCE(MAX(seq), 0) + 1 FROM messages WHERE conversationId = ?;",
                             [conversationID]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 1
            run("""
            INSERT INTO messages (id, conversationId, seq, role, text, reasoning, model, createdAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                text = excluded.text,
                reasoning = excluded.reasoning,
                model = excluded.model;
            """, [message.id, conversationID, next, message.role.rawValue,
                  message.text, message.reasoning, model, message.timestamp])
            run("UPDATE conversations SET updatedAt = ? WHERE id = ?;", [Date(), conversationID])
        }
    }

    public func messages(in conversationID: String) -> [ChatMessage] {
        queue.sync {
            query("""
            SELECT id, role, text, reasoning, createdAt
            FROM messages WHERE conversationId = ? ORDER BY seq ASC;
            """, [conversationID]) { row in
                ChatMessage(
                    id: text(row, 0),
                    role: ChatMessage.ChatRole(rawValue: text(row, 1)) ?? .assistant,
                    text: text(row, 2),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(row, 4)),
                    reasoning: text(row, 3)
                )
            }
        }
    }

    /// Drops `message` and everything after it.
    ///
    /// Editing a message rewrites the conversation from that point, and
    /// regenerating replaces the last reply. Both mean the turns that followed no
    /// longer describe this thread, so they go rather than lingering as orphans.
    public func deleteFrom(_ messageID: String, in conversationID: String) {
        queue.sync {
            let seq = query("SELECT seq FROM messages WHERE id = ? AND conversationId = ?;",
                            [messageID, conversationID]) { Int(sqlite3_column_int64($0, 0)) }.first
            guard let seq else { return }
            run("DELETE FROM messages WHERE conversationId = ? AND seq >= ?;", [conversationID, seq])
            run("UPDATE conversations SET updatedAt = ? WHERE id = ?;", [Date(), conversationID])
        }
    }

    // MARK: - Context rollover

    /// The condensed stand-in for turns that have fallen out of the 32K window,
    /// and the message count it covers.
    public func summary(for conversationID: String) -> (text: String, through: Int) {
        queue.sync {
            query("SELECT summary, summarizedThrough FROM conversations WHERE id = ?;",
                  [conversationID]) { (text($0, 0), Int(sqlite3_column_int64($0, 1))) }.first ?? ("", 0)
        }
    }

    public func setSummary(_ summary: String, through count: Int, for conversationID: String) {
        queue.sync {
            run("UPDATE conversations SET summary = ?, summarizedThrough = ? WHERE id = ?;",
                [summary, count, conversationID])
        }
    }
}

/// One saved Direct-mode conversation, as the rail lists it.
public struct ChatConversation: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let model: String
    public let createdAt: Date
    public let updatedAt: Date
    public let messageCount: Int
}
