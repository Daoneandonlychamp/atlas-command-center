import XCTest

@testable import AtlasCore

/// The store that replaced Cinema's `localStorage`.
///
/// The bug being prevented: WebKit partitions `localStorage` by the app's bundle
/// identifier, so running ATLAS without one handed the page a blank container
/// and a 48-title library looked deleted. These check the replacement actually
/// keeps what it is given, in a file that lives with the rest of ATLAS's data.
final class CinemaStoreTests: XCTestCase {

    private var store: CinemaStore!
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cinema-test-\(UUID().uuidString).sqlite")
        store = CinemaStore(databaseURL: url)
    }

    override func tearDown() {
        store = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
                    .appendingPathComponent(url.lastPathComponent + suffix))
        }
        super.tearDown()
    }

    func testStoreOpens() {
        XCTAssertNil(store.openFailure, "the cinema store must open cleanly")
    }

    /// Empty is the signal that the page should hand over what localStorage held.
    func testEmptyUntilSomethingIsWritten() {
        XCTAssertTrue(store.isEmpty)
        store.set(.library, "{}")
        XCTAssertFalse(store.isEmpty)
    }

    func testValuesRoundTrip() {
        store.set(.library, #"{"version":1,"favorites":[]}"#)
        XCTAssertEqual(store.value(for: .library), #"{"version":1,"favorites":[]}"#)
    }

    func testWritingTwiceReplacesRatherThanDuplicates() {
        store.set(.source, "jellyfin")
        store.set(.source, "videasy")
        XCTAssertEqual(store.value(for: .source), "videasy")
        XCTAssertEqual(store.all().count, 1)
    }

    func testRemoveDeletes() {
        store.set(.device, "ehlvzouxwc")
        store.remove(.device)
        XCTAssertNil(store.value(for: .device))
    }

    /// An empty string is a value someone chose, not a delete.
    func testEmptyStringIsStoredRatherThanTreatedAsAbsent() {
        store.set(.tmdbKey, "")
        XCTAssertEqual(store.value(for: .tmdbKey), "")
        XCTAssertFalse(store.isEmpty)
    }

    /// The whole point: it is still there after the process that wrote it is gone.
    func testSurvivesReopening() {
        store.set(.library, #"{"favorites":[{"id":1402}]}"#)
        store = nil

        let reopened = CinemaStore(databaseURL: url)
        XCTAssertEqual(reopened.value(for: .library), #"{"favorites":[{"id":1402}]}"#)
    }

    /// A real library-sized payload, since the page writes the whole document on
    /// every favourite toggle.
    func testHoldsAFullSizedLibrary() throws {
        let items = (0..<80).map { index in
            #"{"id":\#(index),"name":"Title \#(index)","overview":"\#(String(repeating: "x", count: 400))"}"#
        }
        let library = #"{"version":1,"favorites":[\#(items.joined(separator: ","))]}"#
        XCTAssertGreaterThan(library.count, 30_000)

        store.set(.library, library)
        XCTAssertEqual(store.value(for: .library), library)
    }

    /// Every key the page is allowed to persist is distinct, so one cannot
    /// quietly overwrite another.
    func testKeysAreDistinct() {
        let raw = CinemaStore.Key.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raw).count, raw.count)
    }
}
