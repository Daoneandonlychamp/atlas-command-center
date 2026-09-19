import Foundation

/// Everything the HUD page draws, in one JSON snapshot.
///
/// The page is deliberately dumb: it renders whatever this hands it and owns
/// no data logic of its own. Every number traces back to a file on this
/// machine, so the HUD can be dense without inventing a single reading.
public struct HUDPayload: Codable {
    public struct Job: Codable {
        public let name: String
        public let schedule: String
        public let health: String
        public let failureStreak: Int
        public let nextRunEpoch: Double?
        public let lastRunEpoch: Double?
        public let recentStatuses: [String]
        public let activeIncidents: Int
    }

    public struct Event: Codable {
        public let title: String
        public let startEpoch: Double
        public let isAllDay: Bool
    }

    public struct ModelUse: Codable {
        public let model: String
        public let messages: Int
        public let cost: Double
    }

    public struct Sessions: Codable {
        public let totalCost: Double
        public let todayCost: Double
        public let transcripts: Int
        public let inputTokens: Int
        public let cacheWriteTokens: Int
        public let cacheReadTokens: Int
        public let outputTokens: Int
        public let dailyCosts: [Double]
        public let dailyLabels: [String]
        public let byModel: [ModelUse]
        public let unpricedModels: [String: Int]
        public let isScanning: Bool
    }

    public struct Usage: Codable {
        public let configured: Bool
        public let stale: Bool
        public let ageSeconds: Double
        public let fiveHourPercent: Double?
        public let fiveHourResetsInSeconds: Double?
        public let sevenDayPercent: Double?
        public let sevenDayResetsInSeconds: Double?
        public let contextPercent: Double?
        public let sessionCostUSD: Double?
        public let modelName: String?
    }

    public struct Cron: Codable {
        public let jobs: [Job]
        public let healthy: Int
        public let failing: Int
        public let activeIncidents: Int
        public let loggedIncidents: Int
    }

    public struct Project: Codable {
        public let name: String
        public let branch: String
        public let uncommitted: Int
        public let type: String
    }

    public struct Note: Codable {
        public let title: String
        public let vault: String
        public let modifiedEpoch: Double
    }

    public struct Workspace: Codable {
        /// False while the first scan is still running.
        public let loaded: Bool
        public let projects: [Project]
        public let projectCount: Int
        public let noteCount: Int
        public let notes: [Note]
        public let pendingApprovals: Int
        public let services: [Service]
    }

    public struct Service: Codable {
        public let name: String
        public let state: String
    }

    public struct Brief: Codable {
        public let greeting: String
        public let dateLine: String
        public let events: [Event]
        public let overdueTasks: Int
        public let calendarAuthorized: Bool
        public let remindersAuthorized: Bool
    }

    public struct AudioEnergy: Codable {
        public let rms: Double
        public let bass: Double
        public let mid: Double
        public let treble: Double
    }

    public let generatedEpoch: Double
    /// Whether the local TTS runtime is actually installed — the HUD should not
    /// offer a speak button that can only fail.
    public let voiceAvailable: Bool
    /// cold / warming / ready / synthesizing / speaking / failed / unavailable
    public let voiceState: String
    public let voiceDetail: String
    /// SovereignState enum rawValue ("idle", "processing", "speaking", "executing", etc.)
    public let sovereignState: String
    /// 0 Aethera · 1 Pyra · 2 Orison · 3 Vesper — which world the field shows.
    public let fieldWorld: Int
    /// Live playback loudness, 0-1. Surges the particle field while speaking.
    public let voiceEnergy: Double
    /// Live 4-channel audio energy breakdown
    public let audioEnergy: AudioEnergy
    public let vitals: SystemVitals
    public let cron: Cron
    public let sessions: Sessions
    public let brief: Brief
    public let workspace: Workspace
    public let usage: Usage

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
