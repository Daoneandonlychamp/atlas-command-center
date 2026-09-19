import Foundation
import Combine
import AVFoundation

public protocol SovereignVoiceServiceProtocol: ObservableObject {
    var state: SovereignVoiceServiceState { get }
    var currentEnergy: AudioEnergyFrame { get }
    var isVoiceEnabled: Bool { get set }
    var isAutoSpeakEnabled: Bool { get set }
    var outputVolume: Float { get set }
    var workerLaunchCount: Int { get }

    func warmWorker()
    func speak(text: String, deliveryMode: SovereignVoiceDeliveryMode, for mission: SovereignMissionToken?, onPlaybackStarted: (() -> Void)?, onPlaybackCompleted: ((SovereignVoiceOutcome) -> Void)?)
    func testVoice(onPlaybackStarted: (() -> Void)?, onPlaybackCompleted: ((SovereignVoiceOutcome) -> Void)?)
    func stop()
    func shutdownWorker()
}

public final class SovereignSpeechSession: Identifiable {
    public let id = UUID()
    public let missionToken: SovereignMissionToken?
    public let deliveryMode: SovereignVoiceDeliveryMode
    public let orderedChunks: [String]

    public var synthesizedWavs: [Int: String] = [:]
    public var currentSynthesisIndex: Int = 0
    public var currentPlaybackIndex: Int = 0
    public var isSynthesisStarted: Bool = false
    public var isSynthesisComplete: Bool = false
    public var isPlaybackComplete: Bool = false
    private var hasFiredCompletion: Bool = false

    public let onStarted: (() -> Void)?
    public let onCompleted: ((SovereignVoiceOutcome) -> Void)?

    public init(
        missionToken: SovereignMissionToken?,
        deliveryMode: SovereignVoiceDeliveryMode,
        orderedChunks: [String],
        onStarted: (() -> Void)?,
        onCompleted: ((SovereignVoiceOutcome) -> Void)?
    ) {
        self.missionToken = missionToken
        self.deliveryMode = deliveryMode
        self.orderedChunks = orderedChunks
        self.onStarted = onStarted
        self.onCompleted = onCompleted
    }

    public func fireCompletion(outcome: SovereignVoiceOutcome) {
        guard !hasFiredCompletion else { return }
        hasFiredCompletion = true
        onCompleted?(outcome)
    }
}

public final class SovereignVoiceService: NSObject, ObservableObject, SovereignVoiceServiceProtocol, AVAudioPlayerDelegate {
    public static let shared = SovereignVoiceService()

    @Published public private(set) var state: SovereignVoiceServiceState = .unavailable(reason: "Not initialized")
    /// Deliberately NOT @Published. Metering runs at 30 Hz, and any
    /// objectWillChange it fired made every observer rebuild — the HUD was
    /// re-reading disk and re-encoding the whole dashboard 30x a second for the
    /// length of every spoken brief. Fast consumers subscribe to
    /// `energyUpdates`; slow ones keep reading this property on their own tick.
    public private(set) var currentEnergy: AudioEnergyFrame = .zero

    /// 30 Hz playback loudness. Carries only the frame, so a subscriber can
    /// push it straight at whatever is animating without touching anything else.
    public let energyUpdates = PassthroughSubject<AudioEnergyFrame, Never>()
    @Published public private(set) var workerLaunchCount: Int = 0

