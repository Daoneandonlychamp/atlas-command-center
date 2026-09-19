import Foundation

/// Explicit outcome for a Sovereign Voice synthesis and playback request.
public enum SovereignVoiceOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case unavailable(reason: String)
    case synthesisFailed(reason: String)
    case playbackFailed(reason: String)

    public var isSuccess: Bool {
        if case .completed = self { return true }
        return false
    }

    public var statusDescription: String {
        switch self {
        case .completed:
            return "Speech Completed"
        case .cancelled:
            return "Speech Cancelled"
        case .unavailable(let reason):
            return "Voice Unavailable (\(reason))"
        case .synthesisFailed(let err):
            return "Synthesis Failed (\(err))"
        case .playbackFailed(let err):
            return "Playback Failed (\(err))"
        }
    }
}
