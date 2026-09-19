import Foundation

/// Assembles the HUD snapshot from the services that already own each domain.
///
/// Refresh cadence is split on purpose: vitals move every second, cron and the
/// calendar move on the order of minutes, and a session rescan walks hundreds
/// of megabytes. Polling all three at the fastest rate would burn the battery
/// to redraw numbers that did not change.
public final class HUDFeed: ObservableObject {
    public static let shared = HUDFeed()

    @Published public private(set) var payload: HUDPayload?

    private let cron: CronService
    private let usage: ClaudeUsageReader
    private let sessions: ClaudeSessionScanner
    private let telemetry: SystemTelemetry
    private var lastSlowRefresh = Date.distantPast
    private var lastSessionScan = Date.distantPast

    /// Seconds between cron/calendar reads and between full session rescans.
    private let slowInterval: TimeInterval = 60
    private let sessionInterval: TimeInterval = 600

    /// Checked once: the runtime either shipped with the machine or it did not.
    private lazy var voiceIsInstalled: Bool = {
        let fm = FileManager.default
        let python = SovereignVoiceService.shared.pythonRuntimePath
        let model = SovereignVoiceService.shared.modelSnapshotPath
        return fm.fileExists(atPath: python) && fm.fileExists(atPath: model)
    }()

    public init(
        cron: CronService = .shared,
        usage: ClaudeUsageReader = .shared,
        sessions: ClaudeSessionScanner = .shared,
        telemetry: SystemTelemetry = .shared
    ) {
        self.cron = cron
        self.usage = usage
        self.sessions = sessions
        self.telemetry = telemetry
    }

    /// Called on the HUD's own timer. Vitals are resampled every tick; the
    /// slower sources refresh only when their interval has elapsed.
    public func tick(events: [AtlasCalendarEvent], overdueTasks: Int,
                     calendarAuthorized: Bool, remindersAuthorized: Bool,
                     projects: [AtlasProject], notes: [AtlasNote],
                     pendingApprovals: Int, services: [ServiceConnectionStatus],
                     loaded: Bool) {
        let now = Date()
        if now.timeIntervalSince(lastSlowRefresh) >= slowInterval {
            lastSlowRefresh = now
            cron.refresh()
        }
        if now.timeIntervalSince(lastSessionScan) >= sessionInterval {
            lastSessionScan = now
            sessions.refresh()
        }

        usage.refresh()
        AgentPresence.shared.refreshIfNeeded()
        payload = build(events: events, overdueTasks: overdueTasks,
                        calendarAuthorized: calendarAuthorized, remindersAuthorized: remindersAuthorized,
                        projects: projects, notes: notes,
                        pendingApprovals: pendingApprovals, services: services, loaded: loaded)
    }

    /// Forces every source to reload, for the HUD's manual refresh.
    public func reloadAll() {
        lastSlowRefresh = .distantPast
        lastSessionScan = .distantPast
    }

