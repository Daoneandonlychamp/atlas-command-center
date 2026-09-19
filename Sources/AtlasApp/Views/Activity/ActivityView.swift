import SwiftUI
import AtlasCore
import Luminare

struct ActivityView: View {
    @EnvironmentObject var appState: AtlasAppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AtlasTheme.Spacing.xl) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Activity Ledger & Approval Center")
                            .font(AtlasTheme.Typography.title)
                            .foregroundColor(AtlasTheme.Colors.textPrimary)
                        Text("Append-only audit history of agent actions & security confirmation gates")
                            .font(AtlasTheme.Typography.body)
                            .foregroundColor(AtlasTheme.Colors.textSecondary)
                    }
                    Spacer()
                }

                // Section 1: Pending Approval Center
                if !appState.pendingApprovals.isEmpty {
                    VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                        HStack {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundColor(AtlasTheme.Colors.warning)
                            SectionHeader(title: "PENDING APPROVAL REQUESTS (\(appState.pendingApprovals.count))")
                            Spacer()
                        }

                        ForEach(appState.pendingApprovals) { req in
                            GlassCard(padding: AtlasTheme.Spacing.lg, cornerRadius: AtlasTheme.CornerRadius.lg, showBorder: true, hoverEffect: false, surface: AtlasTheme.Colors.cardSurface) {
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(req.title)
                                                .font(AtlasTheme.Typography.headline)
                                                .foregroundColor(AtlasTheme.Colors.textPrimary)
                                            Text(req.riskTier.rawValue)
                                                .font(AtlasTheme.Typography.label)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(
                                                    LinearGradient(colors: [AtlasTheme.Colors.warning.opacity(0.3), AtlasTheme.Colors.error.opacity(0.1)], startPoint: .leading, endPoint: .trailing)
                                                )
                                                .foregroundColor(AtlasTheme.Colors.warning)
                                                .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
                                        }
                                        Text(req.details)
                                            .font(AtlasTheme.Typography.body)
                                            .foregroundColor(AtlasTheme.Colors.textSecondary)
                                        Text("Requested by: \(req.requestedBy) • \(formattedDate(req.timestamp))")
                                            .font(AtlasTheme.Typography.monoSmall)
                                            .foregroundColor(AtlasTheme.Colors.textMuted)
                                    }

                                    Spacer()

                                    HStack(spacing: 8) {
                                        PremiumButton("Approve & Execute", style: .primary) {
                                            _ = ActivityLedger.shared.executeApproval(id: req.id)
                                            appState.refreshAllData()
                                        }
                                        PremiumButton("Reject", style: .destructive) {
                                            ActivityLedger.shared.rejectApproval(id: req.id)
                                            appState.refreshAllData()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Section 2: Complete Activity History
                VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                    SectionHeader(title: "APPEND-ONLY ACTIVITY AUDIT LEDGER")

                    if appState.activities.isEmpty {
                        Text("No activity recorded yet.")
                            .font(AtlasTheme.Typography.body)
                            .foregroundColor(AtlasTheme.Colors.textMuted)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(appState.activities.indices, id: \.self) { index in
                                let act = appState.activities[index]
                                HStack(alignment: .top, spacing: 16) {
                                    // Timeline Connector
                                    VStack(spacing: 0) {
                                        Circle()
                                            .fill(AtlasTheme.Colors.champagneGold)
                                            .frame(width: 8, height: 8)
                                            .padding(.top, 8)
                                        if index != appState.activities.count - 1 {
                                            Rectangle()
                                                .fill(AtlasTheme.Colors.borderSubtle)
                                                .frame(width: 2)
                                        }
                                    }

                                    GlassCard(padding: AtlasTheme.Spacing.md, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: true, hoverEffect: true, surface: AtlasTheme.Colors.cardSurface) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text(formattedDate(act.timestamp))
                                                    .font(AtlasTheme.Typography.monoSmall)
                                                    .foregroundColor(AtlasTheme.Colors.textMuted)
                                                Text(act.initiator)
                                                    .font(AtlasTheme.Typography.callout)
                                                    .foregroundColor(AtlasTheme.Colors.champagneGold)
                                                Text(act.toolName)
                                                    .font(AtlasTheme.Typography.mono)
                                                    .foregroundColor(AtlasTheme.Colors.textPrimary)

                                                Spacer()

                                                Text(act.riskTier.rawValue)
                                                    .font(AtlasTheme.Typography.label)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(AtlasTheme.Colors.surfaceDark)
                                                    .foregroundColor(AtlasTheme.Colors.textSecondary)
                                                    .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
                                            }

                                            Text(act.actionDescription)
                                                .font(AtlasTheme.Typography.body)
                                                .foregroundColor(AtlasTheme.Colors.textSecondary)

                                            HStack {
                                                Text("Target: \(act.target)")
                                                    .font(AtlasTheme.Typography.monoSmall)
                                                    .foregroundColor(AtlasTheme.Colors.textMuted)
                                                Spacer()
                                                Text("Result: \(act.result) (\(String(format: "%.2fs", act.durationSeconds)))")
                                                    .font(AtlasTheme.Typography.monoSmall)
                                                    .foregroundColor(act.result == "Success" ? AtlasTheme.Colors.success : AtlasTheme.Colors.warning)
                                            }
                                        }
                                    }
                                    .padding(.bottom, AtlasTheme.Spacing.md)
                                }
                            }
                        }
                    }
                }
            }
            .padding(AtlasTheme.Spacing.xl)
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
