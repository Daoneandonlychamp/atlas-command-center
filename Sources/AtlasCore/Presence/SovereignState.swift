import Foundation
import Combine

// MARK: - Sovereign State Enum

public enum SovereignState: String, Codable, CaseIterable {
    case dormant
    case idle
    case listening
    case processing
    case preparingSpeech
    case speaking
    case executing
    case awaitingApproval
    case interrupted
    case error
    case offline

    public var displayName: String {
        switch self {
        case .dormant:          return "Dormant"
        case .idle:             return "Sovereign Online (Idle)"
        case .listening:        return "Listening (Input Active)"
        case .processing:       return "Processing Mission"
        case .preparingSpeech:  return "Preparing Speech"
        case .speaking:         return "Response Presentation"
        case .executing:        return "Executing Command"
        case .awaitingApproval: return "Awaiting Security Approval"
        case .interrupted:      return "Mission Interrupted"
        case .error:            return "System Error"
        case .offline:          return "Sovereign Offline"
        }
    }

    public var statusDescription: String {
        switch self {
        case .dormant:          return "Core in low-power resting state"
        case .idle:             return "Ready for mission directives"
        case .listening:        return "Receiving mission context & prompt"
        case .processing:       return "Reasoning with Sovereign LLM model"
        case .preparingSpeech:  return "Reserved for TTS payload preparation"
        case .speaking:         return "Presenting response payload (simulated speech energy)"
        case .executing:        return "Reserved for local companion tool execution"
        case .awaitingApproval: return "Security gate: approval required"
        case .interrupted:      return "Operation cancelled by operator"
        case .error:            return "Execution halted due to fault"
        case .offline:          return "Hermes agent or authentication unavailable"
        }
    }
}

// MARK: - Sovereign Mission Token

public struct SovereignMissionToken: Hashable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let description: String
    public let timestamp: Date

    public init(id: UUID = UUID(), description: String = "", timestamp: Date = Date()) {
        self.id = id
        self.description = description
        self.timestamp = timestamp
    }
}

// MARK: - Normalized Render Parameters (Platform Neutral — No SwiftUI Dependency)

public struct SovereignCoreNormalizedParameters: Equatable {
    public var state: SovereignState
    public var coreRadius: Double
    public var luminosity: Double
    public var innerDensity: Double
    public var filamentStrength: Double
    public var surfaceTurbulence: Double
    public var particleVelocity: Double
    public var primaryColorTag: String
    public var secondaryColorTag: String
    public var nucleusColorTag: String

    public init(
        state: SovereignState = .idle,
        coreRadius: Double = 36.0,
        luminosity: Double = 0.8,
        innerDensity: Double = 0.7,
        filamentStrength: Double = 0.5,
        surfaceTurbulence: Double = 0.3,
        particleVelocity: Double = 0.5,
        primaryColorTag: String = "gold",
        secondaryColorTag: String = "lightGold",
        nucleusColorTag: String = "white"
    ) {
        self.state = state
        self.coreRadius = coreRadius
        self.luminosity = luminosity
        self.innerDensity = innerDensity
        self.filamentStrength = filamentStrength
        self.surfaceTurbulence = surfaceTurbulence
        self.particleVelocity = particleVelocity
        self.primaryColorTag = primaryColorTag
        self.secondaryColorTag = secondaryColorTag
        self.nucleusColorTag = nucleusColorTag
    }
}

// MARK: - Pure Deterministic Render Parameter Function

