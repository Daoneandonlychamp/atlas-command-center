import SwiftUI
import AtlasCore
import Luminare

/// The scheduled side of Automations: what Hermes runs on a timer, whether it
/// last worked, and what is currently broken.
struct CronJobsSection: View {
    @ObservedObject var cron: CronService

    var body: some View {
        VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
            SectionHeader(title: "SCHEDULED JOBS · HERMES SOVEREIGN")

            if let error = cron.lastError {
                GlassCard(padding: AtlasTheme.Spacing.md, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: true, hoverEffect: false, surface: AtlasTheme.Colors.surfaceDark) {
                    HStack(spacing: AtlasTheme.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(AtlasTheme.Colors.warning)
                        Text(error)
                            .font(AtlasTheme.Typography.callout)
                            .foregroundColor(AtlasTheme.Colors.textSecondary)
                        Spacer()
                    }
                }
            } else if cron.jobs.isEmpty {
                GlassCard(padding: AtlasTheme.Spacing.xxl, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: true, hoverEffect: false, surface: AtlasTheme.Colors.cardSurface) {
                    VStack(spacing: AtlasTheme.Spacing.sm) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.system(size: 28, weight: .light))
                            .foregroundColor(AtlasTheme.Colors.textSubtle)
                        Text("No scheduled jobs registered")
                            .font(AtlasTheme.Typography.callout)
                            .foregroundColor(AtlasTheme.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                summaryRow
                LuminareSection(hasPadding: false) {
                    ForEach(cron.jobs) { job in
                        CronJobRow(job: job, runs: cron.runs[job.id], activeIncidents: cron.activeIncidents(for: job).count)
                    }
                }
            }

            if !cron.loggedIncidents.isEmpty {
                SectionHeader(title: "CRON INCIDENT LOG")
                Text("Hermes records incidents but never closes them. Rows dimmed below are older than the job's last successful run.")
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.textMuted)
                LuminareSection(hasPadding: false) {
                    ForEach(cron.loggedIncidents) { incident in
                        CronIncidentRow(
                            incident: incident,
                            jobName: name(for: incident.jobId),
                            isStale: !activeIds.contains(incident.id)
                        )
                    }
                }
            }
        }
    }

    private var activeIds: Set<String> { Set(cron.activeIncidents.map(\.id)) }

    private func name(for jobId: String) -> String {
        cron.jobs.first { $0.id == jobId }?.name ?? jobId
    }

    private var summaryRow: some View {
        HStack(spacing: AtlasTheme.Spacing.sm) {
            CronStatChip(value: cron.jobs.count, label: "SCHEDULED", color: AtlasTheme.Colors.champagneGold)
            CronStatChip(value: cron.healthyCount, label: "HEALTHY", color: AtlasTheme.Colors.success)
            CronStatChip(value: cron.failingCount, label: "FAILING", color: AtlasTheme.Colors.error)
            CronStatChip(value: cron.activeIncidents.count, label: "ACTIVE INCIDENTS", color: AtlasTheme.Colors.warning)
            Spacer()
        }
    }
}

private struct CronStatChip: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: AtlasTheme.Spacing.sm) {
            Text("\(value)")
                .font(AtlasTheme.Typography.numericSmall)
                .foregroundColor(value == 0 ? AtlasTheme.Colors.textMuted : color)
            Text(label)
                .font(AtlasTheme.Typography.label)
                .foregroundColor(AtlasTheme.Colors.textMuted)
                .tracking(1.2)
        }
        .padding(.horizontal, AtlasTheme.Spacing.md)
        .padding(.vertical, AtlasTheme.Spacing.sm)
        .background(AtlasTheme.Colors.surfaceDark)
        .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
    }
}

private struct CronJobRow: View {
    let job: CronJob
    let runs: CronRunSummary?
    let activeIncidents: Int

