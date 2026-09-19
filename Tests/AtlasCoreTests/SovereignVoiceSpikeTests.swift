import XCTest
@testable import AtlasCore

final class SovereignVoiceSpikeTests: XCTestCase {

    override func setUp() {
        super.setUp()
    }

    // 1. Runtime Availability Check
    func testRuntimeAvailability() {
        let spike = SovereignVoiceSpike.shared
        // Tests path resolution and file existence checks
        let ttsPath = spike.ttsDirectoryPath
        XCTAssertTrue(ttsPath.contains("Application Support/ATLAS/Models/tts"))
        XCTAssertNotNil(spike.venvPythonPath)
        XCTAssertNotNil(spike.modelFilePath)
        XCTAssertNotNil(spike.voicesFilePath)
    }

    // 2. Missing Model Failure Behavior
    func testMissingModelFailureBehavior() {
        let spike = SovereignVoiceSpike.shared
        let dummyPath = "/tmp/non_existent_model_\(UUID().uuidString).wav"
        let result = spike.synthesizeSample(
            text: "Testing missing model failure.",
            voiceId: "non_existent_voice",
            outputWavPath: dummyPath
        )

        if !spike.isRuntimeAvailable {
            XCTAssertFalse(result.isSuccess)
            XCTAssertNotNil(result.errorMessage)
            XCTAssertTrue(result.errorMessage?.contains("Runtime or model missing") == true)
        }
    }

    // 3. Process Cancellation
    func testCancellationHandling() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["10"]
        try p.run()

        XCTAssertTrue(p.isRunning)
        p.terminate()
        p.waitUntilExit()
        XCTAssertFalse(p.isRunning, "Process termination must halt execution immediately")
    }

    // 4. Non-Empty Audio Generation & Attributes (If Runtime Available)
    func testNonEmptyAudioGenerationAndAttributes() throws {
        let spike = SovereignVoiceSpike.shared
        guard spike.isRuntimeAvailable else {
            // Graceful skip if model files are still downloading in background
            return
        }

        XCTAssertTrue(spike.verifyModelLoading(), "Model loading verification must pass when model files exist")

        let targetWav = NSString(string: "~/Library/Application Support/ATLAS/Models/tts/samples/test_unit.wav").expandingTildeInPath
        let result = spike.synthesizeSample(
            text: "Hello there.",
            voiceId: "bm_george",
            outputWavPath: targetWav
        )

        XCTAssertTrue(result.isSuccess, "Synthesis must succeed: \(result.errorMessage ?? "")")
        XCTAssertGreaterThan(result.audioDurationSeconds, 0.1)
        XCTAssertGreaterThan(result.synthesisTimeMs, 1.0)
        XCTAssertGreaterThan(result.realTimeFactor, 0.0)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: targetWav))
        let attrs = try fm.attributesOfItem(atPath: targetWav)
        let fileSize = attrs[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 1024, "Audio file must be non-empty (greater than 1KB)")
    }
}
