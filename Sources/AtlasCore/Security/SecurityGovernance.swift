import Foundation

public final class SecurityGovernance {
    public static let shared = SecurityGovernance()

    public init() {}

    public func classifyAction(toolName: String, payload: String) -> RiskTier {
        let tool = toolName.lowercased()
        let body = payload.lowercased()

        if tool.contains("delete") || tool.contains("rm ") || tool.contains("deploy") ||
           body.contains("rm -rf") || body.contains("stripe") || body.contains("payment") || body.contains("drop ") {
            return .destructive
        }

        if tool.contains("post") || tool.contains("send") || tool.contains("publish") ||
           tool.contains("discord") || tool.contains("push") || body.contains("git push") {
            return .external
        }

        if tool.contains("write") || tool.contains("edit") || tool.contains("commit") ||
           tool.contains("move") || tool.contains("create") {
            return .reversible
        }

        return .readOnly
    }

    public func requiresApproval(tier: RiskTier) -> Bool {
        switch tier {
        case .readOnly, .reversible:
            return false
        case .external, .destructive:
            return true
        }
    }
}
