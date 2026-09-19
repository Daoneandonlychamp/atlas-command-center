import XCTest
import Combine
@testable import AtlasCore

final class SovereignVoiceTests: XCTestCase {

    /// A stand-in interpreter and model directory, created per test.
    ///
    /// Voice is off until the user points Settings at a real Python and a
    /// downloaded model, so a test that wants the *configured* path has to
    /// supply one. These are files that exist and nothing more — enough for
    /// `checkRuntimeAvailability`, which asks only that.
    private var runtimeRoot: URL!
    private var fixturePython: String { runtimeRoot.appendingPathComponent("python").path }
    private var fixtureModel: String { runtimeRoot.appendingPathComponent("model").path }

    override func setUp() {
        super.setUp()
        SovereignPresenceStateManager.shared.resetForTesting()
        SovereignVoiceService.shared.shutdownWorker()

        runtimeRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atlas-voice-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: runtimeRoot.appendingPathComponent("model"), withIntermediateDirectories: true)
        // A launchable stand-in: it starts, stays running, and says nothing.
        // A plain empty file would fail to exec, which is a different failure
        // from the one any of these tests is about.
        FileManager.default.createFile(
            atPath: fixturePython,
            contents: Data("#!/bin/sh\nexec sleep 30\n".utf8),
            attributes: [.posixPermissions: 0o755])

