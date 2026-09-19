import Foundation

public final class EmergencyStopManager: ObservableObject {
    public static let shared = EmergencyStopManager()

    @Published public private(set) var isEmergencyStopActive: Bool = false

    private let queue = DispatchQueue(label: "com.atlas.emergencystop")

    public init() {}

    public func triggerEmergencyStop() {
        queue.sync {
            self.isEmergencyStopActive = true
        }

        // Immediately terminate all active processes in ProcessRegistry
        let terminatedCount = ProcessRegistry.shared.terminateAll()

        // Record event in Activity Ledger
        ActivityLedger.shared.logActivity(AtlasActivity(
            initiator: "User / Emergency Stop",
            toolName: "EmergencyStopManager",
            target: "Local Computer Control",
            actionDescription: "EMERGENCY STOP TRIGGERED — Halted \(terminatedCount) active sub-processes.",
            riskTier: .destructive,
            result: "HALTED (\(terminatedCount) processes terminated)",
            approvalStatus: "EMERGENCY_STOP"
        ))
    }

    public func resetEmergencyStop() {
        queue.sync {
            self.isEmergencyStopActive = false
        }

        ActivityLedger.shared.logActivity(AtlasActivity(
            initiator: "User",
            toolName: "EmergencyStopManager",
            target: "Local Computer Control",
            actionDescription: "Emergency Stop reset — Normal operation restored.",
            riskTier: .reversible,
            result: "RESTORED",
            approvalStatus: "RESTORED"
        ))
    }
}