public func calculateNormalizedRenderParameters(
    state: SovereignState,
    audio: AudioEnergyFrame = .zero
) -> SovereignCoreNormalizedParameters {
    var p = SovereignCoreNormalizedParameters(state: state)

    switch state {
    case .dormant:
        p.coreRadius = 24.0
        p.luminosity = 0.2
        p.innerDensity = 0.3
        p.filamentStrength = 0.1
        p.surfaceTurbulence = 0.05
        p.particleVelocity = 0.1
        p.primaryColorTag = "darkGold"
        p.secondaryColorTag = "dimGold"
        p.nucleusColorTag = "dimWhite"

    case .idle:
        p.coreRadius = 36.0
        p.luminosity = 0.75
        p.innerDensity = 0.65
        p.filamentStrength = 0.4
        p.surfaceTurbulence = 0.2
        p.particleVelocity = 0.4
        p.primaryColorTag = "gold"
        p.secondaryColorTag = "lightGold"
        p.nucleusColorTag = "white"

    case .listening:
        p.coreRadius = 32.0 // Inward compression
        p.luminosity = 0.85
        p.innerDensity = 0.8
        p.filamentStrength = 0.6
        p.surfaceTurbulence = 0.35
        p.particleVelocity = 0.6
        p.primaryColorTag = "cyan"
        p.secondaryColorTag = "lightGold"
        p.nucleusColorTag = "white"

    case .processing:
        p.coreRadius = 42.0
        p.luminosity = 0.9
        p.innerDensity = 0.85
        p.filamentStrength = 0.7
        p.surfaceTurbulence = 0.5
        p.particleVelocity = 1.4 // Fast orbital movement
        p.primaryColorTag = "gold"
        p.secondaryColorTag = "brightGold"
        p.nucleusColorTag = "white"

    case .preparingSpeech:
        p.coreRadius = 34.0
        p.luminosity = 0.95
        p.innerDensity = 0.95
        p.filamentStrength = 0.5
        p.surfaceTurbulence = 0.25
        p.particleVelocity = 0.5
        p.primaryColorTag = "warmWhite"
        p.secondaryColorTag = "gold"
        p.nucleusColorTag = "pureWhite"

    case .speaking:
        let rms = audio.rmsLoudness
        let bass = audio.bassEnergy
        let mid = audio.midEnergy
        let treble = audio.trebleEnergy

        p.coreRadius = 36.0 + (rms * 22.0) + (bass * 8.0)
        p.luminosity = min(1.0, 0.8 + (rms * 0.25))
        p.innerDensity = min(1.0, 0.7 + (mid * 0.3))
        p.filamentStrength = min(1.0, 0.4 + (bass * 0.6))
        p.surfaceTurbulence = min(1.0, 0.2 + (treble * 0.8))
        p.particleVelocity = 0.6 + (treble * 1.2)
        p.primaryColorTag = "gold"
        p.secondaryColorTag = "lightGold"
        p.nucleusColorTag = "white"

    case .executing:
        p.coreRadius = 40.0
        p.luminosity = 0.85
        p.innerDensity = 0.75
        p.filamentStrength = 0.6
        p.surfaceTurbulence = 0.4
        p.particleVelocity = 1.0
        p.primaryColorTag = "gold"
        p.secondaryColorTag = "pureWhite"
        p.nucleusColorTag = "white"

    case .awaitingApproval:
        p.coreRadius = 38.0
        p.luminosity = 0.85
        p.innerDensity = 0.7
        p.filamentStrength = 0.5
        p.surfaceTurbulence = 0.3
        p.particleVelocity = 0.4
        p.primaryColorTag = "amber"
        p.secondaryColorTag = "lightAmber"
        p.nucleusColorTag = "white"

    case .interrupted:
        p.coreRadius = 26.0 // Sudden contraction
        p.luminosity = 0.6
        p.innerDensity = 0.5
        p.filamentStrength = 0.2
        p.surfaceTurbulence = 0.6
        p.particleVelocity = 0.2
        p.primaryColorTag = "amber"
        p.secondaryColorTag = "mutedGold"
        p.nucleusColorTag = "white"

    case .error:
        p.coreRadius = 38.0
        p.luminosity = 0.8
        p.innerDensity = 0.6
        p.filamentStrength = 0.4
        p.surfaceTurbulence = 0.8
        p.particleVelocity = 0.3
        p.primaryColorTag = "red"
        p.secondaryColorTag = "darkRed"
        p.nucleusColorTag = "pinkWhite"

    case .offline:
        p.coreRadius = 30.0
        p.luminosity = 0.3
        p.innerDensity = 0.4
        p.filamentStrength = 0.1
        p.surfaceTurbulence = 0.05
        p.particleVelocity = 0.1
        p.primaryColorTag = "gray"
        p.secondaryColorTag = "darkGray"
        p.nucleusColorTag = "dimWhite"
    }

    return p
}

// MARK: - Sovereign Presence State Manager

public final class SovereignPresenceStateManager: ObservableObject {
    public static let shared = SovereignPresenceStateManager()

