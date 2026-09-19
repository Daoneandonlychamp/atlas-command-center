import Foundation

public final class ProjectScanner {
    public static let shared = ProjectScanner()

    public struct CatalogEntry {
        public let name: String
        public let path: String
        public let overrideType: ProjectType?

        public init(name: String, path: String, overrideType: ProjectType? = nil) {
            self.name = name
            self.path = path
            self.overrideType = overrideType
        }
    }

    /// Projects pinned to the top of the list, ahead of whatever the scan finds.
    ///
    /// Empty by default: a catalog is one person's shortlist, so it is built by
    /// the person using it rather than shipped.
    public var firstClassCatalog: [CatalogEntry] { [] }

    /// Folders walked looking for git repositories. Set in Settings; empty
    /// until then, which leaves the Projects surface showing its empty state.
    private var searchPaths: [String] { WorkspaceSettings.projectSearchPaths }

    public init() {}

    /// One work item per project, so the whole scan costs the slowest repository
    /// rather than the sum of all of them.
    private struct Candidate {
        let path: String
        let displayName: String?
        let overrideType: ProjectType?
    }

    public func discoverProjects() -> [AtlasProject] {
        var candidates: [Candidate] = []
        var visitedPaths = Set<String>()

        // 1. Process First-Class Catalog
        for entry in firstClassCatalog {
            guard FileManager.default.fileExists(atPath: entry.path) else { continue }
            visitedPaths.insert(entry.path)
            candidates.append(Candidate(path: entry.path, displayName: entry.name, overrideType: entry.overrideType))
        }

        // 2. Discover Additional Projects
        for basePath in searchPaths {
            guard FileManager.default.fileExists(atPath: basePath) else { continue }

            if isProjectDirectory(path: basePath) {
                if !visitedPaths.contains(basePath) {
                    visitedPaths.insert(basePath)
                    candidates.append(Candidate(path: basePath, displayName: nil, overrideType: nil))
                }
            } else {
                guard let subdirs = try? FileManager.default.contentsOfDirectory(atPath: basePath) else { continue }
                for sub in subdirs {
                    if sub.hasPrefix(".") || sub == "node_modules" || sub == ".build" { continue }
                    let fullPath = (basePath as NSString).appendingPathComponent(sub)
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                        if isProjectDirectory(path: fullPath) && !visitedPaths.contains(fullPath) {
                            visitedPaths.insert(fullPath)
                            candidates.append(Candidate(path: fullPath, displayName: nil, overrideType: nil))
                        }
                    }
                }
            }
        }

        // Inspecting a project shells out to git several times. Done one after
        // another, a single repository with a very large working tree — a
        // monorepo whose node_modules are not ignored, say — holds up the whole
        // dashboard for minutes. These are independent, so run them together.
        var found = [AtlasProject?](repeating: nil, count: candidates.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let candidate = candidates[index]
            let project = self.inspectProject(
                path: candidate.path,
                displayName: candidate.displayName,
                overrideType: candidate.overrideType
            )
            lock.lock()
            found[index] = project
            lock.unlock()
        }

        return found.compactMap { $0 }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    public func isProjectDirectory(path: String) -> Bool {
        let fm = FileManager.default
        let gitPath = (path as NSString).appendingPathComponent(".git")
        let pkgPath = (path as NSString).appendingPathComponent("package.json")
        let swiftPkgPath = (path as NSString).appendingPathComponent("Package.swift")
        let pyPkgPath = (path as NSString).appendingPathComponent("pyproject.toml")

        let hasXcode = (try? fm.contentsOfDirectory(atPath: path))?.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) ?? false

