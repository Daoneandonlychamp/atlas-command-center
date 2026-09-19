import SwiftUI
import AtlasCore
import Luminare

struct AutomationsView: View {
    @EnvironmentObject var appState: AtlasAppState
    @ObservedObject var emergencyStop = EmergencyStopManager.shared
    @StateObject private var cron = CronService.shared
    @State private var isPulsing = false

    private var registeredTools: [StructuredToolDefinition] {
        LocalCompanion.shared.getRegisteredTools()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AtlasTheme.Spacing.xl) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Automations & Privileged Companion")
                            .font(AtlasTheme.Typography.title)
                            .foregroundColor(AtlasTheme.Colors.textPrimary)
                        Text(subtitle)
                            .font(AtlasTheme.Typography.body)
                            .foregroundColor(AtlasTheme.Colors.textSecondary)
                    }
                    Spacer()

                    Button(action: {
                        if emergencyStop.isEmergencyStopActive {
                            emergencyStop.resetEmergencyStop()
                        } else {
                            emergencyStop.triggerEmergencyStop()
                        }
                        appState.refreshAllData()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: emergencyStop.isEmergencyStopActive ? "play.circle.fill" : "stop.circle.fill")
                            Text(emergencyStop.isEmergencyStopActive ? "Reset Emergency Stop" : "Emergency Stop")
                        }
                        .font(AtlasTheme.Typography.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(emergencyStop.isEmergencyStopActive ? AtlasTheme.Colors.success : AtlasTheme.Colors.error)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
                        .shadow(color: emergencyStop.isEmergencyStopActive ? .clear : AtlasTheme.Colors.error.opacity(isPulsing ? 0.6 : 0.2), radius: isPulsing ? 12 : 4)
                        .animation(emergencyStop.isEmergencyStopActive ? .default : .easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        isPulsing = true
                    }
                }

                if emergencyStop.isEmergencyStopActive {
                    GlassCard(padding: AtlasTheme.Spacing.md, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: true, hoverEffect: false, surface: AtlasTheme.Colors.surfaceDark) {
                        HStack {
                            Image(systemName: "exclamationmark.octagon.fill")
                                .foregroundColor(AtlasTheme.Colors.error)
                            Text("EMERGENCY STOP IS ACTIVE. All local tools & agent executions are blocked.")
                                .font(AtlasTheme.Typography.callout)
                                .foregroundColor(AtlasTheme.Colors.error)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous)
                            .stroke(AtlasTheme.Colors.error.opacity(0.4), lineWidth: 1)
                    )
                }

                CronJobsSection(cron: cron)

                // Permitted Scopes
                VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                    SectionHeader(title: "PERMITTED WORKSPACE SCOPES")

                    LuminareSection(hasPadding: false) {
                        ForEach(LocalCompanion.shared.allowedScopes, id: \.self) { scope in
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(AtlasTheme.Colors.champagneGold)
                                Text(scope)
                                    .font(AtlasTheme.Typography.mono)
                                    .foregroundColor(AtlasTheme.Colors.textPrimary)
                                Spacer()
                                Text("Permitted Scope")
                                    .font(AtlasTheme.Typography.caption)
                                    .foregroundColor(AtlasTheme.Colors.success)
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                        }
                    }
                }

                // Tools Table
                VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                    SectionHeader(title: "REGISTERED STRUCTURED TOOLS & SECURITY TIERS")

                    LuminareSection(hasPadding: false) {
                        ForEach(LocalCompanion.shared.getRegisteredTools(), id: \.id) { (tool: StructuredToolDefinition) in
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous)
                                        .fill(AtlasTheme.Colors.surfaceDark)
                                        .frame(width: 32, height: 32)
                                    Image(systemName: "wrench.and.screwdriver.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(AtlasTheme.Colors.champagneGold)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.name)
                                        .font(AtlasTheme.Typography.mono)
                                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                                    Text(tool.description)
                                        .font(AtlasTheme.Typography.caption)
                                        .foregroundColor(AtlasTheme.Colors.textSecondary)
                                }

                                Spacer()

                                Text(tool.riskTier.rawValue)
                                    .font(AtlasTheme.Typography.label)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(hex: tool.riskTier.badgeColorHex).opacity(0.2))
                                    .foregroundColor(Color(hex: tool.riskTier.badgeColorHex))
                                    .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 52)
                        }
                    }
                }
            }
            .padding(AtlasTheme.Spacing.xl)
        }
        .onAppear { cron.refresh() }
    }

    /// Counts, not adjectives — the page should say what is actually there.
    private var subtitle: String {
        let tools = registeredTools.count
        let jobs = cron.jobs.count
        let failing = cron.failingCount
        var text = "\(jobs) scheduled job\(jobs == 1 ? "" : "s") · \(tools) local structured tool\(tools == 1 ? "" : "s")"
        if failing > 0 { text += " · \(failing) failing" }
        return text
    }
}
