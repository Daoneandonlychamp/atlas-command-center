import XCTest
@testable import AtlasCore

/// The canvas store's job is to edit real Obsidian files without damaging them.
/// Everything here exists because a strict parser would quietly delete data.
final class CanvasStoreTests: XCTestCase {
    private var directory: URL!
    private var store: CanvasStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AtlasCanvasTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = CanvasStore()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ json: String, name: String = "test") throws -> URL {
        let url = directory.appendingPathComponent("\(name).canvas")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testRoundTripKeepsKeysTheSpecDoesNotDefine() throws {
        // Real Obsidian canvases carry a top-level "metadata" object. A typed
        // round trip would drop it the first time ATLAS saved.
        let url = try write("""
        {"nodes":[{"id":"a1","type":"text","text":"hello","x":0,"y":0,"width":260,"height":120}],
         "edges":[],
         "metadata":{"frontmatter":{},"custom":"keep me"}}
        """)

        var document = try store.load(url)
        document.nodes = document.nodes.map { node in
            var moved = node
            moved["x"] = 500
            return moved
        }
        try store.save(document)

        let reloaded = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let metadata = reloaded?["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["custom"] as? String, "keep me",
                       "unknown top-level keys must survive an edit")
        XCTAssertEqual((reloaded?["nodes"] as? [[String: Any]])?.first?["x"] as? Int, 500)
    }

    func testUnknownNodeFieldsSurvive() throws {
        let url = try write("""
        {"nodes":[{"id":"a1","type":"text","text":"hi","x":0,"y":0,"width":100,"height":100,
                   "styleAttributes":{"shape":"diamond"}}],"edges":[]}
        """)
        let document = try store.load(url)
        try store.save(document)

        let reloaded = try store.load(url)
        let node = reloaded.nodes.first
        XCTAssertNotNil(node?["styleAttributes"], "per-node extras must survive too")
    }

    func testMergingReplacesOnlyNodesAndEdges() throws {
        let url = try write("""
        {"nodes":[{"id":"a1","type":"text","text":"old","x":0,"y":0,"width":10,"height":10}],
         "edges":[],"metadata":{"keep":"yes"}}
        """)
        let document = try store.load(url)
        let merged = document.merging(
            nodes: [["id": "b2", "type": "text", "text": "new", "x": 5, "y": 5, "width": 10, "height": 10]],
            edges: [["id": "e1", "fromNode": "b2", "toNode": "b2"]])

        XCTAssertEqual(merged.nodes.count, 1)
        XCTAssertEqual(merged.nodes.first?["id"] as? String, "b2")
        XCTAssertEqual(merged.edges.count, 1)
        XCTAssertEqual((merged.raw["metadata"] as? [String: Any])?["keep"] as? String, "yes")
    }

    func testMissingArraysBecomeEmptyRatherThanCrashing() throws {
        let url = try write("{}")
        let document = try store.load(url)
        XCTAssertTrue(document.nodes.isEmpty)
        XCTAssertTrue(document.edges.isEmpty)
    }

    func testNonCanvasFileIsRejected() throws {
        let url = try write("[1,2,3]")
        XCTAssertThrowsError(try store.load(url))
    }

    func testCreateRefusesToOverwrite() throws {
        let scoped = ScopedStore(folder: directory)
        _ = try scoped.create(named: "Ideas")
        XCTAssertThrowsError(try scoped.create(named: "Ideas"),
                             "creating over an existing canvas would destroy it")
    }

    func testCreateSanitisesTheName() throws {
        let scoped = ScopedStore(folder: directory)
        let document = try scoped.create(named: "Q3/Q4 plan")
        XCTAssertFalse(document.url.lastPathComponent.contains("/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.url.path))
    }

    func testListFindsCanvasesAndSortsNewestFirst() throws {
        _ = try write("{\"nodes\":[],\"edges\":[]}", name: "older")
        Thread.sleep(forTimeInterval: 0.05)
        _ = try write("{\"nodes\":[],\"edges\":[]}", name: "newer")

        let found = store.list(vaults: [directory])
        let names = found.map(\.name)
        XCTAssertTrue(names.contains("older") && names.contains("newer"))
        XCTAssertEqual(names.first, "newer", "most recently touched first")
    }
}

/// A store rooted at a temp folder, so create/delete tests never touch the vault.
private final class ScopedStore {
    private let root: URL
    init(folder: URL) { self.root = folder }

    func create(named name: String) throws -> CanvasDocument {
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { throw CanvasError.badName }
        let url = root.appendingPathComponent("\(safe).canvas")
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CanvasError.alreadyExists(safe)
        }
        let document = CanvasDocument(url: url, raw: ["nodes": [], "edges": []])
        try CanvasStore().save(document)
        return document
    }
}

/// Vault-relative path resolution for file nodes. JSON Canvas paths are relative
/// to the vault root, not to the canvas, which is easy to get wrong and shows up
/// as an empty card rather than an error.
final class CanvasPathTests: XCTestCase {
    private var vault: URL!

    override func setUpWithError() throws {
        vault = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AtlasVaultTest_\(UUID().uuidString)")
        // A vault is a folder with .obsidian in it.
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("Images"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("Maps"),
                                                withIntermediateDirectories: true)
        try Data("png".utf8).write(to: vault.appendingPathComponent("Images/art.png"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vault)
    }

    func testPathResolvesFromTheVaultRootNotTheCanvasFolder() throws {
        // The canvas is nested, but "Images/art.png" is relative to the vault.
        let canvas = vault.appendingPathComponent("Maps/plan.canvas")
        let resolved = CanvasWebViewPathResolver.resolve("Images/art.png", from: canvas)
        XCTAssertEqual(resolved?.lastPathComponent, "art.png")
    }

    func testMissingFileResolvesToNil() {
        let canvas = vault.appendingPathComponent("Maps/plan.canvas")
        XCTAssertNil(CanvasWebViewPathResolver.resolve("Images/gone.png", from: canvas))
    }

    func testCanvasOutsideAnyVaultFallsBackToItsOwnFolder() throws {
        let loose = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AtlasLoose_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: loose) }
        try Data("x".utf8).write(to: loose.appendingPathComponent("beside.png"))

        let canvas = loose.appendingPathComponent("stray.canvas")
        XCTAssertEqual(CanvasWebViewPathResolver.resolve("beside.png", from: canvas)?.lastPathComponent,
                       "beside.png")
    }
}