    private func build(events: [AtlasCalendarEvent], overdueTasks: Int,
                       calendarAuthorized: Bool, remindersAuthorized: Bool,
                       projects: [AtlasProject], notes: [AtlasNote],
                       pendingApprovals: Int, services: [ServiceConnectionStatus],
                       loaded: Bool) -> HUDPayload {
        let jobs = cron.jobs.map { job in
            HUDPayload.Job(
                name: job.name,
                schedule: job.scheduleDisplay,
                health: healthName(job.health),
                failureStreak: job.failureStreak,
                nextRunEpoch: job.nextRunAt?.timeIntervalSince1970,
                lastRunEpoch: job.lastRunAt?.timeIntervalSince1970,
                recentStatuses: Array((cron.runs[job.id]?.recentStatuses ?? []).prefix(20)),
                activeIncidents: cron.activeIncidents(for: job).count
            )
        }

        let series = sessions.dailySeries
        let models = sessions.messagesByModel
            .map { HUDPayload.ModelUse(model: $0.key, messages: $0.value, cost: sessions.costByModel[$0.key] ?? 0) }
            .sorted { $0.cost > $1.cost }

        let currentAudio = SovereignVoiceService.shared.currentEnergy

        return HUDPayload(
            generatedEpoch: Date().timeIntervalSince1970,
            voiceAvailable: voiceIsInstalled,
            voiceState: SovereignVoiceService.shared.state.uiState,
            voiceDetail: SovereignVoiceService.shared.state.statusDescription,
            sovereignState: SovereignPresenceStateManager.shared.currentState.rawValue,
            fieldWorld: AgentPresence.shared.world,
            voiceEnergy: currentAudio.rmsLoudness,
            audioEnergy: HUDPayload.AudioEnergy(
                rms: currentAudio.rmsLoudness,
                bass: currentAudio.bassEnergy,
                mid: currentAudio.midEnergy,
                treble: currentAudio.trebleEnergy
            ),
            vitals: telemetry.sample(),
            cron: HUDPayload.Cron(
                jobs: jobs,
                healthy: cron.healthyCount,
                failing: cron.failingCount,
                activeIncidents: cron.activeIncidents.count,
                loggedIncidents: cron.loggedIncidents.count
            ),
            sessions: HUDPayload.Sessions(
                totalCost: sessions.totalCost,
                todayCost: sessions.todayCost,
                transcripts: sessions.sessionCount,
                inputTokens: sessions.tokens.input,
                cacheWriteTokens: sessions.tokens.cacheWrite,
                cacheReadTokens: sessions.tokens.cacheRead,
                outputTokens: sessions.tokens.output,
                dailyCosts: series.map(\.cost),
                dailyLabels: series.map(\.day),
                byModel: models,
                unpricedModels: sessions.unpricedModels,
                isScanning: sessions.isScanning
            ),
            brief: HUDPayload.Brief(
                greeting: Self.greeting(for: Date()),
                dateLine: Self.dateLine.string(from: Date()).uppercased(),
                events: events.map {
                    // EventKit's all-day flag is not carried on AtlasCalendarEvent,
                    // so infer it from the span rather than print "12:00 AM".
                    HUDPayload.Event(
                        title: $0.title,
                        startEpoch: $0.startDate.timeIntervalSince1970,
                        isAllDay: $0.endDate.timeIntervalSince($0.startDate) >= 23 * 3600
                    )
                },
                overdueTasks: overdueTasks,
                calendarAuthorized: calendarAuthorized,
                remindersAuthorized: remindersAuthorized
            ),
            workspace: HUDPayload.Workspace(
                loaded: loaded,
                // Busiest repositories first — a project with uncommitted work
                // is the one worth surfacing on a dashboard.
                projects: projects
                    .sorted { ($0.uncommittedChangesCount, $0.lastModified) > ($1.uncommittedChangesCount, $1.lastModified) }
                    .prefix(6)
                    .map {
                        HUDPayload.Project(
                            name: $0.name,
                            branch: $0.gitBranch,
                            uncommitted: $0.uncommittedChangesCount,
                            type: $0.projectType.rawValue
                        )
                    },
                projectCount: projects.count,
                noteCount: notes.count,
                notes: notes.prefix(4).map {
                    HUDPayload.Note(title: $0.title, vault: $0.vaultName,
                                    modifiedEpoch: $0.modifiedDate.timeIntervalSince1970)
                },
                pendingApprovals: pendingApprovals,
                services: services.map {
                    HUDPayload.Service(name: $0.name, state: $0.state.rawValue)
                }
            ),
            usage: {
                let snap = usage.snapshot
                return HUDPayload.Usage(
                    configured: usage.isConfigured,
                    stale: snap?.isStale ?? true,
                    ageSeconds: snap?.age ?? 0,
                    fiveHourPercent: snap?.fiveHour?.usedPercentage,
                    fiveHourResetsInSeconds: snap?.fiveHour?.timeUntilReset,
                    sevenDayPercent: snap?.sevenDay?.usedPercentage,
                    sevenDayResetsInSeconds: snap?.sevenDay?.timeUntilReset,
                    contextPercent: snap?.contextPercentage,
                    sessionCostUSD: snap?.sessionCostUSD,
                    modelName: snap?.modelName
                )
            }()
        )
    }

    private func healthName(_ health: CronJob.Health) -> String {
        switch health {
        case .healthy: return "healthy"
        case .failing: return "failing"
        case .paused:  return "paused"
        case .unknown: return "unknown"
        }
    }

    static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 0..<5:   return "Good night"
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        default:      return "Good evening"
        }
    }

    /// Short form: the top bar is a status strip, not a letterhead.
    static let dateLine: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()
}
