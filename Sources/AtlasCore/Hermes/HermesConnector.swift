import Foundation
import Combine

public final class HermesRequestHandle {
    private var process: Process?
    private var isCancelledFlag = false
    private let lock = NSLock()

    public init() {}

    internal func attachProcess(_ p: Process) {
        lock.lock()
        self.process = p
        let shouldCancel = isCancelledFlag
        lock.unlock()

        if shouldCancel && p.isRunning {
            let pid = p.processIdentifier
            kill(-pid, SIGKILL)
            p.terminate()
        }
    }

    public func cancel() {
        lock.lock()
        isCancelledFlag = true
        let p = process
        lock.unlock()

        if let p = p, p.isRunning {
            let pid = p.processIdentifier
            kill(-pid, SIGKILL)
            p.terminate()
        }
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelledFlag
    }
}

public final class HermesConnector: ObservableObject {
    public static let shared = HermesConnector()

    @Published public private(set) var authState: HermesAuthState = .unknown
    public private(set) var lastExecutedPrompt: String?
    public private(set) var lastExecutedArguments: [String]?
    public private(set) var lastIncludedContextFiles: [String] = []

    /// Where the `hermes` executable lives. Set in Settings; blank falls back
    /// to whatever `hermes` resolves to on `PATH`.
    private var hermesBinaryPath: String {
        let configured = WorkspaceSettings.hermesBinaryPath
        guard configured.isEmpty else { return configured }
        return "/usr/local/bin/hermes"
    }

    /// Health endpoint of a self-hosted gateway. Blank disables the integration
    /// rather than pointing every install at one person's server.
    private var railwayURL: String {
        let base = WorkspaceSettings.hermesGatewayURL
        guard !base.isEmpty else { return "" }
        return base.hasSuffix("/") ? base + "health" : base + "/health"
    }
    private let hermesProfileDir = NSString(string: "~/.hermes/profiles/sovereign").expandingTildeInPath

    public init() {}

    public func updateAuthState(_ newState: HermesAuthState) {
        self.authState = newState
    }

    public func checkServices() -> [ServiceConnectionStatus] {
        var statuses: [ServiceConnectionStatus] = []

        // 1. Local Mac Host Status
        statuses.append(ServiceConnectionStatus(
            id: "mac",
            name: "Local Mac Host",
            state: .authenticatedAndOperational,
            isOnline: true,
            detail: "Active (\(ProcessInfo.processInfo.operatingSystemVersionString))"
        ))

        // 2. Local Hermes Agent Status (Honest One-Shot CLI Inspection)
        let binaryExists = FileManager.default.fileExists(atPath: hermesBinaryPath)
        let configExists = FileManager.default.fileExists(atPath: (hermesProfileDir as NSString).appendingPathComponent("config.yaml"))

        let hermesState: ServiceHealthState
        let hermesDetail: String
        let hermesOnline: Bool

        if !binaryExists {
            updateAuthState(.notInstalled)
            hermesState = .notInstalled
            hermesDetail = "Binary missing at \(hermesBinaryPath)"
            hermesOnline = false
        } else if !configExists {
            updateAuthState(.notConfigured)
            hermesState = .installed
            hermesDetail = "Profile Sovereign missing config.yaml"
            hermesOnline = false
        } else {
            if authState == .unknown {
                let hasCreds = inspectHermesAuthList()
                if !hasCreds {
                    updateAuthState(.loginRequired)
                }
            }

            switch authState {
            case .authenticated:
                hermesState = .authenticatedAndOperational
                hermesDetail = "CLI Ready (Auth Verified)"
                hermesOnline = true
            case .loginRequired:
                hermesState = .configured
                hermesDetail = "Login Required (Run 'hermes auth add nous')"
                hermesOnline = false
            case .authenticationExpired:
                hermesState = .configured
                hermesDetail = "Authentication Expired (Session Revoked)"
                hermesOnline = false
            case .notInstalled:
                hermesState = .notInstalled
                hermesDetail = "Binary missing"
                hermesOnline = false
            case .notConfigured:
                hermesState = .installed
                hermesDetail = "Profile unconfigured"
                hermesOnline = false
            case .unknown, .checkFailed:
                hermesState = .configured
                hermesDetail = "Login Not Verified"
                hermesOnline = false
            }
        }

        statuses.append(ServiceConnectionStatus(
            id: "hermes",
            name: "Hermes Agent (Local)",
            state: hermesState,
            isOnline: hermesOnline,
            detail: hermesDetail
        ))

        // 3. Railway Cloud Infrastructure Status
        let railwayOnline = checkRailwayConnectivity()
        statuses.append(ServiceConnectionStatus(
            id: "railway",
            name: "Sovereign Cloud Engine",
            state: railwayOnline ? .cloudReachable : .configured,
            isOnline: railwayOnline,
            detail: railwayOnline ? "Online (Production Stack Operational)" : "Offline (Railway Stack Unreachable)"
        ))

        return statuses
    }