    @Published public var isVoiceEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isVoiceEnabled, forKey: "atlas.sovereign.voiceEnabled")
            if !isVoiceEnabled {
                shutdownWorker()
            }
        }
    }

    @Published public var isAutoSpeakEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoSpeakEnabled, forKey: "atlas.sovereign.autoSpeakEnabled")
        }
    }

    @Published public var outputVolume: Float {
        didSet {
            let clamped = max(0.0, min(1.0, outputVolume))
            UserDefaults.standard.set(clamped, forKey: "atlas.sovereign.outputVolume")
            audioPlayer?.volume = clamped
        }
    }

    // Settable Dependency Seams for Testing
    public var customPythonPath: String?
    public var customModelPath: String?
    public var customScriptPath: String?

    /// Python interpreter running the TTS worker. Set in Settings; blank leaves
    /// voice switched off rather than launching whatever `python` happens to be
    /// first on `PATH` and failing halfway through a model load.
    public var pythonRuntimePath: String {
        return customPythonPath ?? WorkspaceSettings.voicePythonPath
    }

    /// Downloaded MLX model directory. Blank leaves voice switched off.
    public var modelSnapshotPath: String {
        return customModelPath ?? WorkspaceSettings.voiceModelPath
    }

    private var workerProcess: Process?
    private var workerStdinPipe: Pipe?
    private var workerStdoutPipe: Pipe?
    public private(set) var currentWorkerGeneration: UUID?

    private var intentionallyTerminatedPids: Set<Int32> = []
    private var receiveBuffer = ""

    private var audioPlayer: AVAudioPlayer?
    private var energyTimer: Timer?

    private var activeSession: SovereignSpeechSession?
    private var pendingRequests: [String: (sessionId: UUID, chunkIndex: Int, outputPath: String)] = [:]

    /// In-flight priming request, if any. Its result is thrown away — see `primeInferenceKernels`.
    private var primingRequestId: String?

    private let cacheDirectory: URL

    private override init() {
        let defaultVoice = UserDefaults.standard.object(forKey: "atlas.sovereign.voiceEnabled") as? Bool ?? true
        let defaultAuto = UserDefaults.standard.object(forKey: "atlas.sovereign.autoSpeakEnabled") as? Bool ?? true
        let defaultVol = UserDefaults.standard.object(forKey: "atlas.sovereign.outputVolume") as? Float ?? 1.0

        self.isVoiceEnabled = defaultVoice
        self.isAutoSpeakEnabled = defaultAuto
        self.outputVolume = defaultVol

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = caches.appendingPathComponent("ATLAS/Voice", isDirectory: true)

        super.init()

        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        checkRuntimeAvailability()
    }

    public func checkRuntimeAvailability() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: pythonRuntimePath) {
            self.state = .unavailable(reason: "Python runtime missing at \(pythonRuntimePath)")
            return
        }
        if !fm.fileExists(atPath: modelSnapshotPath) {
            self.state = .unavailable(reason: "Chatterbox model snapshot missing at \(modelSnapshotPath)")
            return
        }
        if case .unavailable = self.state {
            self.state = .cold
        }
    }

    public func getWorkerScriptPath() -> String {
        if let custom = customScriptPath, FileManager.default.fileExists(atPath: custom) {
            return custom
        }

        #if SWIFT_PACKAGE
        if let bundlePath = Bundle.module.path(forResource: "sovereign_voice_worker", ofType: "py"),
           FileManager.default.fileExists(atPath: bundlePath) {
            return bundlePath
        }
        #endif

        if let mainBundlePath = Bundle.main.path(forResource: "sovereign_voice_worker", ofType: "py"),
           FileManager.default.fileExists(atPath: mainBundlePath) {
            return mainBundlePath
        }

        // Running from a source checkout rather than a built bundle.
        let repoPath = FileManager.default.currentDirectoryPath
            + "/Sources/AtlasCore/Resources/sovereign_voice_worker.py"
        return repoPath
    }

    public func warmWorker() {
        guard isVoiceEnabled else { return }
        checkRuntimeAvailability()

        if case .unavailable = self.state { return }
        if workerProcess != nil && workerProcess!.isRunning { return }

        self.state = .warming

        let scriptPath = getWorkerScriptPath()
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            self.state = .unavailable(reason: "Worker script missing at \(scriptPath)")
            handleCurrentSessionFailure(.unavailable(reason: "Worker script missing"))
            return
        }

        let workerGen = UUID()
        self.currentWorkerGeneration = workerGen

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonRuntimePath)
        proc.arguments = [scriptPath]
        // The worker has no idea where the user put the model; only the app
        // does, so it is handed over rather than hardcoded on both sides.
        var env = ProcessInfo.processInfo.environment
        env["ATLAS_TTS_MODEL_PATH"] = modelSnapshotPath
        proc.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // Worker stderr used to go to /dev/null, which hid every load failure
        // and made a silent voice indistinguishable from a broken one.
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            NSLog("[ATLAS VOICE worker] %@", text)
        }

        self.workerProcess = proc
        self.workerStdinPipe = stdinPipe
        self.workerStdoutPipe = stdoutPipe
        self.receiveBuffer = ""

        self.workerLaunchCount += 1

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.appendAndParseBuffer(data, generation: workerGen)
            }
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.handleWorkerTermination(proc: p, generation: workerGen, exitCode: p.terminationStatus)
            }
        }

        do {
            try proc.run()
        } catch {
            self.state = .failed(error: "Failed to launch worker: \(error.localizedDescription)")
            handleCurrentSessionFailure(.unavailable(reason: "Worker launch failed: \(error.localizedDescription)"))
        }
    }

    public func appendAndParseBuffer(_ data: Data, generation: UUID? = nil) {
        if let gen = generation, gen != currentWorkerGeneration {
            return
        }

        receiveBuffer += String(decoding: data, as: UTF8.self)

        while let newlineRange = receiveBuffer.range(of: "\n") {
            let line = String(receiveBuffer[..<newlineRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            receiveBuffer.removeSubrange(..<newlineRange.upperBound)

            if !line.isEmpty {
                handleWorkerOutputLine(line, generation: generation)
            }
        }
    }

    public func handleWorkerOutputLine(_ line: String, generation: UUID? = nil) {
        if let gen = generation, gen != currentWorkerGeneration {
            return
        }

        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else {
            return
        }

        switch event {
        case "ready":
            self.state = .ready

            // If a speech session was queued while warming, start synthesis now!
            if let session = activeSession, !session.isSynthesisStarted {
                startSynthesizingSession(session)
            } else {
                primeInferenceKernels()
            }

        case "completed":
            if let reqId = json["id"] as? String, reqId == primingRequestId {
                primingRequestId = nil
                if let path = json["output_path"] as? String {
                    try? FileManager.default.removeItem(atPath: path)
                }
                return
            }
            if let reqId = json["id"] as? String,
               let path = json["output_path"] as? String {
                if let req = pendingRequests.removeValue(forKey: reqId) {
                    handleChunkSynthesisSuccess(sessionId: req.sessionId, chunkIndex: req.chunkIndex, wavPath: path)
                }
            }

        case "error":
            // A failed priming run is not a failed voice. Never let it mark the
            // service broken — the next real request will surface any real fault.
            if let reqId = json["id"] as? String, reqId == primingRequestId {
                primingRequestId = nil
                NSLog("[ATLAS Voice] kernel priming failed (harmless): %@", json["error"] as? String ?? "?")
                return
            }
            let err = json["error"] as? String ?? "Unknown worker error"
            if let reqId = json["id"] as? String,
               let req = pendingRequests.removeValue(forKey: reqId) {
                handleChunkSynthesisFailure(sessionId: req.sessionId, chunkIndex: req.chunkIndex, errorMsg: err)
            } else {
                self.state = .failed(error: err)
                handleCurrentSessionFailure(.synthesisFailed(reason: err))
            }

        default:
            break
        }
    }

    private func handleWorkerTermination(proc: Process, generation: UUID, exitCode: Int32) {
        // Always clean up PID bookkeeping to prevent leak/reuse confusion
        let wasIntentional = proc.isRunning ? false : intentionallyTerminatedPids.remove(proc.processIdentifier) != nil

        // Verify worker generation identity
        guard proc == self.workerProcess || generation == self.currentWorkerGeneration else {
            return
        }

        workerProcess = nil
        workerStdinPipe = nil
        workerStdoutPipe = nil
        currentWorkerGeneration = nil
        receiveBuffer = ""

        pendingRequests.removeAll()

        if wasIntentional {
            if case .unavailable = self.state {
                // keep unavailable
            } else {
                self.state = .cold
            }
        } else {
            self.state = .failed(error: "Worker process terminated unexpectedly with code \(exitCode)")
            handleCurrentSessionFailure(.synthesisFailed(reason: "Worker process terminated (code \(exitCode))"))
        }
    }

    public func speak(
        text: String,
        deliveryMode: SovereignVoiceDeliveryMode = .conversational,
        for mission: SovereignMissionToken? = nil,
        onPlaybackStarted: (() -> Void)? = nil,
        onPlaybackCompleted: ((SovereignVoiceOutcome) -> Void)? = nil
    ) {
        guard isVoiceEnabled else {
            onPlaybackCompleted?(.unavailable(reason: "Voice disabled"))
            return
        }

        // Cancel active session, but retain an already-ready worker!
        stop()

        let chunks = SovereignSpeechSanitizer.chunk(text)
        guard !chunks.isEmpty else {
            onPlaybackCompleted?(.completed)
            return
        }

        let session = SovereignSpeechSession(
            missionToken: mission,
            deliveryMode: deliveryMode,
            orderedChunks: chunks,
            onStarted: onPlaybackStarted,
            onCompleted: onPlaybackCompleted
        )

        self.activeSession = session

        warmWorker()

        if case .unavailable = self.state {
            handleCurrentSessionFailure(.unavailable(reason: "Voice runtime unavailable"))
            return
        }

        // If worker is already ready, start synthesis immediately; otherwise ready handler will trigger it
        if state == .ready {
            startSynthesizingSession(session)
        }
    }

    public func testVoice(onPlaybackStarted: (() -> Void)? = nil, onPlaybackCompleted: ((SovereignVoiceOutcome) -> Void)? = nil) {
        let testText = "ATLAS Sovereign voice system online. All parameters operational."
        speak(text: testText, deliveryMode: .wakeup, for: nil, onPlaybackStarted: onPlaybackStarted, onPlaybackCompleted: onPlaybackCompleted)
    }

    private func startSynthesizingSession(_ session: SovereignSpeechSession) {
        guard activeSession?.id == session.id else { return }
        session.isSynthesisStarted = true

        // Request synthesis of Chunk 0
        synthesizeChunk(session: session, index: 0)
    }

    /// The model loads in ~1.4s, but the *first* generation after that pays a
    /// one-time ~8s Metal kernel compilation. Warming only loaded the weights, so
    /// that cost landed on the first BRIEF ME press. Spend it here instead, while
    /// the dashboard is just sitting open, and throw the audio away.
    private func primeInferenceKernels() {
        guard primingRequestId == nil, activeSession == nil else { return }
        let reqId = "prime-\(UUID().uuidString.prefix(6))"
        primingRequestId = reqId
        sendWorkerSynthesizeRequest(
            id: reqId,
            text: "Ready.",
            mode: .conversational,
            outputPath: cacheDirectory.appendingPathComponent("\(reqId).wav").path
        )
    }

    private func synthesizeChunk(session: SovereignSpeechSession, index: Int) {
        guard activeSession?.id == session.id else { return }
        guard index < session.orderedChunks.count else {
            session.isSynthesisComplete = true
            return
        }

        let chunkText = session.orderedChunks[index]
        let reqId = "chk-\(session.id.uuidString.prefix(6))-\(index)"
        let chunkPath = cacheDirectory.appendingPathComponent("\(reqId).wav").path

        pendingRequests[reqId] = (sessionId: session.id, chunkIndex: index, outputPath: chunkPath)
        self.state = .synthesizing(chunkId: reqId)

        sendWorkerSynthesizeRequest(id: reqId, text: chunkText, mode: session.deliveryMode, outputPath: chunkPath)
    }

    private func sendWorkerSynthesizeRequest(id: String, text: String, mode: SovereignVoiceDeliveryMode, outputPath: String) {
        guard let stdin = workerStdinPipe?.fileHandleForWriting else {
            handleWorkerOutputLine("{\"event\": \"error\", \"id\": \"\(id)\", \"error\": \"Worker stdin not connected\"}")
            return
        }

        let reqObj: [String: Any] = [
            "action": "synthesize",
            "id": id,
            "text": text,
            "mode": mode.rawValue,
            "output_path": outputPath,
            "max_tokens": 500
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: reqObj),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            let line = jsonStr + "\n"
            if let lineData = line.data(using: .utf8) {
                stdin.write(lineData)
            }
        }
    }

    private func handleChunkSynthesisSuccess(sessionId: UUID, chunkIndex: Int, wavPath: String) {
        guard let session = activeSession, session.id == sessionId else { return }

        // Mission safety check
        if let mission = session.missionToken, !SovereignPresenceStateManager.shared.isMissionActive(mission) {
            // Mission is stale: discard output, clean up activeSession, do NOT play!
            pendingRequests.removeAll()
            activeSession = nil
            if self.state != .cold && !self.state.isPlaying {
                self.state = .ready
            }
            return
        }

        session.synthesizedWavs[chunkIndex] = wavPath

        // Trigger synthesis of next chunk in background if available
        if chunkIndex + 1 < session.orderedChunks.count {
            synthesizeChunk(session: session, index: chunkIndex + 1)
        } else {
            session.isSynthesisComplete = true
        }

        // If this chunk is the next chunk waiting to play, start audio playback!
        if session.currentPlaybackIndex == chunkIndex && audioPlayer == nil {
            startPlayingChunk(session: session, chunkIndex: chunkIndex)
        }
    }

    private func handleChunkSynthesisFailure(sessionId: UUID, chunkIndex: Int, errorMsg: String) {
        guard let session = activeSession, session.id == sessionId else { return }

        if chunkIndex == 0 {
            // First chunk failed: release preparingSpeech state immediately!
            handleCurrentSessionFailure(.synthesisFailed(reason: errorMsg))
        } else {
            // Subsequent chunk failed: complete session with existing synthesized chunks
            session.isSynthesisComplete = true
            if session.currentPlaybackIndex >= session.synthesizedWavs.count {
                completeSession(session, outcome: .synthesisFailed(reason: errorMsg))
            }
        }
    }

    private func startPlayingChunk(session: SovereignSpeechSession, chunkIndex: Int) {
        guard activeSession?.id == session.id else { return }
        guard session.missionToken == nil || SovereignPresenceStateManager.shared.isMissionActive(session.missionToken) else {
            activeSession = nil
            self.state = .ready
            return
        }
        guard let wavPath = session.synthesizedWavs[chunkIndex], FileManager.default.fileExists(atPath: wavPath) else {
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: wavPath))
            player.delegate = self
            player.volume = outputVolume
            player.isMeteringEnabled = true

            self.audioPlayer = player
            self.state = .playing(chunkId: "chk-\(session.id.uuidString.prefix(6))-\(chunkIndex)")

            if let mission = session.missionToken {
                SovereignPresenceStateManager.shared.transition(to: .speaking, for: mission)
            } else {
                SovereignPresenceStateManager.shared.setRestingState(.speaking)
            }

            player.play()
            startEnergyMeteringTimer()

            if chunkIndex == 0 {
                session.onStarted?()
            }

        } catch {
            print("[SovereignVoice] Playback failed for chunk \(chunkIndex): \(error)")
            handleCurrentSessionFailure(.playbackFailed(reason: error.localizedDescription))
        }
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopEnergyMeteringTimer()
        audioPlayer = nil

        guard let session = activeSession else { return }

        guard flag else {
            completeSession(session, outcome: .playbackFailed(reason: "AVAudioPlayer reported unsuccessful playback"))
            return
        }

        session.currentPlaybackIndex += 1

        if let _ = session.synthesizedWavs[session.currentPlaybackIndex] {
            // Next chunk is ready, play immediately!
            startPlayingChunk(session: session, chunkIndex: session.currentPlaybackIndex)
        } else if session.currentPlaybackIndex < session.orderedChunks.count && !session.isSynthesisComplete {
            // Next chunk still synthesizing in background: wait without completing session!
            self.state = .synthesizing(chunkId: "chk-\(session.id.uuidString.prefix(6))-\(session.currentPlaybackIndex)")
        } else {
            // All chunks finished playing!
            completeSession(session, outcome: .completed)
        }
    }

    private func completeSession(_ session: SovereignSpeechSession, outcome: SovereignVoiceOutcome) {
        guard activeSession?.id == session.id else { return }

        session.isPlaybackComplete = true

        stopEnergyMeteringTimer()
        audioPlayer = nil

        if outcome.isSuccess {
            self.state = .ready
        } else {
            self.state = .failed(error: outcome.statusDescription)
        }

        if session.missionToken == nil {
            SovereignPresenceStateManager.shared.setRestingState(.idle)
        }

        activeSession = nil
        session.fireCompletion(outcome: outcome)
    }

    private func handleCurrentSessionFailure(_ outcome: SovereignVoiceOutcome) {
        guard let session = activeSession else {
            self.state = .failed(error: outcome.statusDescription)
            return
        }

        stopEnergyMeteringTimer()
        audioPlayer = nil

        self.state = .failed(error: outcome.statusDescription)

        if session.missionToken == nil {
            SovereignPresenceStateManager.shared.setRestingState(.idle)
        }

        activeSession = nil
        session.fireCompletion(outcome: outcome)
    }

    private func startEnergyMeteringTimer() {
        stopEnergyMeteringTimer()
        energyTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            self?.updateAudioEnergyFrame()
        }
    }

    private func stopEnergyMeteringTimer() {
        energyTimer?.invalidate()
        energyTimer = nil
        applyEnergyFrame(.zero)
    }

    /// Single write path for loudness: store it for the slow payload, then hand
    /// it to the fast channel. Never routed through @Published — see `currentEnergy`.
    func applyEnergyFrame(_ frame: AudioEnergyFrame) {
        self.currentEnergy = frame
        energyUpdates.send(frame)
    }

    private func updateAudioEnergyFrame() {
        guard let player = audioPlayer, player.isPlaying else {
            stopEnergyMeteringTimer()
            return
        }

        player.updateMeters()

        let avg = player.averagePower(forChannel: 0)
        let peak = player.peakPower(forChannel: 0)

        applyEnergyFrame(AudioEnergyCalculator.calculate(averagePower: avg, peakPower: peak))
    }

    public func stop() {
        stopEnergyMeteringTimer()

        if let player = audioPlayer, player.isPlaying {
            player.stop()
        }
        audioPlayer = nil

        // If synthesis is actively executing in worker, terminate process to cancel in-flight generation
        if !pendingRequests.isEmpty, let proc = workerProcess, proc.isRunning {
            intentionallyTerminatedPids.insert(proc.processIdentifier)
            proc.terminate()
            workerProcess = nil
            workerStdinPipe = nil
            workerStdoutPipe = nil
            currentWorkerGeneration = nil
            self.state = .cold
        }

        pendingRequests.removeAll()

        if let session = activeSession {
            session.fireCompletion(outcome: .cancelled)
            if session.missionToken == nil {
                SovereignPresenceStateManager.shared.setRestingState(.idle)
            }
            activeSession = nil
        }

        receiveBuffer = ""

        if case .unavailable = self.state {
            // keep unavailable
        } else if self.state != .cold {
            if workerProcess != nil && workerProcess!.isRunning {
                self.state = .ready
            } else {
                self.state = .cold
            }
        }
    }

    public func shutdownWorker() {
        stop()

        if let proc = workerProcess, proc.isRunning {
            intentionallyTerminatedPids.insert(proc.processIdentifier)
            proc.terminate()
            workerProcess = nil
            workerStdinPipe = nil
            workerStdoutPipe = nil
            currentWorkerGeneration = nil
        }

        if case .unavailable = self.state {
            // keep unavailable
        } else {
            self.state = .cold
        }
    }
}
