import Foundation

/// Which Hermes agent is currently live, and which world the HUD field shows.
///
/// A profile only acts when its gateway is running, so "running" is the honest
/// definition of active. The sticky default (the profile `hermes profile use`
/// selected) breaks ties when several are up.
public final class AgentPresence: ObservableObject {
    public static let shared = AgentPresence()

    /// Worlds in the order the field defines them.
    public enum World: Int {
        case aethera = 0   // Sovereign — the calm blue default
        case pyra = 1      // Foxtrot — money, fire
        case orison = 2    // unassigned
        case vesper = 3    // unassigned
    }

    /// Assignment is data, not logic, so a new agent is one line.
    public static let worldByProfile: [String: World] = [
        "sovereign": .aethera,
        "foxtrot": .pyra,
    ]

    @Published public private(set) var activeProfile: String = "sovereign"
    @Published public private(set) var runningProfiles: [String] = []

    private let profilesDir: URL
    private var lastScan = Date.distantPast
    private let interval: TimeInterval = 20

    public init(profilesDir: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".hermes/profiles")) {
        self.profilesDir = profilesDir
    }

    public var world: Int {
        (Self.worldByProfile[activeProfile] ?? .aethera).rawValue
    }

    /// Cheap enough to call every frame; the filesystem is only touched on the
    /// interval, because a gateway does not start and stop between frames.
    public func refreshIfNeeded() {
        guard Date().timeIntervalSince(lastScan) >= interval else { return }
        lastScan = Date()

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: profilesDir.path)
        else { return }

        // A gateway writes a pid file while it runs. Checking the process is
        // alive avoids treating a stale file from a crash as a live agent.
        var running: [String] = []
        for name in names.sorted() {
            let pidFile = profilesDir.appendingPathComponent(name).appendingPathComponent("gateway.pid")
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  kill(pid, 0) == 0 || errno == EPERM
            else { continue }
            running.append(name)
        }

        runningProfiles = running
        // Prefer a non-sovereign specialist when one is up, since that is the
        // agent doing something distinct right now.
        if let specialist = running.first(where: { $0 != "sovereign" && Self.worldByProfile[$0] != nil }) {
            activeProfile = specialist
        } else if let first = running.first {
            activeProfile = first
        }
    }
}
