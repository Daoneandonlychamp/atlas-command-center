import Foundation

/// Explicit delivery modes for Sovereign voice synthesis conditioning.
public enum SovereignVoiceDeliveryMode: String, Codable, CaseIterable, Sendable {
    case conversational
    case mission
    case wakeup
    case warning

    public var referenceFilename: String {
        switch self {
        case .conversational:
            return "lewis_onyx_blend_conversational.wav"
        case .mission:
            return "lewis_onyx_blend_mission.wav"
        case .wakeup:
            return "lewis_onyx_blend_wakeup.wav"
        case .warning:
            return "lewis_onyx_blend_mission.wav"
        }
    }
}
