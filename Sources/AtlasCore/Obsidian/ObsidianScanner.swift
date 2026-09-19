import Foundation

public final class ObsidianScanner {
    public static let shared = ObsidianScanner()

    private let obsidianConfigPath = NSString(string: "~/Library/Application Support/obsidian/obsidian.json").expandingTildeInPath

    public init() {}

    public func discoverVaults() -> [AtlasVault] {
        var vaults: [AtlasVault] = []

        guard FileManager.default.fileExists(atPath: obsidianConfigPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: obsidianConfigPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaultsDict = json["vaults"] as? [String: [String: Any]] else {
            return vaults
        }

        for (vaultId, info) in vaultsDict {
            if let path = info["path"] as? String {
                let url = URL(fileURLWithPath: path)
                let name = url.lastPathComponent
                let isOpen = info["open"] as? Bool ?? false
                let exists = FileManager.default.fileExists(atPath: path)

                if exists {
                    let noteCount = countMarkdownFiles(in: path)
                    let vault = AtlasVault(
                        id: vaultId,
                        name: name,
                        path: path,
                        noteCount: noteCount,
                        isDefault: isOpen,
                        lastIndexed: Date()
                    )
                    vaults.append(vault)
                }
            }
        }

        return vaults.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Globally fetches the genuinely newest Markdown notes across all registered vaults.
    /// Fast two-phase scan: reads file modification metadata first, sorts globally, then reads content for top items.
    public func fetchGloballyNewestNotes(vaults: [AtlasVault], limit: Int = 10) -> [AtlasNote] {
        struct FileEntry {
            let url: URL
            let vault: AtlasVault
            let modDate: Date
        }

        var entries: [FileEntry] = []

        for vault in vaults {
            let vaultURL = URL(fileURLWithPath: vault.path)
            guard let enumerator = FileManager.default.enumerator(
                at: vaultURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension.lowercased() == "md" {
                    let pathComponents = fileURL.pathComponents
                    // Skip hidden or config folders (e.g. .obsidian, .trash)
                    if pathComponents.contains(where: { $0.hasPrefix(".") }) {
                        continue
                    }
                    let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                    entries.append(FileEntry(url: fileURL, vault: vault, modDate: modDate))
                }
            }
        }

        // Sort globally by real modification date descending
        let sortedEntries = entries.sorted { $0.modDate > $1.modDate }.prefix(limit)

        var resultNotes: [AtlasNote] = []
        for entry in sortedEntries {
            let relativePath = entry.url.path.replacingOccurrences(of: entry.vault.path + "/", with: "")
            let fileName = entry.url.deletingPathExtension().lastPathComponent
            let content = (try? String(contentsOf: entry.url, encoding: .utf8)) ?? ""
            let snippet = String(content.prefix(150)).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")

            let note = AtlasNote(
                title: fileName,
                path: entry.url.path,
                vaultName: entry.vault.name,
                relativePath: relativePath,
                tags: extractTags(from: content),
                snippet: snippet,
                backlinksCount: 0,
                modifiedDate: entry.modDate
            )
            resultNotes.append(note)
        }

        return resultNotes
    }

    public func searchNotes(query: String, in vaults: [AtlasVault], limit: Int = 50) -> [AtlasNote] {
        var results: [AtlasNote] = []
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        for vault in vaults {
            let vaultURL = URL(fileURLWithPath: vault.path)
            guard let enumerator = FileManager.default.enumerator(
                at: vaultURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension.lowercased() == "md" {
                    let relativePath = fileURL.path.replacingOccurrences(of: vault.path + "/", with: "")
                    let fileName = fileURL.deletingPathExtension().lastPathComponent

                    if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                        let titleMatches = cleanQuery.isEmpty || fileName.lowercased().contains(cleanQuery)
                        let contentMatches = cleanQuery.isEmpty || content.lowercased().contains(cleanQuery)

                        if titleMatches || contentMatches {
                            let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()

                            let snippet: String
                            if cleanQuery.isEmpty {
                                snippet = String(content.prefix(150)).trimmingCharacters(in: .whitespacesAndNewlines)
                            } else if let range = content.range(of: cleanQuery, options: .caseInsensitive) {
                                let start = content.index(range.lowerBound, offsetBy: -40, limitedBy: content.startIndex) ?? content.startIndex
                                let end = content.index(range.upperBound, offsetBy: 100, limitedBy: content.endIndex) ?? content.endIndex
                                snippet = "…" + content[start..<end].replacingOccurrences(of: "\n", with: " ") + "…"
                            } else {
                                snippet = String(content.prefix(150)).replacingOccurrences(of: "\n", with: " ")
                            }

                            let note = AtlasNote(
                                title: fileName,
                                path: fileURL.path,
                                vaultName: vault.name,
                                relativePath: relativePath,
                                tags: extractTags(from: content),
                                snippet: snippet,
                                backlinksCount: countBacklinks(for: fileName, in: vault.path),
                                modifiedDate: modDate
                            )
                            results.append(note)

                            if results.count >= limit {
                                return results
                            }
                        }
                    }
                }
            }
        }

        return results
    }

    private func countMarkdownFiles(in path: String) -> Int {
        let vaultURL = URL(fileURLWithPath: path)
        var count = 0
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "md" {
                count += 1
            }
        }
        return count
    }

    private func extractTags(from content: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: "#([a-zA-Z0-9_-]+)", options: [])
        let nsString = content as NSString
        let matches = regex?.matches(in: content, options: [], range: NSRange(location: 0, length: nsString.length)) ?? []
        return matches.compactMap { match -> String? in
            if match.numberOfRanges > 1 {
                return nsString.substring(with: match.range(at: 1))
            }
            return nil
        }
    }

    private func countBacklinks(for noteTitle: String, in vaultPath: String) -> Int {
        let wikiLink = "[[" + noteTitle + "]]"
        let vaultURL = URL(fileURLWithPath: vaultPath)
        var count = 0
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "md",
               let content = try? String(contentsOf: fileURL, encoding: .utf8),
               content.contains(wikiLink) {
                count += 1
            }
        }
        return count
    }
}
