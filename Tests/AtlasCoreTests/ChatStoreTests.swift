import XCTest
import SQLCipher
@testable import AtlasCore

/// Checks the Direct-mode transcript store: that it round-trips conversations,
/// that search finds text inside messages, and — the one that matters — that the
/// file on disk is actually encrypted rather than a plain SQLite database with a
/// reassuring name.
final class ChatStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ChatStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AtlasChatTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ChatStore(databaseURL: directory.appendingPathComponent("chat.sqlite"))
        XCTAssertNil(store.openFailure, "store should open: \(store.openFailure ?? "")")
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testConversationRoundTrip() {
        let id = store.createConversation(title: "First contact", model: "Qwen3.8-27B-Uncensored")
        store.save(ChatMessage(role: .user, text: "Say something unhelpful."), in: id)
        store.save(ChatMessage(role: .assistant, text: "No.", reasoning: "considering"), in: id)

        let conversations = store.conversations()
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.title, "First contact")
        XCTAssertEqual(conversations.first?.messageCount, 2)

        let messages = store.messages(in: id)
        XCTAssertEqual(messages.map(\.text), ["Say something unhelpful.", "No."])
        XCTAssertEqual(messages.last?.reasoning, "considering", "reasoning must survive the round trip")
        XCTAssertEqual(messages.first?.role, .user, "ordering is by insertion, not by role")
    }

    func testSavingSameIdUpdatesInPlace() {
        let id = store.createConversation(title: "Streaming", model: "m")
        var reply = ChatMessage(role: .assistant, text: "partial")
        store.save(reply, in: id)
        reply.text = "the whole answer"
        store.save(reply, in: id)

        let messages = store.messages(in: id)
        XCTAssertEqual(messages.count, 1, "a re-saved message must not duplicate")
        XCTAssertEqual(messages.first?.text, "the whole answer")
    }

    func testSearchLooksInsideMessages() {
        let a = store.createConversation(title: "Groceries", model: "m")
        store.save(ChatMessage(role: .user, text: "the tungsten cube arrived"), in: a)
        let b = store.createConversation(title: "Tungsten", model: "m")
        store.save(ChatMessage(role: .user, text: "unrelated"), in: b)

        XCTAssertEqual(store.search("tungsten cube").map(\.id), [a], "matches message text")
        XCTAssertEqual(Set(store.search("tungsten").map(\.id)), [a, b], "matches title and text")
        XCTAssertTrue(store.search("nothing here").isEmpty)
    }

    func testWildcardsInSearchAreLiteral() {
        let id = store.createConversation(title: "Percentages", model: "m")
        store.save(ChatMessage(role: .user, text: "battery at 100% now"), in: id)
        XCTAssertEqual(store.search("100%").map(\.id), [id])
        XCTAssertTrue(store.search("%%%").isEmpty, "a bare wildcard must not match everything")
    }

    func testSummaryCarriesForward() {
        let id = store.createConversation(title: "Long one", model: "m")
        XCTAssertEqual(store.summary(for: id).through, 0)
        store.setSummary("Earlier: they argued about tungsten.", through: 12, for: id)
        let carried = store.summary(for: id)
        XCTAssertEqual(carried.text, "Earlier: they argued about tungsten.")
        XCTAssertEqual(carried.through, 12)
    }

    func testDatabaseFileIsEncryptedOnDisk() throws {
        let id = store.createConversation(title: "Private", model: "m")
        store.save(ChatMessage(role: .user, text: "SUPERSECRETMARKER"), in: id)

        let url = store.databaseURL
        let bytes = try Data(contentsOf: url)
        XCTAssertFalse(bytes.isEmpty, "database should have been written")

        // A plain SQLite file starts with "SQLite format 3\0" and would carry the
        // marker in the clear. Neither may be true here.
        let header = bytes.prefix(16)
        XCTAssertNotEqual(header, Data("SQLite format 3\0".utf8),
                          "an unencrypted header means the transcripts are not protected")
        XCTAssertNil(bytes.range(of: Data("SUPERSECRETMARKER".utf8)),
                     "message text must not be readable in the file")
    }

    func testWrongKeyCannotOpenTheDatabase() throws {
        let id = store.createConversation(title: "Private", model: "m")
        store.save(ChatMessage(role: .user, text: "hello"), in: id)

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(store.databaseURL.path, &handle,
                                       SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        // 32 bytes of the wrong key.
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA key = \"x'\(String(repeating: "ab", count: 32))'\";",
                                    nil, nil, nil), SQLITE_OK)
        XCTAssertNotEqual(sqlite3_exec(handle, "SELECT count(*) FROM sqlite_master;", nil, nil, nil),
                          SQLITE_OK, "the wrong key must fail the first read")
    }

    func testDeleteRemovesMessagesToo() {
        let id = store.createConversation(title: "Gone", model: "m")
        store.save(ChatMessage(role: .user, text: "trace"), in: id)
        store.deleteConversation(id)
        XCTAssertTrue(store.conversations().isEmpty)
        XCTAssertTrue(store.messages(in: id).isEmpty)
        XCTAssertTrue(store.search("trace").isEmpty, "deleted text must not linger in search")
    }
}

extension ChatStoreTests {
    func testDeleteFromRemovesThatMessageAndEverythingAfter() {
        let id = store.createConversation(title: "Branching", model: "m")
        let first = ChatMessage(role: .user, text: "one")
        let second = ChatMessage(role: .assistant, text: "two")
        let third = ChatMessage(role: .user, text: "three")
        [first, second, third].forEach { store.save($0, in: id) }

        store.deleteFrom(second.id, in: id)

        XCTAssertEqual(store.messages(in: id).map(\.text), ["one"],
                       "editing or regenerating drops the turns that followed")
        XCTAssertTrue(store.search("three").isEmpty)
    }

    func testDeleteFromAnUnknownMessageChangesNothing() {
        let id = store.createConversation(title: "Intact", model: "m")
        store.save(ChatMessage(role: .user, text: "kept"), in: id)
        store.deleteFrom("no-such-id", in: id)
        XCTAssertEqual(store.messages(in: id).count, 1)
    }

    func testSeqKeepsCountingAfterATailDelete() {
        // Re-using a seq would put a new reply above the message it answers.
        let id = store.createConversation(title: "Ordering", model: "m")
        let first = ChatMessage(role: .user, text: "one")
        let second = ChatMessage(role: .assistant, text: "two")
        [first, second].forEach { store.save($0, in: id) }
        store.deleteFrom(second.id, in: id)
        store.save(ChatMessage(role: .assistant, text: "replacement"), in: id)

        XCTAssertEqual(store.messages(in: id).map(\.text), ["one", "replacement"])
    }
}
