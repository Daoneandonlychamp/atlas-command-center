import Foundation

public final class ActivityLedger {
    public static let shared = ActivityLedger()

    private let storageURL: URL
    private var activities: [AtlasActivity] = []
    private var approvalRequests: [AtlasApprovalRequest] = []
    private let queue = DispatchQueue(label: "com.atlas.ledger", attributes: .concurrent)

    public init() {
        let hermesDir = NSString(string: "~/.hermes/profiles/sovereign").expandingTildeInPath
        let dirURL = URL(fileURLWithPath: hermesDir)
        if !FileManager.default.fileExists(atPath: hermesDir) {
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }
        self.storageURL = dirURL.appendingPathComponent("atlas_ledger.json")
        loadLedger()
    }

    public func logActivity(_ activity: AtlasActivity) {
        queue.async(flags: .barrier) {
            self.activities.insert(activity, at: 0)
            self.saveLedger()
        }
    }

    public func requestApproval(_ request: AtlasApprovalRequest) {
        queue.async(flags: .barrier) {
            self.approvalRequests.insert(request, at: 0)
            self.saveLedger()
        }
    }

    public func executeApproval(id: String) -> Bool {
        if EmergencyStopManager.shared.isEmergencyStopActive {
            logActivity(AtlasActivity(
                initiator: "User / ApprovalCenter",
                toolName: "ApprovalExecutor",
                target: id,
                actionDescription: "Approval execution blocked: Emergency Stop is active",
                riskTier: .destructive,
                result: "BLOCKED",
                approvalStatus: "EMERGENCY_STOP"
            ))
            return false
        }

        return queue.sync(flags: .barrier) {
            guard let idx = self.approvalRequests.firstIndex(where: { $0.id == id }) else { return false }
            var req = self.approvalRequests[idx]

            // Ensure exact once execution
            guard req.executionCount == 0, req.status == .pending || req.status == .approved else {
                return false
            }

            req.status = .approved
            req.executionCount += 1
            req.executedAt = Date()

            var success = true
            var output = "Action approved and executed."

            if let action = req.structuredAction {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: action.executablePath)
                process.arguments = action.arguments
                if let workDir = action.workingDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: workDir)
                }

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                ProcessRegistry.shared.register(process)
                defer { ProcessRegistry.shared.unregister(process) }

                do {
                    try process.run()
                    // Drain the pipe before waiting. A child that writes more than
                    // the pipe buffer (~64 KB) blocks until someone reads, so
                    // waiting first deadlocks both processes.
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    output = String(data: data, encoding: .utf8) ?? "Execution completed"
                    success = process.terminationStatus == 0
                } catch {
                    output = "Execution error: \(error.localizedDescription)"
                    success = false
                }
            }

            req.status = success ? .executed : .failed
            req.executionOutput = output
            self.approvalRequests[idx] = req

            self.activities.insert(AtlasActivity(
                initiator: req.requestedBy,
                toolName: req.title,
                target: req.details,
                actionDescription: "Approval executed directly via process binary (Count: 1). Result: \(success ? "Success" : "Failed")",
                riskTier: req.riskTier,
                result: success ? "Success" : "Failed",
                durationSeconds: 0.1,
                approvalStatus: req.status.rawValue
            ), at: 0)

            self.saveLedger()
            return success
        }
    }

    public func rejectApproval(id: String) {
        queue.async(flags: .barrier) {
            guard let idx = self.approvalRequests.firstIndex(where: { $0.id == id }) else { return }
            var req = self.approvalRequests[idx]

            guard req.executionCount == 0 else { return }

            req.status = .rejected
            self.approvalRequests[idx] = req

            self.activities.insert(AtlasActivity(
                initiator: req.requestedBy,
                toolName: req.title,
                target: req.details,
                actionDescription: "Approval rejected by user. Action was NOT executed.",
                riskTier: req.riskTier,
                result: "Rejected",
                durationSeconds: 0.1,
                approvalStatus: "Rejected"
            ), at: 0)

            self.saveLedger()
        }
    }

    public func fetchActivities(limit: Int = 100) -> [AtlasActivity] {
        return queue.sync {
            Array(activities.prefix(limit))
        }
    }

    public func fetchPendingApprovals() -> [AtlasApprovalRequest] {
        return queue.sync {
            approvalRequests.filter { $0.status == .pending }
        }
    }

    public func fetchAllApprovals() -> [AtlasApprovalRequest] {
        return queue.sync {
            approvalRequests
        }
    }

    private func saveLedger() {
        let wrapper = LedgerDataWrapper(activities: activities, approvalRequests: approvalRequests)
        if let data = try? JSONEncoder().encode(wrapper) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    private func loadLedger() {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let wrapper = try? JSONDecoder().decode(LedgerDataWrapper.self, from: data) else {
            self.activities = []
            self.approvalRequests = []
            saveLedger()
            return
        }

        self.activities = wrapper.activities
        self.approvalRequests = wrapper.approvalRequests
    }
}

private struct LedgerDataWrapper: Codable {
    let activities: [AtlasActivity]
    let approvalRequests: [AtlasApprovalRequest]
}