    var body: some View {
        HStack(spacing: AtlasTheme.Spacing.md) {
            GlowDot(color: healthColor)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: AtlasTheme.Spacing.sm) {
                    Text(job.name)
                        .font(AtlasTheme.Typography.mono)
                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                    if job.failureStreak > 0 {
                        Text("\(job.failureStreak)× IN A ROW")
                            .font(AtlasTheme.Typography.label)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(AtlasTheme.Colors.error.opacity(0.2))
                            .foregroundColor(AtlasTheme.Colors.error)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    if activeIncidents > 0 {
                        Text("\(activeIncidents) INCIDENT\(activeIncidents == 1 ? "" : "S")")
                            .font(AtlasTheme.Typography.label)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(AtlasTheme.Colors.warning.opacity(0.2))
                            .foregroundColor(AtlasTheme.Colors.warning)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }

                HStack(spacing: AtlasTheme.Spacing.sm) {
                    Text(job.scheduleDisplay)
                        .font(AtlasTheme.Typography.monoSmall)
                        .foregroundColor(AtlasTheme.Colors.champagneLight)
                    Text(subtitle)
                        .font(AtlasTheme.Typography.caption)
                        .foregroundColor(AtlasTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let runs, runs.total > 0 {
                RunStrip(statuses: runs.recentStatuses)
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text(nextRunText)
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.textSecondary)
                Text(job.model ?? job.deliver ?? "")
                    .font(AtlasTheme.Typography.footnote)
                    .foregroundColor(AtlasTheme.Colors.textMuted)
            }
            .frame(minWidth: 120, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 56)
    }

    private var healthColor: Color {
        switch job.health {
        case .healthy: return AtlasTheme.Colors.success
        case .failing: return AtlasTheme.Colors.error
        case .paused:  return AtlasTheme.Colors.textMuted
        case .unknown: return AtlasTheme.Colors.warning
        }
    }

    /// The most useful thing to say about a job is why it is unhealthy, so an
    /// error wins over the last-run time when there is one.
    private var subtitle: String {
        if job.health == .paused { return job.enabled ? "paused" : "disabled" }
        if let error = job.lastError, !error.isEmpty { return error }
        guard let last = job.lastRunAt else { return "never run" }
        return "ran \(Self.relative.localizedString(for: last, relativeTo: Date()))"
    }

    private var nextRunText: String {
        guard job.health != .paused else { return "—" }
        guard let next = job.nextRunAt else { return "not scheduled" }
        return "next \(Self.relative.localizedString(for: next, relativeTo: Date()))"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// Newest run on the right, so the strip reads left-to-right like time does.
private struct RunStrip: View {
    let statuses: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(statuses.prefix(12).reversed().enumerated()), id: \.offset) { _, status in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color(for: status))
                    .frame(width: 4, height: 16)
            }
        }
        .help("Last \(min(statuses.count, 12)) runs, oldest first")
    }

    private func color(for status: String) -> Color {
        switch status {
        case "completed": return AtlasTheme.Colors.success.opacity(0.8)
        case "failed":    return AtlasTheme.Colors.error.opacity(0.85)
        case "running", "claimed": return AtlasTheme.Colors.info.opacity(0.8)
        default:          return AtlasTheme.Colors.textSubtle
        }
    }
}

private struct CronIncidentRow: View {
    let incident: CronIncident
    let jobName: String
    let isStale: Bool

    var body: some View {
        HStack(spacing: AtlasTheme.Spacing.md) {
            Image(systemName: isStale ? "clock.arrow.circlepath" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(isStale ? AtlasTheme.Colors.textSubtle : AtlasTheme.Colors.warning)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AtlasTheme.Spacing.sm) {
                    Text(jobName)
                        .font(AtlasTheme.Typography.mono)
                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                    Text(incident.failureType.uppercased())
                        .font(AtlasTheme.Typography.label)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(AtlasTheme.Colors.surfaceDark)
                        .foregroundColor(AtlasTheme.Colors.textSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Text(incident.error)
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            if let seen = incident.lastSeenAt {
                Text(Self.relative.localizedString(for: seen, relativeTo: Date()))
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.textMuted)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .opacity(isStale ? 0.45 : 1)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