    @Published public private(set) var currentState: SovereignState = .idle
    @Published public private(set) var activeMission: SovereignMissionToken? = nil

    private let lock = NSLock()

    public init() {}

    /// Begins a new mission, invalidating any previous mission tokens.
    @discardableResult
    public func beginMission(description: String = "") -> SovereignMissionToken {
        lock.lock()
        let newToken = SovereignMissionToken(description: description)
        self.activeMission = newToken
        self.currentState = .processing
        lock.unlock()

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        return newToken
    }

    /// Checks if a mission token is the currently active mission.
    public func isMissionActive(_ mission: SovereignMissionToken?) -> Bool {
        guard let mission = mission else { return false }
        lock.lock()
        defer { lock.unlock() }
        return activeMission == mission
    }

    /// Transitions visual state for a valid mission token. Rejects stale tokens.
    @discardableResult
    public func transition(to newState: SovereignState, for mission: SovereignMissionToken?) -> Bool {
        guard let mission = mission else { return false }
        lock.lock()
        defer { lock.unlock() }

        guard activeMission == mission else {
            return false
        }

        guard isLegalTransition(from: currentState, to: newState) else {
            return false
        }

        self.currentState = newState

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        return true
    }

    /// Completes a mission and transitions to the specified ending state.
    public func completeMission(_ mission: SovereignMissionToken?, endingState: SovereignState = .idle) {
        guard let mission = mission else { return }
        lock.lock()
        defer { lock.unlock() }

        guard activeMission == mission else { return }

        self.activeMission = nil
        self.currentState = endingState

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    /// Interrupts a specific active mission.
    public func interruptMission(_ mission: SovereignMissionToken?) {
        guard let mission = mission else { return }
        lock.lock()
        guard activeMission == mission else {
            lock.unlock()
            return
        }

        self.activeMission = nil
        self.currentState = .interrupted
        lock.unlock()

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }

        // Schedule settling to idle or offline after shockwave animation
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            // Ensure no NEW mission was started during the settling delay!
            if self.activeMission == nil && self.currentState == .interrupted {
                let isOffline = HermesConnector.shared.authState == .loginRequired ||
                                HermesConnector.shared.authState == .notInstalled ||
                                HermesConnector.shared.authState == .notConfigured
                self.currentState = isOffline ? .offline : .idle
                self.lock.unlock()

                DispatchQueue.main.async {
                    self.objectWillChange.send()
                }
            } else {
                self.lock.unlock()
            }
        }
    }

    /// Interrupts all active mission work (used by Emergency Stop).
    public func interruptAll() {
        lock.lock()
        self.activeMission = nil
        self.currentState = .interrupted
        lock.unlock()

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    /// Directly sets an un-missioned resting state (e.g. idle, offline, listening).
    public func setRestingState(_ newState: SovereignState) {
        lock.lock()
        // If a mission is actively running, do not override unless offline or error
        if activeMission != nil && newState != .offline && newState != .error {
            lock.unlock()
            return
        }
        self.currentState = newState
        lock.unlock()

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    /// Reset method for unit test isolation.
    public func resetForTesting() {
        lock.lock()
        self.activeMission = nil
        self.currentState = .idle
        lock.unlock()

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    private func isLegalTransition(from source: SovereignState, to target: SovereignState) -> Bool {
        if source == target { return true }
        if target == .error || target == .offline || target == .interrupted { return true }

        switch source {
        case .dormant:          return target == .idle || target == .offline
        case .idle:             return target == .listening || target == .processing || target == .dormant || target == .offline
        case .listening:        return target == .idle || target == .processing
        case .processing:       return target == .preparingSpeech || target == .speaking || target == .awaitingApproval || target == .executing || target == .idle
        case .preparingSpeech:  return target == .speaking || target == .idle
        case .speaking:         return target == .idle || target == .processing
        case .executing:        return target == .idle || target == .preparingSpeech || target == .speaking || target == .awaitingApproval
        case .awaitingApproval: return target == .processing || target == .executing || target == .preparingSpeech || target == .speaking || target == .idle
        case .interrupted:      return target == .idle || target == .offline || target == .processing || target == .listening
        case .error:            return target == .idle || target == .offline || target == .processing
        case .offline:          return target == .idle || target == .processing
        }
    }
}