        return fm.fileExists(atPath: gitPath) ||
               fm.fileExists(atPath: pkgPath) ||
               fm.fileExists(atPath: swiftPkgPath) ||
               fm.fileExists(atPath: pyPkgPath) ||
               hasXcode
    }

    public func resolveGitRoot(at path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let output = runProcess(cmd: "/usr/bin/git", args: ["rev-parse", "--show-toplevel"], cwd: path) else { return nil }
        let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    public func detectProjectType(path: String) -> ProjectType {
        let fm = FileManager.default
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()

        let hasSwift = fm.fileExists(atPath: (path as NSString).appendingPathComponent("Package.swift"))
        let hasNode = fm.fileExists(atPath: (path as NSString).appendingPathComponent("package.json"))
        let hasPy = fm.fileExists(atPath: (path as NSString).appendingPathComponent("pyproject.toml")) || fm.fileExists(atPath: (path as NSString).appendingPathComponent("requirements.txt"))
        let hasXcode = (try? fm.contentsOfDirectory(atPath: path))?.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) ?? false
        let isGit = resolveGitRoot(at: path) != nil

        if hasSwift { return .swiftPackage }
        if hasXcode { return .xcodeProject }
        if name.contains("site") || name.contains("website") { return .clientWebsite }
        if hasNode { return .nodeProject }
        if hasPy { return .pythonProject }
        if isGit { return .gitRepository }
        return .folder
    }

    public func inspectProject(path: String, displayName: String? = nil, overrideType: ProjectType? = nil) -> AtlasProject? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let name = displayName ?? URL(fileURLWithPath: path).lastPathComponent
        let type = overrideType ?? detectProjectType(path: path)
        let gitRoot = resolveGitRoot(at: path)
        let isGit = gitRoot != nil
        let isRepoRoot = isGit && (gitRoot == path)
        let isNested = isGit && !isRepoRoot

        var gitBranch = ""
        var gitStatus = "Git not initialized"
        var staged: [String] = []
        var modified: [String] = []
        var untracked: [String] = []
        var deleted: [String] = []
        var conflicted: [String] = []
        var commits: [String] = []

        if isGit {
            let branchRaw = runProcess(cmd: "/usr/bin/git", args: ["branch", "--show-current"], cwd: path)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            gitBranch = branchRaw.isEmpty ? "main" : branchRaw

            let porcelain = runProcess(cmd: "/usr/bin/git", args: ["status", "--porcelain"], cwd: path) ?? ""
            let lines = porcelain.components(separatedBy: .newlines).filter { !$0.isEmpty }

            for line in lines {
                guard line.count >= 3 else { continue }
                let col1 = line[line.startIndex]
                let col2 = line[line.index(line.startIndex, offsetBy: 1)]
                let filePath = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)

                let statusPair = "\(col1)\(col2)"

                if statusPair == "??" {
                    untracked.append(filePath)
                } else if ["UU", "AA", "DD", "AU", "UD", "UA", "DU"].contains(statusPair) {
                    conflicted.append(filePath)
                } else {
                    if ["M", "A", "D", "R", "C"].contains(col1) {
                        staged.append(filePath)
                    }
                    if col2 == "M" {
                        modified.append(filePath)
                    } else if col2 == "D" {
                        deleted.append(filePath)
                    }
                }
            }

            let totalChanges = staged.count + modified.count + untracked.count + deleted.count + conflicted.count
            gitStatus = totalChanges == 0 ? "Clean" : "\(totalChanges) change(s)"

            let logRaw = runProcess(cmd: "/usr/bin/git", args: ["log", "-n", "5", "--oneline"], cwd: path) ?? ""
            commits = logRaw.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }

        let scripts = extractPackageScripts(path: path)
        let deploymentTarget = detectDeploymentTarget(path: path)

        return AtlasProject(
            id: path,
            name: name,
            path: path,
            projectType: type,
            isGitRepository: isGit,
            gitRootPath: gitRoot,
            isRepositoryRoot: isRepoRoot,
            isNestedApplication: isNested,
            gitBranch: gitBranch,
            gitStatus: gitStatus,
            uncommittedChangesCount: staged.count + modified.count + untracked.count + deleted.count + conflicted.count,
            stagedFiles: staged,
            modifiedFiles: modified,
            untrackedFiles: untracked,
            deletedFiles: deleted,
            conflictedFiles: conflicted,
            recentCommits: commits,
            availableScripts: scripts,
            buildStatus: "Ready",
            deploymentStatus: deploymentTarget,
            isCloudConnected: deploymentTarget != "No deployment configuration detected",
            lastModified: Date()
        )
    }

    private func detectDeploymentTarget(path: String) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent("railway.json")) ||
           fm.fileExists(atPath: (path as NSString).appendingPathComponent("Procfile")) ||
           fm.fileExists(atPath: (path as NSString).appendingPathComponent(".railway")) {
            return "Railway configuration detected"
        }
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent("vercel.json")) ||
           fm.fileExists(atPath: (path as NSString).appendingPathComponent(".vercel/project.json")) {
            return "Vercel configuration detected"
        }
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent("fly.toml")) {
            return "Fly.io configuration detected"
        }
        return "No deployment configuration detected"
    }

    private func extractPackageScripts(path: String) -> [String] {
        let pkgPath = (path as NSString).appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: pkgPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: pkgPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scriptsDict = json["scripts"] as? [String: Any] else {
            return []
        }
        return Array(scriptsDict.keys.sorted())
    }

    /// Ceiling for any single git invocation during a scan.
    private let processTimeout: TimeInterval = 20

    private func runProcess(cmd: String, args: [String], cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cmd)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()

            // Give up on a command that will not finish. `git status` on a huge
            // working tree can run for minutes; the dashboard would rather show
            // a project with missing detail than block on one repository.
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + processTimeout, execute: deadline)

            // Drain the pipe before waiting. A child that writes more than the
            // pipe buffer (~64 KB) blocks until someone reads, so waiting first
            // deadlocks both processes.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()

            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
