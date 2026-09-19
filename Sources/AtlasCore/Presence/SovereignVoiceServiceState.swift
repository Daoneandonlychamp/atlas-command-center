import Foundation

/// States for the Sovereign Voice Service process & playback pipeline.
public enum SovereignVoiceServiceState: Equatable, Sendable {
    case unavailable(reason: String)
    case cold
    case warming
    case ready
    case synthesizing(chunkId: String)
    case playing(chunkId: String)
    case failed(error: String)

    public var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        if case .synthesizing = self { return true }
        if case .playing = self { return true }
        return false
    }

    public var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    /// Short, stable token for the UI. `statusDescription` is prose meant for
    /// Settings; this is what the HUD switches on.
    public var uiState: String {
        switch self {
        case .unavailable: return "unavailable"
        case .cold:        return "cold"
        case .warming:     return "warming"
        case .ready:       return "ready"
        case .synthesizing: return "synthesizing"
        case .playing:     return "speaking"
        case .failed:      return "failed"
        }
    }

    public var statusDescription: String {
        switch self {
        case .unavailable(let reason):
            return "Voice Unavailable (\(reason))"
        case .cold:
            return "Voice Available (Cold)"
        case .warming:
            return "Warming Chatterbox Worker..."
        case .ready:
            return "Sovereign Voice Ready"
        case .synthesizing(let id):
            return "Synthesizing Speech (\(id))..."
        case .playing(let id):
            return "Speaking (\(id))..."
        case .failed(let err):
            return "Voice Failed: \(err)"
        }
    }
}
