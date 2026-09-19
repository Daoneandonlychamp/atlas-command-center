import Foundation

public struct BoundedContextResult {
    public let contextText: String
    public let includedFilePaths: [String]
    public let totalByteSize: Int

    public init(contextText: String, includedFilePaths: [String], totalByteSize: Int) {
        self.contextText = contextText
        self.includedFilePaths = includedFilePaths
        self.totalByteSize = totalByteSize
    }
}

public final class BoundedContextBuilder {
    public static let shared = BoundedContextBuilder()

    private let maxFileBytes = 8192 // 8 KB per file
    private let maxTotalBytes = 32768 // 32 KB max total context

    private let excludedPatterns = [
        ".env", "auth.json", "credentials", "secret", "private_key",
        ".git", "node_modules", ".build", "dist", ".swiftpm",
        ".db", ".db-shm", ".db-wal", ".keychain"
    ]

    public init() {}

    public func buildContext(selectedProjects: [AtlasProject], selectedVaults: [AtlasVault]) -> BoundedContextResult {
        var includedFiles: [String] = []
        var totalBytes = 0
        var contextText = ""

        // 1. Projects Bounded Context
        for project in selectedProjects {
            if totalBytes >= maxTotalBytes { break }
            let projURL = URL(fileURLWithPath: project.path)

            let targets = ["README.md", "Package.swift", "package.json"]
            for targetName in targets {
                let fileURL = projURL.appendingPathComponent(targetName)
                if FileManager.default.fileExists(atPath: fileURL.path) && isSafeFile(path: fileURL.path) {
                    if let content = readFileBounded(fileURL: fileURL, maxBytes: maxFileBytes) {
                        let header = "\n--- [PROJECT FILE: \(project.name)/\(targetName)] ---\n"
                        let chunk = header + content + "\n"
                        let chunkBytes = chunk.utf8.count

                        if totalBytes + chunkBytes <= maxTotalBytes {
                            contextText += chunk
                            includedFiles.append(fileURL.path)
                            totalBytes += chunkBytes
                        }
                    }
                }
            }
        }

        // 2. Vaults Bounded Context (top 3 notes per vault)
        for vault in selectedVaults {
            if totalBytes >= maxTotalBytes { break }
            let vaultURL = URL(fileURLWithPath: vault.path)

            guard let enumerator = FileManager.default.enumerator(
                at: vaultURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            var vaultCount = 0
            for case let fileURL as URL in enumerator {
                if vaultCount >= 3 || totalBytes >= maxTotalBytes { break }

                if fileURL.pathExtension.lowercased() == "md" && isSafeFile(path: fileURL.path) {
                    if let content = readFileBounded(fileURL: fileURL, maxBytes: maxFileBytes) {
                        let relPath = fileURL.path.replacingOccurrences(of: vault.path + "/", with: "")
                        let header = "\n--- [VAULT NOTE: \(vault.name)/\(relPath)] ---\n"
                        let chunk = header + content + "\n"
                        let chunkBytes = chunk.utf8.count

                        if totalBytes + chunkBytes <= maxTotalBytes {
                            contextText += chunk
                            includedFiles.append(fileURL.path)
                            totalBytes += chunkBytes
                            vaultCount += 1
                        }
                    }
                }
            }
        }

        return BoundedContextResult(
            contextText: contextText,
            includedFilePaths: includedFiles,
            totalByteSize: totalBytes
        )
    }

    public func isSafeFile(path: String) -> Bool {
        let lower = path.lowercased()
        for pattern in excludedPatterns {
            if lower.contains(pattern) {
                return false
            }
        }
        return true
    }

    private func readFileBounded(fileURL: URL, maxBytes: Int) -> String? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        let truncatedData = data.prefix(maxBytes)
        return String(data: truncatedData, encoding: .utf8)
    }
}
