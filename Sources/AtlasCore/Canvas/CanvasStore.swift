import Foundation

/// Reads and writes JSON Canvas files — the same `.canvas` format Obsidian
/// Canvas uses, so a canvas made here opens there and vice versa.
///
/// The documents are held as raw dictionaries rather than parsed into strict
/// structs, on purpose. Obsidian writes keys the 1.0 spec does not define — a
/// top-level `metadata` object, for one — and a typed round trip would silently
/// delete them the first time ATLAS saved. Anything unrecognised is carried
/// through untouched; only the fields ATLAS actually edits are rewritten.
public final class CanvasStore {
    public static let shared = CanvasStore()

    private let fileManager = FileManager.default

    public init() {}

    /// Where ATLAS puts canvases it makes. Existing ones anywhere in the vaults
    /// are still listed and opened — this is just the default home.
    public var folder: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Obsidian/MYTHOS Context/Canvases", isDirectory: true)
    }

    // MARK: - Listing

    /// Every `.canvas` file across the registered vaults, ATLAS's own folder first.
    public func list(vaults: [URL] = []) -> [CanvasFile] {
        var roots = [folder]
        roots.append(contentsOf: vaults)
        if roots.count == 1 {
            // No vault registry handed in — sweep the Obsidian directory itself.
            roots.append(fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Obsidian", isDirectory: true))
        }

        var seen = Set<String>()
        var found: [CanvasFile] = []
        for root in roots {
            guard let walker = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "canvas" {
                guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                found.append(CanvasFile(url: url,
                                        name: url.deletingPathExtension().lastPathComponent,
                                        isAtlasFolder: url.path.hasPrefix(folder.path),
                                        modifiedAt: modified))
            }
        }
        return found.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - Reading and writing

    public func load(_ url: URL) throws -> CanvasDocument {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CanvasError.notACanvas
        }
        return CanvasDocument(url: url, raw: object)
    }

    @discardableResult
    public func save(_ document: CanvasDocument) throws -> URL {
        try fileManager.createDirectory(at: document.url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        // Sorted keys so a canvas that did not really change produces an
        // identical file, which keeps git history and Obsidian sync quiet.
        let data = try JSONSerialization.data(withJSONObject: document.raw,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: document.url, options: .atomic)
        return document.url
    }

    /// Creates an empty canvas, refusing to overwrite one that already exists.
    public func create(named name: String) throws -> CanvasDocument {
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { throw CanvasError.badName }
        let url = folder.appendingPathComponent("\(safe).canvas")
        guard !fileManager.fileExists(atPath: url.path) else { throw CanvasError.alreadyExists(safe) }
        let document = CanvasDocument(url: url, raw: ["nodes": [], "edges": []])
        try save(document)
        return document
    }

    public func delete(_ url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}

public struct CanvasFile: Identifiable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    /// True for canvases in ATLAS's own folder, so the list can group them.
    public let isAtlasFolder: Bool
    public let modifiedAt: Date
}

/// A canvas document, kept as the raw JSON so unknown keys survive editing.
public struct CanvasDocument {
    public var url: URL
    public var raw: [String: Any]

    public init(url: URL, raw: [String: Any]) {
        self.url = url
        self.raw = raw
        if self.raw["nodes"] == nil { self.raw["nodes"] = [] }
        if self.raw["edges"] == nil { self.raw["edges"] = [] }
    }

    public var nodes: [[String: Any]] {
        get { raw["nodes"] as? [[String: Any]] ?? [] }
        set { raw["nodes"] = newValue }
    }

    public var edges: [[String: Any]] {
        get { raw["edges"] as? [[String: Any]] ?? [] }
        set { raw["edges"] = newValue }
    }

    public var name: String { url.deletingPathExtension().lastPathComponent }

    /// JSON text for handing to the page.
    public func json() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { throw CanvasError.notACanvas }
        return text
    }

    /// Rebuilds a document from what the page sends back.
    ///
    /// Only `nodes` and `edges` are taken from the page; every other top-level
    /// key keeps the value it had on disk, so Obsidian's `metadata` and anything
    /// a future version adds survives a round trip through ATLAS.
    public func merging(nodes: [[String: Any]], edges: [[String: Any]]) -> CanvasDocument {
        var updated = self
        updated.nodes = nodes
        updated.edges = edges
        return updated
    }
}

public enum CanvasError: LocalizedError {
    case notACanvas
    case badName
    case alreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .notACanvas: return "That file is not a canvas."
        case .badName: return "Give the canvas a name."
        case .alreadyExists(let name): return "“\(name)” already exists."
        }
    }
}


/// Resolves a JSON Canvas file-node path.
///
/// These are relative to the *vault root*, not to the canvas, so this walks up
/// looking for the folder holding `.obsidian`. Getting it wrong shows up as an
/// empty card rather than an error, which is why it is tested rather than
/// trusted. In AtlasCore so the tests can reach it.
public enum CanvasWebViewPathResolver {
    public static func resolve(_ file: String, from canvas: URL) -> URL? {
        let manager = FileManager.default
        var directory = canvas.deletingLastPathComponent()
        for _ in 0..<12 {
            if manager.fileExists(atPath: directory.appendingPathComponent(".obsidian").path) {
                let candidate = directory.appendingPathComponent(file)
                return manager.fileExists(atPath: candidate.path) ? candidate : nil
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        // A canvas kept outside any vault still resolves files beside it.
        let fallback = canvas.deletingLastPathComponent().appendingPathComponent(file)
        return manager.fileExists(atPath: fallback.path) ? fallback : nil
    }
}
