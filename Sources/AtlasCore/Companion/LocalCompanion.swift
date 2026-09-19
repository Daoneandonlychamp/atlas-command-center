import Foundation
import AppKit

public struct StructuredToolDefinition: Identifiable, Codable {
    public let id: String
    public let name: String
    public let description: String
    public let riskTier: RiskTier
    public let isAllowlisted: Bool

    public init(id: String, name: String, description: String, riskTier: RiskTier, isAllowlisted: Bool = true) {
        self.id = id
        self.name = name
        self.description = description
        self.riskTier = riskTier
        self.isAllowlisted = isAllowlisted
    }
}

public final class AtlasCommandHandle {
    private let process: Process
    private var isCancelledFlag: Bool = false
    private let lock = NSLock()

    public init(process: Process) {
        self.process = process
    }

    public func cancel() {
        lock.lock()
        isCancelledFlag = true
        lock.unlock()

        if process.isRunning {
            let pid = process.processIdentifier
            kill(-pid, SIGKILL)
            process.terminate()
        }
    }

    public var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelledFlag
    }
}

public final class LocalCompanion {
    public static let shared = LocalCompanion()

    /// The folders the Companion may read from and run inside.
    ///
    /// Empty until the user names one in Settings, which means a fresh install
    /// can do nothing at all. That is deliberate for an allowlist guarding
    /// shell execution: an empty list fails closed, and every path in it is
    /// there because someone chose it.
    public var allowedScopes: [String] { WorkspaceSettings.companionScopes }

    public init() {}

    public func getRegisteredTools() -> [StructuredToolDefinition] {
        return [
            StructuredToolDefinition(
                id: "read_file",
                name: "Read Permitted File",
                description: "Reads content from a file inside permitted workspace scopes",
                riskTier: .readOnly
            ),
            StructuredToolDefinition(
                id: "search_folder",
                name: "Search Permitted Folders",
                description: "Searches files by query within permitted workspace scopes",
                riskTier: .readOnly
            ),
            StructuredToolDefinition(
                id: "inspect_git",
                name: "Inspect Git Status",
                description: "Inspects Git branch, uncommitted files, and commit log for a repository",
                riskTier: .readOnly
            ),
            StructuredToolDefinition(
                id: "open_target",
                name: "Open Project or Note",
                description: "Opens a project folder in Finder or an Obsidian note in Obsidian app",
                riskTier: .reversible
            ),
            StructuredToolDefinition(
                id: "run_command",
                name: "Run Allowlisted Command",
                description: "Executes an allowlisted, non-destructive project build or test command",
                riskTier: .reversible
            )
        ]
    }

    public func isPathPermitted(_ path: String) -> Bool {
        return PathValidator.shared.isPathPermitted(path, allowedScopes: allowedScopes)
    }

    public func readFile(path: String) -> Result<String, Error> {
        if EmergencyStopManager.shared.isEmergencyStopActive {
            return .failure(NSError(domain: "LocalCompanion", code: 403, userInfo: [NSLocalizedDescriptionKey: "Emergency Stop is active"]))
        }
        guard isPathPermitted(path) else {
            return .failure(NSError(domain: "LocalCompanion", code: 401, userInfo: [NSLocalizedDescriptionKey: "Path outside permitted scopes: \(path)"]))
        }

        let canonical = PathValidator.shared.resolveCanonicalPath(path)
        guard FileManager.default.fileExists(atPath: canonical) else {
            return .failure(NSError(domain: "LocalCompanion", code: 404, userInfo: [NSLocalizedDescriptionKey: "File does not exist at path: \(path)"]))
        }

        do {
            let content = try String(contentsOfFile: canonical, encoding: .utf8)
            ActivityLedger.shared.logActivity(AtlasActivity(
                initiator: "User / LocalCompanion",
                toolName: "read_file",
                target: path,
                actionDescription: "Read file (\(content.count) bytes)",
                riskTier: .readOnly,
                result: "Success"
            ))
            return .success(content)
        } catch {
            return .failure(error)
        }
    }

    public func searchFolder(folderPath: String, query: String) -> [String] {
        guard isPathPermitted(folderPath), !EmergencyStopManager.shared.isEmergencyStopActive else { return [] }
        let canonical = PathValidator.shared.resolveCanonicalPath(folderPath)
        let url = URL(fileURLWithPath: canonical)
        var matches: [String] = []
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.lowercased().contains(query.lowercased()) {
                matches.append(fileURL.path)
                if matches.count >= 50 { break }
            }
        }

        ActivityLedger.shared.logActivity(AtlasActivity(
            initiator: "User / LocalCompanion",
            toolName: "search_folder",
            target: folderPath,
            actionDescription: "Found \(matches.count) matches for query '\(query)'",
            riskTier: .readOnly,
            result: "Success"
        ))

