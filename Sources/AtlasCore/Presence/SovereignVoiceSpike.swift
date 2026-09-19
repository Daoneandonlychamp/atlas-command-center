import Foundation

public struct SovereignVoiceSampleResult: Codable {
    public let voiceId: String
    public let audioFilePath: String
    public let audioDurationSeconds: Double
    public let synthesisTimeMs: Double
    public let realTimeFactor: Double
    public let peakRamMB: Double
    public let isSuccess: Bool
    public let errorMessage: String?

    public init(
        voiceId: String,
        audioFilePath: String,
        audioDurationSeconds: Double,
        synthesisTimeMs: Double,
        realTimeFactor: Double,
        peakRamMB: Double,
        isSuccess: Bool,
        errorMessage: String? = nil
    ) {
        self.voiceId = voiceId
        self.audioFilePath = audioFilePath
        self.audioDurationSeconds = audioDurationSeconds
        self.synthesisTimeMs = synthesisTimeMs
        self.realTimeFactor = realTimeFactor
        self.peakRamMB = peakRamMB
        self.isSuccess = isSuccess
        self.errorMessage = errorMessage
    }
}

public final class SovereignVoiceSpike {
    public static let shared = SovereignVoiceSpike()

    public var ttsDirectoryPath: String {
        return NSString(string: "~/Library/Application Support/ATLAS/Models/tts").expandingTildeInPath
    }

    public var venvPythonPath: String {
        return (ttsDirectoryPath as NSString).appendingPathComponent("venv/bin/python3")
    }

    public var modelFilePath: String {
        return (ttsDirectoryPath as NSString).appendingPathComponent("kokoro-v1.0.onnx")
    }

    public var voicesFilePath: String {
        return (ttsDirectoryPath as NSString).appendingPathComponent("voices-v1.0.bin")
    }

    public var auditionScriptPath: String {
        return (ttsDirectoryPath as NSString).appendingPathComponent("audition.py")
    }

    public init() {}

    public var isRuntimeAvailable: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: venvPythonPath) &&
               fm.fileExists(atPath: modelFilePath) &&
               fm.fileExists(atPath: voicesFilePath) &&
               fm.fileExists(atPath: auditionScriptPath)
    }

    public func verifyModelLoading() -> Bool {
        guard isRuntimeAvailable else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: venvPythonPath)
        process.arguments = ["-c", "from kokoro_onnx import Kokoro; k = Kokoro('\(modelFilePath)', '\(voicesFilePath)'); print('OK')"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            // Drain before waiting, or a chatty child deadlocks the pair.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return process.terminationStatus == 0 && output.contains("OK")
        } catch {
            return false
        }
    }

    public func synthesizeSample(text: String, voiceId: String, outputWavPath: String) -> SovereignVoiceSampleResult {
        guard isRuntimeAvailable else {
            return SovereignVoiceSampleResult(
                voiceId: voiceId,
                audioFilePath: outputWavPath,
                audioDurationSeconds: 0,
                synthesisTimeMs: 0,
                realTimeFactor: 0,
                peakRamMB: 0,
                isSuccess: false,
                errorMessage: "Runtime or model missing at \(ttsDirectoryPath)"
            )
        }

        let escapedText = text.replacingOccurrences(of: "'", with: "\\'")
        let pyScript = """
import sys, time, psutil, soundfile as sf
from kokoro_onnx import Kokoro

t0 = time.time()
k = Kokoro('\(modelFilePath)', '\(voicesFilePath)')
samples, sr = k.create('\(escapedText)', voice='\(voiceId)', speed=1.0, lang='en-us')
t1 = time.time()

dur = len(samples) / float(sr)
synth_ms = (t1 - t0) * 1000.0
rtf = (t1 - t0) / dur if dur > 0 else 0.0
ram = psutil.Process().memory_info().rss / (1024 * 1024)

sf.write('\(outputWavPath)', samples, sr)
print(f"{dur:.3f}|{synth_ms:.2f}|{rtf:.4f}|{ram:.2f}|{sr}")
"""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: venvPythonPath)
        process.arguments = ["-c", pyScript]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: outputWavPath) {
                let parts = output.components(separatedBy: "|")
                if parts.count >= 5 {
                    return SovereignVoiceSampleResult(
                        voiceId: voiceId,
                        audioFilePath: outputWavPath,
                        audioDurationSeconds: Double(parts[0]) ?? 0,
                        synthesisTimeMs: Double(parts[1]) ?? 0,
                        realTimeFactor: Double(parts[2]) ?? 0,
                        peakRamMB: Double(parts[3]) ?? 0,
                        isSuccess: true,
                        errorMessage: nil
                    )
                }
            }

            return SovereignVoiceSampleResult(
                voiceId: voiceId,
                audioFilePath: outputWavPath,
                audioDurationSeconds: 0,
                synthesisTimeMs: 0,
                realTimeFactor: 0,
                peakRamMB: 0,
                isSuccess: false,
                errorMessage: "Synthesis failed with exit code \(process.terminationStatus): \(output)"
            )
        } catch {
            return SovereignVoiceSampleResult(
                voiceId: voiceId,
                audioFilePath: outputWavPath,
                audioDurationSeconds: 0,
                synthesisTimeMs: 0,
                realTimeFactor: 0,
                peakRamMB: 0,
                isSuccess: false,
                errorMessage: error.localizedDescription
            )
        }
    }
}
