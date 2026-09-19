import Foundation

/// Reads the Hermes Sovereign credential broker and owns the lifecycle of the
/// localhost Connection Center.
///
/// Why this lives in ATLAS: the Connection Center is a `tsx` script that has
/// only ever been run by hand from a terminal, so it dies with whatever shell
/// started it — and it is the only place OAuth identities can be reconnected.
/// ATLAS is the desktop home for this system, so it should be the thing that
/// keeps it alive and shows what is connected.
///
/// Read-only with respect to the broker: ATLAS never writes tokens. Starting
/// the server is a Reversible Local Action under the ATLAS authority model.
public struct BrokerIdentity: Identifiable, Codable, Hashable {
    public let identityId: String
    public let provider: String
    public let lifecycleState: String
    public let handle: String?
    public let providerUserId: String?

    public var id: String { identityId }

    enum CodingKeys: String, CodingKey {
        case identityId = "identity_id"
        case provider
        case lifecycleState = "lifecycle_state"
        case handle
        case providerUserId = "platform_user_id"
    }

    /// Display family so the UI can group the way the web Connection Center does.
    public var family: String {
        switch provider {
        case "gmail", "google_calendar", "google_drive", "google_contacts", "google_tasks":
            return "Google Workspace"
        case "x", "threads", "instagram", "tiktok": return "Social"
        case "github": return "Engineering"
        case "stripe", "plaid": return "Commerce"
        case "discord": return "Platform"
        default: return "Other"
        }
    }

    public var isHealthy: Bool { lifecycleState == "ACTIVE" || lifecycleState == "CANARY_VERIFIED" }

    /// Providers with no real OAuth flow in the Connection Center yet.
    public var isWired: Bool { !["github", "stripe", "plaid"].contains(provider) }
}

public final class ConnectionCenterService: ObservableObject {
    public static let port = 8899
    public static let url = URL(string: "http://localhost:8899")!

    @Published public private(set) var identities: [BrokerIdentity] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var lastError: String?

    private let stateFile: URL
    private let webAppDir: URL

    public init(
        stateFile: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes/profiles/sovereign/connections/integrations_state.json"),
        webAppDir: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/Developer/MYTHOS CODE STRUCTURE/mythos-webapp")
    ) {
        self.stateFile = stateFile
        self.webAppDir = webAppDir
    }

    public var healthyCount: Int { identities.filter(\.isHealthy).count }

    public func refresh() {
        loadIdentities()
        checkRunning()
    }

    private func loadIdentities() {
        do {
            let data = try Data(contentsOf: stateFile)
            identities = try JSONDecoder().decode([BrokerIdentity].self, from: data)
                .sorted { ($0.family, $0.identityId) < ($1.family, $1.identityId) }
            lastError = nil
        } catch {
            identities = []
            lastError = "Could not read the credential broker: \(error.localizedDescription)"
        }
    }

    /// A listening socket is the only honest signal that the server is up.
    private func checkRunning() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(Self.port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            // Drain before waiting, or a large listing deadlocks the pair.
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            task.waitUntilExit()
            isRunning = out.contains("LISTEN")
        } catch {
            isRunning = false
        }
    }

    /// Start the Connection Center detached, so it outlives ATLAS rather than
    /// dying with it the way a terminal-started copy does.
    @discardableResult
    public func startServer() -> Bool {
        guard !isRunning else { return true }
        let tsx = webAppDir.appendingPathComponent("node_modules/.bin/tsx")
        let script = "scripts/mythos-connection-center-server.ts"
        guard FileManager.default.fileExists(atPath: tsx.path) else {
            lastError = "tsx not found — run npm install in mythos-webapp"
            return false
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "cd \"\(webAppDir.path)\" && nohup \"\(tsx.path)\" \(script) > /tmp/connection-center.log 2>&1 &"]
        do {
            try task.run()
            task.waitUntilExit()
            // give the listener a moment before reporting state
            Thread.sleep(forTimeInterval: 2.5)
            checkRunning()
            if !isRunning { lastError = "Server did not come up — see /tmp/connection-center.log" }
            return isRunning
        } catch {
            lastError = "Could not start the server: \(error.localizedDescription)"
            return false
        }
    }
}
