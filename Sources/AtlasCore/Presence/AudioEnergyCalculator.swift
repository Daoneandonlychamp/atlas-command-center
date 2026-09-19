import Foundation

/// Pure deterministic helper for calculating normalized audio energy frames from player power metering.
/// Note: Represents approximate amplitude-weighted energy levels derived from peak and average power.
public struct AudioEnergyCalculator {
    public init() {}

    public static func calculate(averagePower: Float, peakPower: Float) -> AudioEnergyFrame {
        guard !averagePower.isNaN && !averagePower.isInfinite &&
              !peakPower.isNaN && !peakPower.isInfinite else {
            return .zero
        }

        // dB range from -50.0 (silence) to 0.0 (max peak)
        let minDb: Float = -50.0
        guard averagePower > minDb || peakPower > minDb else {
            return .zero
        }

        let normAvg = max(0.0, min(1.0, (max(minDb, averagePower) - minDb) / -minDb))
        let normPeak = max(0.0, min(1.0, (max(minDb, peakPower) - minDb) / -minDb))

        let rms = Double(normAvg)
        let bass = Double(normPeak * 0.8)
        let mid = Double(normAvg * 0.9)
        let treble = Double(normPeak * 0.7)

        return AudioEnergyFrame(
            rmsLoudness: max(0.0, min(1.0, rms)),
            bassEnergy: max(0.0, min(1.0, bass)),
            midEnergy: max(0.0, min(1.0, mid)),
            trebleEnergy: max(0.0, min(1.0, treble))
        )
    }
}