        return matches
    }

    public func inspectGitStatus(repositoryPath: String) -> String {
        guard isPathPermitted(repositoryPath), !EmergencyStopManager.shared.isEmergencyStopActive else {
            return "Error: Path not permitted or Emergency Stop active"
        }
        let canonical = PathValidator.shared.resolveCanonicalPath(repositoryPath)
        let branch = runProcess(cmd: "/usr/bin/git", args: ["branch", "--show-current"], cwd: canonical) ?? "unknown"
        let status = runProcess(cmd: "/usr/bin/git", args: ["status", "--porcelain"], cwd: canonical) ?? ""
        let log = runProcess(cmd: "/usr/bin/git", args: ["log", "-n", "3", "--oneline"], cwd: canonical) ?? ""

        let output = """
        Branch: \(branch.trimmingCharacters(in: .whitespacesAndNewlines))
        Uncommitted files:
        \(status.isEmpty ? "Clean working tree" : status)
        Recent commits:
        \(log)
        """

        ActivityLedger.shared.logActivity(AtlasActivity(
            initiator: "User / LocalCompanion",
            toolName: "inspect_git",
            target: repositoryPath,
            actionDescription: "Inspected Git repository status",
            riskTier: .readOnly,
            result: "Success"
        ))

        return output
    }

    public func openTarget(pathOrURI: String) -> Bool {
        guard !EmergencyStopManager.shared.isEmergencyStopActive else { return false }
        if pathOrURI.hasPrefix("obsidian://") {
            guard PathValidator.shared.validateObsidianURI(pathOrURI) else { return false }
            if let url = URL(string: pathOrURI) {
                return NSWorkspace.shared.open(url)
            }
            return false
        } else {
            guard isPathPermitted(pathOrURI) else { return false }
            let canonical = PathValidator.shared.resolveCanonicalPath(pathOrURI)
            return NSWorkspace.shared.selectFile(canonical, inFileViewerRootedAtPath: canonical)
        }
    }

    public func executeCommand(
        command: String,
        projectPath: String,
        onHandleAssigned: ((AtlasCommandHandle) -> Void)? = nil
    ) -> AtlasCommandResult {
        let startTime = Date()

        if EmergencyStopManager.shared.isEmergencyStopActive {
            return AtlasCommandResult(
                stdout: "",
                stderr: "Emergency Stop is active.",
                exitCode: 403,
                duration: 0.0,
                isCancelled: false,
                launchError: "Emergency Stop active"
            )
        }

        guard isPathPermitted(projectPath) else {
            return AtlasCommandResult(
                stdout: "",
                stderr: "Path outside permitted scopes: \(projectPath)",
                exitCode: 401,
                duration: 0.0,
                isCancelled: false,
                launchError: "Path not permitted"
            )
        }

        let cleanCmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleanCmd.components(separatedBy: " ")
        guard let binary = parts.first else {
            return AtlasCommandResult(
                stdout: "",
                stderr: "Invalid command format.",
                exitCode: 400,
                duration: 0.0,
                isCancelled: false,
                launchError: "Invalid command format"
            )
        }
        let args = Array(parts.dropFirst())

        let binPath: String
        if binary == "swift" { binPath = "/usr/bin/swift" }
        else if binary == "git" { binPath = "/usr/bin/git" }
        else if binary == "npm" { binPath = "/usr/local/bin/npm" }
        else { binPath = "/usr/bin/\(binary)" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: PathValidator.shared.resolveCanonicalPath(projectPath))

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let handle = AtlasCommandHandle(process: process)
        onHandleAssigned?(handle)

        ProcessRegistry.shared.register(process)
        defer { ProcessRegistry.shared.unregister(process) }

        do {
            try process.run()
            process.waitUntilExit()

            let duration = Date().timeIntervalSince(startTime)
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            let stdoutStr = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if handle.wasCancelled {
                return AtlasCommandResult(
                    stdout: stdoutStr,
                    stderr: "Execution Cancelled by User.",
                    exitCode: -1,
                    duration: duration,
                    isCancelled: true,
                    launchError: nil
                )
            }

            return AtlasCommandResult(
                stdout: stdoutStr,
                stderr: stderrStr,
                exitCode: process.terminationStatus,
                duration: duration,
                isCancelled: false,
                launchError: nil
            )
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            return AtlasCommandResult(
                stdout: "",
                stderr: error.localizedDescription,
                exitCode: 1,
                duration: duration,
                isCancelled: handle.wasCancelled,
                launchError: error.localizedDescription
            )
        }
    }

    public func runAllowlistedCommand(command: String, projectPath: String) -> Result<String, Error> {
        let result = executeCommand(command: command, projectPath: projectPath)
        if result.isSuccess {
            return .success(result.stdout.isEmpty ? result.stderr : result.stdout)
        } else {
            return .failure(NSError(domain: "LocalCompanion", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: result.stderr.isEmpty ? "Exit code \(result.exitCode)" : result.stderr]))
        }
    }

    private func runProcess(cmd: String, args: [String], cwd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)

        ProcessRegistry.shared.register(p)
        defer { ProcessRegistry.shared.unregister(p) }

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            // Drain before waiting, or a command with large output deadlocks.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
