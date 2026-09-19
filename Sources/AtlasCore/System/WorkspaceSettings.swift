import Foundation

/// Where ATLAS is allowed to look on this particular Mac.
///
/// Every path here starts empty. ATLAS ships knowing nothing about the machine
/// it landed on, and each surface that needs a location asks for one rather
/// than guessing — a scanner pointed at a folder that does not exist reports an
/// empty state, which is honest, where a guessed home directory is not.
///
/// Stored in `UserDefaults` rather than a store, because these are preferences
/// about the machine, not the user's data. Nothing here is secret; secrets live
/// in the Keychain.
public enum WorkspaceSettings {
    private static let defaults = UserDefaults.standard

    public enum Key {
        public static let projectSearchPaths = "atlas.workspace.projectSearchPaths"
        public static let companionScopes = "atlas.workspace.companionScopes"
        public static let hermesGatewayURL = "atlas.workspace.hermesGatewayURL"
        public static let hermesBinaryPath = "atlas.workspace.hermesBinaryPath"
        public static let voicePythonPath = "atlas.workspace.voicePythonPath"
        public static let voiceModelPath = "atlas.workspace.voiceModelPath"
    }

    // MARK: - Projects

    /// Folders scanned for git repositories. Empty means the Projects surface
    /// shows its empty state, which is what a fresh install should do.
    public static var projectSearchPaths: [String] {
        get { stringList(Key.projectSearchPaths) }
        set { setStringList(Key.projectSearchPaths, newValue) }
    }

    // MARK: - Companion

    /// The Companion's filesystem boundary.
    ///
    /// Empty means the Companion can read nothing and run nothing, and that is
    /// the correct default for an allowlist guarding shell execution: the cost
    /// of shipping it empty is a feature that does nothing until configured,
    /// and the cost of shipping it populated is a guess about someone else's
    /// machine that grants more than they asked for.
    public static var companionScopes: [String] {
        get { stringList(Key.companionScopes) }
        set { setStringList(Key.companionScopes, newValue) }
    }

    // MARK: - Hermes (optional integration)

    /// Base URL of a self-hosted Hermes gateway. Blank disables the integration.
    public static var hermesGatewayURL: String {
        get { trimmed(Key.hermesGatewayURL) }
        set { setTrimmed(Key.hermesGatewayURL, newValue) }
    }

    /// Path to the `hermes` executable. Blank falls back to whatever `hermes`
    /// resolves to on `PATH`, and to nothing at all if it is not installed.
    public static var hermesBinaryPath: String {
        get { trimmed(Key.hermesBinaryPath) }
        set { setTrimmed(Key.hermesBinaryPath, newValue) }
    }

    // MARK: - Voice (optional integration)

    /// Python interpreter for the local TTS worker. Blank disables voice.
    public static var voicePythonPath: String {
        get { trimmed(Key.voicePythonPath) }
        set { setTrimmed(Key.voicePythonPath, newValue) }
    }

    /// Downloaded MLX model directory for the local TTS worker. Blank disables voice.
    public static var voiceModelPath: String {
        get { trimmed(Key.voiceModelPath) }
        set { setTrimmed(Key.voiceModelPath, newValue) }
    }

    // MARK: - Storage

    /// Discards blanks and duplicates so a stray return in a text field does not
    /// become a scope that matches nothing, or a second copy of one that does.
    private static func stringList(_ key: String) -> [String] {
        let raw = defaults.stringArray(forKey: key) ?? []
        var seen = Set<String>()
        return raw.compactMap { entry in
            let path = (entry as NSString).expandingTildeInPath
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seen.insert(path).inserted else { return nil }
            return path
        }
    }

    private static func setStringList(_ key: String, _ value: [String]) {
        defaults.set(value, forKey: key)
    }

    private static func trimmed(_ key: String) -> String {
        (defaults.string(forKey: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func setTrimmed(_ key: String, _ value: String) {
        defaults.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key)
    }
}
