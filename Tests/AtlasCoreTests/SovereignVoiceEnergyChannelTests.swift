import XCTest
import Combine
@testable import AtlasCore

/// Playback metering ticks 30 times a second. It used to arrive as an
/// `@Published` change, so every observer rebuilt on every audio frame — the HUD
/// re-read `atlas-statusline.json` off disk and re-encoded the entire dashboard
/// payload ~900 times per spoken brief.
///
/// These pin the split that fixed it: loudness travels on its own channel, and
/// touching it must not wake the object's general observers.
final class SovereignVoiceEnergyChannelTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// The regression guard. If `currentEnergy` is ever made `@Published` again,
    /// this fails and the 30 Hz dashboard rebuild is back.
    func testEnergyFramesDoNotFireObjectWillChange() {
        let service = SovereignVoiceService.shared
        var generalChangeCount = 0

        service.objectWillChange
            .sink { _ in generalChangeCount += 1 }
            .store(in: &cancellables)

        for _ in 0..<30 {
            service.applyEnergyFrame(
                AudioEnergyFrame(rmsLoudness: 0.7, bassEnergy: 0.5, midEnergy: 0.6, trebleEnergy: 0.4)
            )
        }

        XCTAssertEqual(generalChangeCount, 0,
                       "Audio frames woke the object's observers — the HUD will rebuild the whole payload per frame again")
    }

    /// The other half: the fast channel must actually deliver, or the particle
    /// field goes still while Sovereign is speaking.
    func testEnergyChannelDeliversEveryFrame() {
        let service = SovereignVoiceService.shared
        var received: [AudioEnergyFrame] = []

        service.energyUpdates
            .sink { received.append($0) }
            .store(in: &cancellables)

        let sent = (0..<5).map { i in
            AudioEnergyFrame(rmsLoudness: Double(i) / 5.0, bassEnergy: 0.2, midEnergy: 0.3, trebleEnergy: 0.1)
        }
        sent.forEach { service.applyEnergyFrame($0) }

        XCTAssertEqual(received.count, sent.count)
        XCTAssertEqual(received.map(\.rmsLoudness), sent.map(\.rmsLoudness))
        XCTAssertEqual(service.currentEnergy, sent[sent.count - 1], "currentEnergy must still be readable for the slow 1 Hz payload")
    }

    /// The dB→frame maths the field's shader uniforms are driven from.
    func testSilenceAndFullScaleMapToExpectedEnergy() {
        XCTAssertEqual(AudioEnergyCalculator.calculate(averagePower: -60, peakPower: -60), .zero,
                       "Below the -50 dB floor should read as silence, not a faint glow")
        XCTAssertEqual(AudioEnergyCalculator.calculate(averagePower: .nan, peakPower: 0), .zero)

        let loud = AudioEnergyCalculator.calculate(averagePower: 0, peakPower: 0)
        XCTAssertEqual(loud.rmsLoudness, 1.0, accuracy: 0.001)

        let mid = AudioEnergyCalculator.calculate(averagePower: -25, peakPower: -25)
        XCTAssertEqual(mid.rmsLoudness, 0.5, accuracy: 0.01)
    }
}