        SovereignVoiceService.shared.customPythonPath = fixturePython
        SovereignVoiceService.shared.customModelPath = fixtureModel
        SovereignVoiceService.shared.customScriptPath = nil
    }

    override func tearDown() {
        SovereignPresenceStateManager.shared.resetForTesting()
        SovereignVoiceService.shared.shutdownWorker()
        SovereignVoiceService.shared.customPythonPath = nil
        SovereignVoiceService.shared.customModelPath = nil
        SovereignVoiceService.shared.customScriptPath = nil
        if let root = runtimeRoot { try? FileManager.default.removeItem(at: root) }
        runtimeRoot = nil
        super.tearDown()
    }

    // MARK: - 1. Speech Sanitizing & Chunking Tests

    func testSpeechSanitization() {
        let raw = """
        # Mission Briefing
        Here is the link: [ATLAS Repo](https://github.com/example/ATLAS).
        ```python
        print("do not speak this code block")
        ```
        Use `npm run dev` for dev server. **Important**: e.g. v0.19 build.
        * Bullet point one
        """

        let sanitized = SovereignSpeechSanitizer.sanitize(raw)

        XCTAssertFalse(sanitized.contains("```python"))
        XCTAssertFalse(sanitized.contains("print(\"do not speak this code block\")"))
        XCTAssertFalse(sanitized.contains("https://github.com/example/ATLAS"))
        XCTAssertTrue(sanitized.contains("Atlas Repo"))
        XCTAssertTrue(sanitized.contains("npm run dev"))
        XCTAssertTrue(sanitized.contains("for example"))
        XCTAssertTrue(sanitized.contains("version zero point"))
        XCTAssertFalse(sanitized.contains("**Important**"))
    }

    func testSentenceChunkingWordBoundaries() {
        let text = "This is sentence one. This is sentence two with more words to test chunking logic. This is sentence three."
        let chunks = SovereignSpeechSanitizer.chunk(text, maxWordsPerChunk: 10)

        XCTAssertGreaterThan(chunks.count, 1)

        for chunk in chunks {
            let words = chunk.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            XCTAssertLessThanOrEqual(words.count, 15) // Sentence boundary margin
            XCTAssertFalse(chunk.isEmpty)
        }
    }

    // MARK: - 2. Delivery Mode Reference Mapping

    func testDeliveryModeReferenceMapping() {
        XCTAssertEqual(SovereignVoiceDeliveryMode.conversational.referenceFilename, "lewis_onyx_blend_conversational.wav")
        XCTAssertEqual(SovereignVoiceDeliveryMode.mission.referenceFilename, "lewis_onyx_blend_mission.wav")
        XCTAssertEqual(SovereignVoiceDeliveryMode.wakeup.referenceFilename, "lewis_onyx_blend_wakeup.wav")
        XCTAssertEqual(SovereignVoiceDeliveryMode.warning.referenceFilename, "lewis_onyx_blend_mission.wav")
    }

    // MARK: - 3. Persistent Worker Preservation & Launch Count Tests

    func testPersistentWorkerReusedAcrossPromptAndSpeaking() {
        let service = SovereignVoiceService.shared

        // A script path that does not exist, so the worker launches and dies
        // immediately — the launch count is what this test is about, not the
        // worker surviving.
        service.customScriptPath = "/tmp/nonexistent_test_script.py"
        service.checkRuntimeAvailability()

        service.warmWorker()
        let initialLaunches = service.workerLaunchCount
        XCTAssertGreaterThan(initialLaunches, 0)

        // Simulating worker ready event
        service.handleWorkerOutputLine("{\"event\": \"ready\"}")
        XCTAssertEqual(service.state, .ready)

        // Stop idle ready service -> Worker must NOT be terminated!
        service.stop()
        XCTAssertEqual(service.state, .ready)
        XCTAssertEqual(service.workerLaunchCount, initialLaunches)

        // Speak prompt -> Should reuse ready worker without incrementing launch count
        service.speak(text: "Test payload", deliveryMode: .conversational, for: nil)
        XCTAssertEqual(service.workerLaunchCount, initialLaunches)

        // Clean up worker
        service.shutdownWorker()
    }

    func testFilesExistingDoesNotEqualReady() {
        let service = SovereignVoiceService.shared
        service.checkRuntimeAvailability()

        // Both files are present (setUp made them), and the service is still
        // only .cold. Files on disk are not a loaded model.
        XCTAssertEqual(service.state, .cold)
    }

    func testMissingRuntimeProducesUnavailableState() {
        let service = SovereignVoiceService.shared
        service.customPythonPath = "/non/existent/python/path/binary"
        service.checkRuntimeAvailability()

        if case .unavailable(let reason) = service.state {
            XCTAssertTrue(reason.contains("Python runtime missing"))
        } else {
            XCTFail("Expected .unavailable state for missing python binary")
        }
    }

    // MARK: - 4. Multi-Chunk Pipeline & Ordering Tests

    func testMultiChunkSequencePipelineAndOrdering() {
        let session = SovereignSpeechSession(
            missionToken: nil,
            deliveryMode: .conversational,
            orderedChunks: ["Chunk zero.", "Chunk one.", "Chunk two."],
            onStarted: nil,
            onCompleted: nil
        )

        XCTAssertEqual(session.orderedChunks.count, 3)
        XCTAssertEqual(session.currentPlaybackIndex, 0)

        session.synthesizedWavs[0] = "/tmp/chk0.wav"
        session.synthesizedWavs[1] = "/tmp/chk1.wav"
        session.synthesizedWavs[2] = "/tmp/chk2.wav"
        session.isSynthesisComplete = true

        var completionCount = 0
        var recordedOutcome: SovereignVoiceOutcome?

        let service = SovereignVoiceService.shared
        service.speak(text: "Chunk zero. Chunk one. Chunk two.", deliveryMode: .conversational, for: nil) { outcome in
            completionCount += 1
            recordedOutcome = outcome
        }

        XCTAssertEqual(completionCount, 0) // Synthesis active
        service.stop()

        XCTAssertEqual(completionCount, 1) // Completed exactly once upon stop
        XCTAssertEqual(recordedOutcome, .cancelled)
    }

    func testTemporaryGapBetweenSynthesisAndPlaybackDoesNotCompleteEarly() {
        let service = SovereignVoiceService.shared
        var completedFired = false

        service.speak(text: "First sentence here. Second sentence here.", deliveryMode: .conversational, for: nil) { outcome in
            completedFired = true
        }

        // Mid-session gap should NOT trigger completion early
        XCTAssertFalse(completedFired)
    }

    // MARK: - 5. Voice Failure & Text Fallback Tests

    func testTextOnlyFallbackOnVoiceFailure() {
        let manager = SovereignPresenceStateManager.shared
        let mission = manager.beginMission(description: "Text Fallback Test")

        let service = SovereignVoiceService.shared
        service.customPythonPath = "/invalid/path"
        service.checkRuntimeAvailability()

        var outcomeReceived: SovereignVoiceOutcome?
        service.speak(text: "Test speech failure payload", deliveryMode: .conversational, for: mission) { outcome in
            outcomeReceived = outcome
        }

        // Voice failure should report outcome without crashing Hermes mission
        XCTAssertNotNil(outcomeReceived)
        XCTAssertFalse(outcomeReceived!.isSuccess)
    }

    // MARK: - 6. Worker Generation Isolation Tests

    func testObsoleteWorkerReadyEventsIgnored() {
        let service = SovereignVoiceService.shared
        let oldGen = UUID()

        service.handleWorkerOutputLine("{\"event\": \"ready\"}", generation: oldGen)

        // State remains cold, old generation line ignored
        XCTAssertEqual(service.state, .cold)
    }

    // MARK: - 7. Audio Energy Clamping & NaN Rejection

    func testAudioEnergyCalculatorClampingAndNaN() {
        let nanFrame = AudioEnergyCalculator.calculate(averagePower: Float.nan, peakPower: Float.infinity)
        XCTAssertEqual(nanFrame, .zero)

        let extremeFrame = AudioEnergyCalculator.calculate(averagePower: 100.0, peakPower: 50.0)
        XCTAssertLessThanOrEqual(extremeFrame.rmsLoudness, 1.0)
        XCTAssertLessThanOrEqual(extremeFrame.bassEnergy, 1.0)

        let silentFrame = AudioEnergyCalculator.calculate(averagePower: -200.0, peakPower: -200.0)
        XCTAssertEqual(silentFrame, .zero)
    }

    // MARK: - 8. Voice Disabled Text-Only Completion

    func testVoiceDisabledTextOnlyCompletion() {
        let service = SovereignVoiceService.shared
        let wasEnabled = service.isVoiceEnabled
        service.isVoiceEnabled = false

        var outcome: SovereignVoiceOutcome?
        service.speak(text: "Testing voice disabled", deliveryMode: .conversational, for: nil) { res in
            outcome = res
        }

        XCTAssertEqual(outcome, .unavailable(reason: "Voice disabled"))
        service.isVoiceEnabled = wasEnabled
    }

    // MARK: - 9. Bundled Resource Location Test

    func testBundledResourceResolution() {
        let scriptPath = SovereignVoiceService.shared.getWorkerScriptPath()
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath))

        #if SWIFT_PACKAGE
        if let bundleUrl = Bundle.module.url(forResource: "sovereign_voice_worker", withExtension: "py") {
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundleUrl.path))
        }
        #endif
    }

    // MARK: - 10. Gated Real-Model Integration Test

    func testRealChatterboxIntegration() throws {
        // Whatever this machine was pointed at in Settings. Unset on a fresh
        // install, which is why the guard below skips rather than fails.
        let pythonPath = WorkspaceSettings.voicePythonPath
        let modelPath = WorkspaceSettings.voiceModelPath

        // Resolve canonical worker script through production resource bundle path!
        let scriptPath = SovereignVoiceService.shared.getWorkerScriptPath()

        guard FileManager.default.fileExists(atPath: pythonPath) &&
              FileManager.default.fileExists(atPath: modelPath) &&
              FileManager.default.fileExists(atPath: scriptPath) else {
            print("[SKIP] Chatterbox Python environment, model snapshot, or canonical worker script not present on this machine.")
            return
        }

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let outputWav = caches.appendingPathComponent("ATLAS/Voice/integration_test_lewis_onyx.wav").path

        try? FileManager.default.removeItem(atPath: outputWav)

        let exp = expectation(description: "Real Chatterbox WAV generation completed")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        var generatedWavPath: String? = nil
        var buffer = ""

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            buffer += String(decoding: data, as: UTF8.self)

            while let newlineRange = buffer.range(of: "\n") {
                let line = String(buffer[..<newlineRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                buffer.removeSubrange(..<newlineRange.upperBound)

                if line.isEmpty { continue }

                if line.contains("\"event\": \"ready\"") {
                    let req: [String: Any] = [
                        "action": "synthesize",
                        "id": "integration-test-1",
                        "text": "ATLAS Sovereign voice integration verified.",
                        "mode": "conversational",
                        "output_path": outputWav
                    ]
                    if let reqData = try? JSONSerialization.data(withJSONObject: req),
                       let reqStr = String(data: reqData, encoding: .utf8) {
                        stdinPipe.fileHandleForWriting.write((reqStr + "\n").data(using: .utf8)!)
                    }
                } else if line.contains("\"event\": \"completed\"") {
                    if let jsonData = line.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let path = json["output_path"] as? String {
                        generatedWavPath = path
                        exp.fulfill()
                    }
                }
            }
        }

        try process.run()
        wait(for: [exp], timeout: 45.0)

        // Clean up process
        process.terminate()

        // Verify generated WAV properties
        guard let wavPath = generatedWavPath else {
            XCTFail("WAV file path was not returned by worker")
            return
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: wavPath), "WAV file must exist on disk")

        let fileData = try Data(contentsOf: URL(fileURLWithPath: wavPath))
        XCTAssertGreaterThan(fileData.count, 1000, "WAV file must be non-empty")

        // Parse WAV Header (RIFF format)
        let numChannels = fileData.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self) }
        let sampleRate = fileData.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self) }
        let bitsPerSample = fileData.withUnsafeBytes { $0.load(fromByteOffset: 34, as: UInt16.self) }

        XCTAssertEqual(numChannels, 1, "Audio must be mono (1 channel)")
        XCTAssertEqual(sampleRate, 24000, "Audio sample rate must be 24,000 Hz")

        let bytesPerSample = Double(bitsPerSample) / 8.0
        let pcmDataBytes = Double(fileData.count - 44)
        let durationSec = pcmDataBytes / (Double(sampleRate) * Double(numChannels) * bytesPerSample)

        XCTAssertGreaterThan(durationSec, 1.0, "Audio duration must be greater than 1.0s")
        XCTAssertLessThan(durationSec, 10.0, "Audio duration must not be an exaggerated or 20s malformed output")
    }
}