    private func inspectHermesAuthList() -> Bool {
        guard FileManager.default.fileExists(atPath: hermesBinaryPath) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hermesBinaryPath)
        process.arguments = ["auth", "list"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            // Drain before waiting, or a chatty child deadlocks the pair.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains("nous") || output.contains("logged in") || output.contains("active")
        } catch {
            return false
        }
    }

    private func checkRailwayConnectivity() -> Bool {
        // No gateway configured is not an outage — it is the default, and it
        // reports offline rather than reaching for someone else's server.
        let endpoint = railwayURL
        guard !endpoint.isEmpty, let url = URL(string: endpoint) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3.0

        let semaphore = DispatchSemaphore(value: 0)
        var isOnline = false

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let httpResp = response as? HTTPURLResponse, (200...399).contains(httpResp.statusCode) {
                isOnline = true
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 3.5)
        return isOnline
    }

    @discardableResult
    public func sendMessage(
        prompt: String,
        contextProjects: [AtlasProject] = [],
        contextVaults: [AtlasVault] = [],
        onToken: @escaping (String) -> Void,
        onCompletion: @escaping (ChatMessage) -> Void
    ) -> HermesRequestHandle {
        let handle = HermesRequestHandle()

        if EmergencyStopManager.shared.isEmergencyStopActive {
            let errorMsg = ChatMessage(
                role: .assistant,
                text: "❌ **Execution Blocked**: Emergency Stop is currently ACTIVE. All local agent operations are halted.",
                executionLocation: .local,
                isPendingApproval: false
            )
            onToken(errorMsg.text)
            onCompletion(errorMsg)
            return handle
        }

        let boundedResult = BoundedContextBuilder.shared.buildContext(
            selectedProjects: contextProjects,
            selectedVaults: contextVaults
        )
        self.lastIncludedContextFiles = boundedResult.includedFilePaths

        var fullPrompt = boundedResult.contextText
        if !fullPrompt.isEmpty {
            fullPrompt += "\n--- [USER MISSION PROMPT] ---\n"
        }
        fullPrompt += prompt

        self.lastExecutedPrompt = fullPrompt

        let riskTier = SecurityGovernance.shared.classifyAction(toolName: "HermesTask", payload: fullPrompt)

        if SecurityGovernance.shared.requiresApproval(tier: riskTier) {
            let structuredAction = AtlasStructuredAction(
                toolIdentifier: "hermes_task",
                targetPath: hermesBinaryPath,
                executablePath: hermesBinaryPath,
                arguments: ["-z", fullPrompt],
                riskTier: riskTier
            )

            let req = AtlasApprovalRequest(
                title: "Execute Hermes Mission",
                details: String(prompt.prefix(80)),
                riskTier: riskTier,
                requestedBy: "Hermes Assistant",
                actionPayload: fullPrompt,
                structuredAction: structuredAction
            )
            ActivityLedger.shared.requestApproval(req)

            let approvalMsg = ChatMessage(
                role: .assistant,
                text: "⚠️ **Approval Required**: Action classified as **\(riskTier.rawValue)**. Execution payload queued in Approval Center.",
                executionLocation: .local,
                isPendingApproval: true
            )
            onToken(approvalMsg.text)
            onCompletion(approvalMsg)
            return handle
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard !handle.isCancelled else { return }

            let args = ["-z", fullPrompt]
            self.lastExecutedArguments = args

            let process = Process()
            process.executableURL = URL(fileURLWithPath: self.hermesBinaryPath)
            process.arguments = args

            var env = ProcessInfo.processInfo.environment
            env["HERMES_PROFILE"] = "sovereign"
            process.environment = env

            handle.attachProcess(process)
            guard !handle.isCancelled else { return }

            ProcessRegistry.shared.register(process)
            defer { ProcessRegistry.shared.unregister(process) }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let startTime = Date()

            do {
                try process.run()
                process.waitUntilExit()

                guard !handle.isCancelled else { return }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let rawOutput = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let duration = Date().timeIntervalSince(startTime)
                let exitCode = process.terminationStatus

                let isMissingToken = rawOutput.contains("No access token found")
                let isRevokedToken = rawOutput.contains("revoked")
                let isAuthError = isMissingToken || isRevokedToken
                let isSuccess = exitCode == 0 && !isAuthError

                if isMissingToken {
                    self.updateAuthState(.loginRequired)
                } else if isRevokedToken {
                    self.updateAuthState(.authenticationExpired)
                } else if isSuccess {
                    self.updateAuthState(.authenticated)
                }

                let finalResponseText: String
                if isMissingToken {
                    finalResponseText = "🔑 **Hermes Authentication Required**: \(rawOutput)\n\n**Action Required**: Open Terminal and execute `hermes auth add nous` or `hermes setup` to log in."
                } else if isRevokedToken {
                    finalResponseText = "🔑 **Hermes Session Expired**: \(rawOutput)\n\n**Action Required**: Open Terminal and execute `hermes auth add nous` to refresh credentials."
                } else if rawOutput.isEmpty {
                    finalResponseText = exitCode == 0 ? "Mission completed with empty output." : "Hermes execution failed with exit code \(exitCode)."
                } else {
                    finalResponseText = rawOutput
                }

                onToken(finalResponseText)

                let finalMsg = ChatMessage(
                    role: .assistant,
                    text: finalResponseText,
                    touchedFiles: self.lastIncludedContextFiles,
                    executionLocation: .local,
                    isPendingApproval: false
                )

                ActivityLedger.shared.logActivity(AtlasActivity(
                    initiator: "Hermes Agent",
                    toolName: "hermes -z",
                    target: "Sovereign Assistant",
                    actionDescription: "Processed mission: '\(String(prompt.prefix(50)))'",
                    riskTier: riskTier,
                    result: isSuccess ? "SUCCESS (\(String(format: "%.2f", duration))s)" : "FAILED (exit \(exitCode))",
                    approvalStatus: "APPROVED"
                ))

                onCompletion(finalMsg)
            } catch {
                guard !handle.isCancelled else { return }

                let errorMsg = ChatMessage(
                    role: .assistant,
                    text: "❌ **Execution Error**: Failed to launch Hermes CLI at `\(self.hermesBinaryPath)`: \(error.localizedDescription)",
                    executionLocation: .local,
                    isPendingApproval: false
                )
                onToken(errorMsg.text)
                onCompletion(errorMsg)
            }
        }

        return handle
    }
}
