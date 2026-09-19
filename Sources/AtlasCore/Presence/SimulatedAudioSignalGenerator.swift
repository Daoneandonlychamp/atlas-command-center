import Foundation
import Combine

// MARK: - Audio Signal Output Struct

public struct AudioEnergyFrame: Equatable {
    public var rmsLoudness: Double
    public var bassEnergy: Double
    public var midEnergy: Double
    public var trebleEnergy: Double

    public init(
        rmsLoudness: Double = 0.0,
        bassEnergy: Double = 0.0,
        midEnergy: Double = 0.0,
        trebleEnergy: Double = 0.0
    ) {
        self.rmsLoudness = rmsLoudness
        self.bassEnergy = bassEnergy
        self.midEnergy = midEnergy
        self.trebleEnergy = trebleEnergy
    }

    public static let zero = AudioEnergyFrame()
}

// MARK: - Audio Signal Provider Protocol (For clean Phase 2 real PCM substitution)

public protocol AudioSignalProvider: AnyObject {
    var currentFrame: AudioEnergyFrame { get }
}

// MARK: - Simulated Audio Signal Generator

public final class SimulatedAudioSignalGenerator: ObservableObject, AudioSignalProvider {
    public static let shared = SimulatedAudioSignalGenerator()

    @Published public private(set) var currentFrame: AudioEnergyFrame = .zero

    private var timer: Timer?
    private var isSimulating: Bool = false

    // Smoothing state
    private var targetRMS: Double = 0.0
    private var targetBass: Double = 0.0
    private var targetMid: Double = 0.0
    private var targetTreble: Double = 0.0

    private var smoothRMS: Double = 0.0
    private var smoothBass: Double = 0.0
    private var smoothMid: Double = 0.0
    private var smoothTreble: Double = 0.0

    private var phase: Double = 0.0

    public init() {}

    public func startSimulation() {
        guard !isSimulating else { return }
        isSimulating = true
        phase = 0.0

        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.updateSignal()
            }
        }
    }

    public func stopSimulation() {
        isSimulating = false
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = nil
            self.smoothRMS = 0.0
            self.smoothBass = 0.0
            self.smoothMid = 0.0
            self.smoothTreble = 0.0
            self.currentFrame = .zero
        }
    }

    private func updateSignal() {
        phase += 0.12

        // Speech cadence simulation: alternating speech bursts and micro-pauses
        let speechEnvelope = max(0, sin(phase * 0.7) * cos(phase * 0.3))
        let isActiveSpeech = speechEnvelope > 0.1

        if isActiveSpeech {
            // Generate vocal target energies
            targetRMS = min(1.0, speechEnvelope * (0.6 + 0.4 * sin(phase * 2.1)))
            targetBass = min(1.0, 0.4 + 0.5 * cos(phase * 1.3))
            targetMid = min(1.0, 0.5 + 0.4 * sin(phase * 3.4))
            targetTreble = min(1.0, 0.3 + 0.6 * max(0, sin(phase * 5.2)))
        } else {
            // Micro-pause silence
            targetRMS = 0.05
            targetBass = 0.08
            targetMid = 0.06
            targetTreble = 0.02
        }

        // Exponential smoothing filter (Attack = 0.35, Decay = 0.18)
        let rmsAlpha = (targetRMS > smoothRMS) ? 0.35 : 0.18
        let bassAlpha = (targetBass > smoothBass) ? 0.30 : 0.15
        let midAlpha = (targetMid > smoothMid) ? 0.35 : 0.18
        let trebleAlpha = (targetTreble > smoothTreble) ? 0.40 : 0.20

        smoothRMS += (targetRMS - smoothRMS) * rmsAlpha
        smoothBass += (targetBass - smoothBass) * bassAlpha
        smoothMid += (targetMid - smoothMid) * midAlpha
        smoothTreble += (targetTreble - smoothTreble) * trebleAlpha

        let newFrame = AudioEnergyFrame(
            rmsLoudness: max(0, min(1.0, smoothRMS)),
            bassEnergy: max(0, min(1.0, smoothBass)),
            midEnergy: max(0, min(1.0, smoothMid)),
            trebleEnergy: max(0, min(1.0, smoothTreble))
        )

        DispatchQueue.main.async {
            self.currentFrame = newFrame
        }
    }
}
