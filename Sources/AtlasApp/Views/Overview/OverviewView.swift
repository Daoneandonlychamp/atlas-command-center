import SwiftUI
import AtlasCore
import Luminare

struct OverviewView: View {
    @EnvironmentObject var appState: AtlasAppState

    @State private var pinnedProjectIds: Set<String> = []
    @State private var copiedCommandText: String? = nil

    private var pinnedProjects: [AtlasProject] {
        return appState.projects.filter { pinnedProjectIds.contains($0.id) }
    }

    private var dirtyProjectCount: Int {
        appState.projects.filter { $0.uncommittedChangesCount > 0 }.count
    }

    private var currentDateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        return formatter.string(from: Date())
    }
    
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 17 { return "Good afternoon" }
        return "Good evening"
    }

    private var calendarStatus: CalendarPermissionStatus {
        CalendarManager.shared.calendarAuthorizationStatus
    }

    private var reminderStatus: CalendarPermissionStatus {
        CalendarManager.shared.reminderAuthorizationStatus
    }

    private var hermesStatus: ServiceConnectionStatus? {
        appState.serviceStatuses.first(where: { $0.id == "hermes" })
    }

    private var railwayStatus: ServiceConnectionStatus? {
        appState.serviceStatuses.first(where: { $0.id == "railway" })
    }

    private var hermesAuthState: HermesAuthState {
        HermesConnector.shared.authState
    }

    private var requiresAttention: Bool {
        return calendarStatus != .authorized ||
               reminderStatus != .authorized ||
               !appState.pendingApprovals.isEmpty ||
               (hermesAuthState == .loginRequired || hermesAuthState == .authenticationExpired || hermesAuthState == .notConfigured) ||
               railwayStatus?.isOnline == false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AtlasTheme.Spacing.xxl) {
                // 1. Header: Greeting & Date & Refresh
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: AtlasTheme.Spacing.xs) {
                        Text(greeting)
                            .font(AtlasTheme.Typography.headline)
                            .foregroundColor(AtlasTheme.Colors.textSecondary)
                        Text("Daily Briefing")
                            .font(AtlasTheme.Typography.largeTitle)
                            .foregroundColor(AtlasTheme.Colors.textPrimary)
                        Text(currentDateString.uppercased())
                            .font(AtlasTheme.Typography.label)
                            .tracking(0.5)
                            .foregroundColor(AtlasTheme.Colors.champagneGold)
                    }
                    Spacer()

                    PremiumButton(appState.isRefreshing ? "Refreshing…" : "Refresh", icon: appState.isRefreshing ? nil : "arrow.clockwise", style: .secondary) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            triggerRefresh()
                        }
                    }
                    .disabled(appState.isRefreshing)
                }

                // 2. Metrics Summary Strip — tappable, color-coded, icon on right
                HStack(spacing: AtlasTheme.Spacing.lg) {
                    StatCard(
                        title: "Projects",
                        value: "\(appState.projects.count)",
                        icon: "folder.fill",
                        accent: AtlasTheme.Colors.champagneGold,
                        caption: dirtyProjectCount > 0 ? "\(dirtyProjectCount) with changes" : "All clean",
                        action: { appState.selectedSection = .projects }
                    )
                    StatCard(
                        title: "Notes",
                        value: "\(appState.recentNotes.count)",
                        icon: "doc.text.fill",
                        accent: AtlasTheme.Colors.info,
                        caption: "\(appState.vaults.count) vault\(appState.vaults.count == 1 ? "" : "s")",
                        action: { appState.selectedSection = .notes }
                    )
                    StatCard(
                        title: "Today's Events",
                        value: "\(appState.todayEvents.count)",
                        icon: "calendar",
                        accent: Color.cyan,
                        caption: appState.todayEvents.isEmpty ? "Day is clear" : "Scheduled",
                        action: { appState.selectedSection = .calendar }
                    )
                    StatCard(
                        title: "Pending",
                        value: "\(appState.pendingApprovals.count)",
                        icon: appState.pendingApprovals.isEmpty ? "checkmark.shield.fill" : "shield.trianglebadge.exclamationmark",
                        accent: appState.pendingApprovals.isEmpty ? AtlasTheme.Colors.success : AtlasTheme.Colors.warning,
                        caption: appState.pendingApprovals.isEmpty ? "Nothing to review" : "Needs approval",
                        action: { appState.selectedSection = .activity }
                    )
                }

                // 3. Conditional Attention Section
                if requiresAttention {
                    GlassCard(padding: AtlasTheme.Spacing.lg, cornerRadius: AtlasTheme.CornerRadius.lg, showBorder: true, hoverEffect: false, surface: AtlasTheme.Colors.cardSurface) {
                        VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                            HStack(spacing: AtlasTheme.Spacing.sm) {
                                GlowDot(color: AtlasTheme.Colors.warning, size: 8, glowRadius: 6)
                                Text("ATTENTION REQUIRED")
                                    .font(AtlasTheme.Typography.label)
                                    .tracking(1.5)
                                    .foregroundColor(AtlasTheme.Colors.warning)
                            }

                            // Pending Approvals Block
                            if !appState.pendingApprovals.isEmpty {
                                AttentionItemRow(
                                    icon: "shield.trianglebadge.exclamationmark",
                                    title: "\(appState.pendingApprovals.count) Pending Security Approval(s)",
                                    actionTitle: "Review Approvals →",
                                    action: { appState.selectedSection = .activity }
                                )
                            }

                            // Calendar Permission Block
                            if calendarStatus != .authorized {
                                AttentionItemRow(
                                    icon: "calendar.badge.exclamationmark",
                                    title: "Calendar Access Not Granted",
                                    actionTitle: "Request Access",
                                    action: requestCalendarAccess
                                )
                            }

                            // Reminders Permission Block
                            if reminderStatus != .authorized {
                                AttentionItemRow(
                                    icon: "checklist.unchecked",
                                    title: "Reminders Access Not Granted",
                                    actionTitle: "Request Access",
                                    action: requestReminderAccess
                                )
                            }

                            // Hermes Authentication Block
                            if hermesAuthState == .loginRequired || hermesAuthState == .authenticationExpired || hermesAuthState == .notConfigured {
                                GlassCard(padding: AtlasTheme.Spacing.md, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: false, hoverEffect: false, surface: AtlasTheme.Colors.surfaceDark) {
                                    HStack {
                                        Image(systemName: "key.fill")
                                            .foregroundColor(AtlasTheme.Colors.warning)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(hermesAuthState == .authenticationExpired ? "Hermes Session Expired" : "Hermes CLI Authentication Required")
                                                .font(AtlasTheme.Typography.callout)
                                                .foregroundColor(AtlasTheme.Colors.textPrimary)
                                            Text("Execute `hermes auth add nous` in Terminal to restore assistant capabilities.")
                                                .font(AtlasTheme.Typography.footnote)
                                                .foregroundColor(AtlasTheme.Colors.textSecondary)
                                        }
                                        Spacer()
                                        PremiumButton(copiedCommandText ?? "Copy Command", style: .primary) {
                                            copyHermesLoginCommand()
                                        }
                                    }
                                }
                            }

                            // Railway Cloud Block
                            if let railway = railwayStatus, !railway.isOnline {
                                AttentionItemRow(
                                    icon: "icloud.slash",
                                    title: "Railway Cloud Service Unreachable",
                                    actionTitle: "Retry Health Check",
                                    action: {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                            triggerRefresh()
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.lg, style: .continuous)
                            .stroke(AtlasTheme.Colors.warning.opacity(0.4), lineWidth: 1)
                    )
                }

                // 4. Grid Row 1: Today's Schedule & Reminders
                HStack(alignment: .top, spacing: AtlasTheme.Spacing.lg) {
                    // Today's Schedule
                    GlassCard(padding: AtlasTheme.Spacing.lg, cornerRadius: AtlasTheme.CornerRadius.lg, showBorder: true, hoverEffect: false, surface: AtlasTheme.Colors.cardSurface) {
                        VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                            SectionHeader(title: "TODAY'S SCHEDULE")
                            
                            if calendarStatus != .authorized {
                                PermissionDeniedCard(
                                    serviceName: "Calendar",
                                    settingsPath: "System Settings → Privacy & Security → Calendars",
                                    onRequest: requestCalendarAccess
                                )
                            } else if appState.todayEvents.isEmpty {
                                BriefingEmptyStateCard(title: "Your day is clear.", icon: "calendar", actionTitle: "New Event", actionIcon: "plus", action: { appState.selectedSection = .calendar })
                            } else {
                                ForEach(appState.todayEvents) { evt in
                                    GlassCard(padding: AtlasTheme.Spacing.md, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: false, hoverEffect: true, surface: AtlasTheme.Colors.surfaceDark) {
                                        HStack(spacing: AtlasTheme.Spacing.md) {
                                            AccentBar(color: AtlasTheme.Colors.champagneGold, width: 3, height: nil)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(evt.title)
                                                    .font(AtlasTheme.Typography.callout)
                                                    .foregroundColor(AtlasTheme.Colors.textPrimary)
                                                Text("\(formattedTime(evt.startDate)) - \(formattedTime(evt.endDate)) • \(evt.calendarName)")
                                                    .font(AtlasTheme.Typography.footnote)
                                                    .foregroundColor(AtlasTheme.Colors.textSecondary)
                                            }
                                            Spacer()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Reminders
                    GlassCard(padding: AtlasTheme.Spacing.lg, cornerRadius: AtlasTheme.CornerRadius.lg, showBorder: true, hoverEffect: false, surface: AtlasTheme.Colors.cardSurface) {
                        VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                            SectionHeader(title: "REMINDERS")

                            if reminderStatus != .authorized {
                                PermissionDeniedCard(
                                    serviceName: "Reminders",
                                    settingsPath: "System Settings → Privacy & Security → Reminders",
                                    onRequest: requestReminderAccess
                                )
                            } else if appState.overdueReminders.isEmpty {
                                BriefingEmptyStateCard(title: "No incomplete reminders.", icon: "checkmark.circle", actionTitle: "New Reminder", actionIcon: "plus", action: { appState.selectedSection = .calendar })
                            } else {
                                ForEach(appState.overdueReminders.prefix(5)) { task in
                                    GlassCard(padding: AtlasTheme.Spacing.md, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: false, hoverEffect: true, surface: AtlasTheme.Colors.surfaceDark) {
                                        HStack(spacing: AtlasTheme.Spacing.sm) {
                                            AccentBar(color: AtlasTheme.Colors.champagneMuted, width: 3, height: nil)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(task.title)
                                                    .font(AtlasTheme.Typography.callout)
                                                    .foregroundColor(AtlasTheme.Colors.textPrimary)
                                                Text("Category: \(task.category)")
                                                    .font(AtlasTheme.Typography.monoSmall)
                                                    .foregroundColor(AtlasTheme.Colors.textMuted)
                                            }
                                            Spacer()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                // 5. Grid Row 2: Pinned Projects & Recent Notes
                HStack(alignment: .top, spacing: AtlasTheme.Spacing.lg) {
                    // Pinned Projects
                    GlassCard(padding: AtlasTheme.Spacing.lg, cornerRadius: AtlasTheme.CornerRadius.lg, showBorder: true, hoverEffect: false, surface: AtlasTheme.Colors.cardSurface) {
                        VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                            SectionHeader(title: "PINNED PROJECTS", actionTitle: "All Projects →", action: { appState.selectedSection = .projects })
                            
                            if pinnedProjects.isEmpty {
                                GlassCard(padding: AtlasTheme.Spacing.lg, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: false, hoverEffect: false, surface: AtlasTheme.Colors.surfaceDark) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("No pinned projects yet. Pin active projects from Projects for quick access.")
                                            .font(AtlasTheme.Typography.caption)
                                            .foregroundColor(AtlasTheme.Colors.textSecondary)
                                        
                                        PremiumButton("Go to Projects to Pin", icon: "pin", style: .ghost) {
                                            appState.selectedSection = .projects
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                ForEach(pinnedProjects) { proj in
                                    Button(action: { selectProject(proj) }) {
                                        GlassCard(padding: AtlasTheme.Spacing.md, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: false, hoverEffect: true, surface: AtlasTheme.Colors.surfaceDark) {
                                            HStack {
                                                Image(systemName: "pin.fill")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(AtlasTheme.Colors.champagneGold)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(proj.name)
                                                        .font(AtlasTheme.Typography.callout)
                                                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                                                    Text("Branch: \(proj.gitBranch)")
                                                        .font(AtlasTheme.Typography.monoSmall)
                                                        .foregroundColor(AtlasTheme.Colors.textSecondary)
                                                }
                                                Spacer()
                                                Text(proj.gitStatus)
                                                    .font(AtlasTheme.Typography.caption)
                                                    .foregroundColor(proj.uncommittedChangesCount > 0 ? AtlasTheme.Colors.warning : AtlasTheme.Colors.success)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(AtlasTheme.Colors.surfaceDark)
                                                    .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Recent Notes
                    GlassCard(padding: AtlasTheme.Spacing.lg, cornerRadius: AtlasTheme.CornerRadius.lg, showBorder: true, hoverEffect: false, surface: AtlasTheme.Colors.cardSurface) {
                        VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                            SectionHeader(title: "RECENT NOTES", actionTitle: "All Notes →", action: { appState.selectedSection = .notes })

                            if appState.recentNotes.isEmpty {
                                BriefingEmptyStateCard(title: "No Markdown notes found in registered Obsidian vaults.", icon: "doc.text")
                            } else {
                                ForEach(appState.recentNotes.prefix(4)) { note in
                                    Button(action: { openObsidianNote(note) }) {
                                        GlassCard(padding: AtlasTheme.Spacing.md, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: false, hoverEffect: true, surface: AtlasTheme.Colors.surfaceDark) {
                                            HStack {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(note.title)
                                                        .font(AtlasTheme.Typography.callout)
                                                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                                                    Text("\(note.vaultName) • \(formattedRelativeDate(note.modifiedDate))")
                                                        .font(AtlasTheme.Typography.monoSmall)
                                                        .foregroundColor(AtlasTheme.Colors.textSecondary)
                                                }
                                                Spacer()

                                                HStack(spacing: 4) {
                                                    Image(systemName: "arrow.up.forward.app")
                                                    Text("Obsidian")
                                                }
                                                .font(.system(size: 10, weight: .semibold))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(AtlasTheme.Colors.surfaceDark)
                                                .foregroundColor(AtlasTheme.Colors.champagneGold)
                                                .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

            }
            .padding(AtlasTheme.Spacing.xxl)
        }
        .onAppear {
            loadPinnedProjectIds()
            if appState.projects.isEmpty {
                triggerRefresh()
            }
        }
    }

    private func triggerRefresh() {
        appState.refreshAllData {
            loadPinnedProjectIds()
        }
    }

    private func loadPinnedProjectIds() {
        if let data = UserDefaults.standard.data(forKey: "ATLAS_PINNED_PROJECTS"),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            pinnedProjectIds = ids
        } else {
            pinnedProjectIds = []
        }
    }

    private func selectProject(_ project: AtlasProject) {
        appState.selectedProject = project
        appState.selectedSection = .projects
    }

    private func openObsidianNote(_ note: AtlasNote) {
        let uri = "obsidian://open?vault=\(note.vaultName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&file=\(note.relativePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        _ = LocalCompanion.shared.openTarget(pathOrURI: uri)
    }

    private func copyHermesLoginCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("hermes auth add nous", forType: .string)
        copiedCommandText = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            copiedCommandText = nil
        }
    }

    private func requestCalendarAccess() {
        CalendarManager.shared.requestCalendarAccess { _ in
            triggerRefresh()
        }
    }

    private func requestReminderAccess() {
        CalendarManager.shared.requestReminderAccess { _ in
            triggerRefresh()
        }
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func formattedRelativeDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }
}

struct AttentionItemRow: View {
    let icon: String
    let title: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        GlassCard(padding: AtlasTheme.Spacing.md, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: false, hoverEffect: true, surface: AtlasTheme.Colors.surfaceDark) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(AtlasTheme.Colors.warning)
                Text(title)
                    .font(AtlasTheme.Typography.callout)
                    .foregroundColor(AtlasTheme.Colors.textPrimary)
                Spacer()
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(AtlasTheme.Colors.warning)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct PermissionDeniedCard: View {
    let serviceName: String
    let settingsPath: String
    let onRequest: () -> Void

    var body: some View {
        GlassCard(padding: AtlasTheme.Spacing.md, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: false, hoverEffect: false, surface: AtlasTheme.Colors.surfaceDark) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(AtlasTheme.Colors.warning)
                    Text("\(serviceName) Permission Not Granted")
                        .font(AtlasTheme.Typography.callout)
                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                }
                Text("To allow ATLAS to show your schedule, open macOS **\(settingsPath)**.")
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.textSecondary)

                PremiumButton("Request \(serviceName) Access", style: .secondary) {
                    onRequest()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BriefingEmptyStateCard: View {
    let title: String
    let icon: String
    var actionTitle: String? = nil
    var actionIcon: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        GlassCard(padding: AtlasTheme.Spacing.md, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: false, hoverEffect: false, surface: AtlasTheme.Colors.surfaceDark) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(AtlasTheme.Colors.textMuted)
                Text(title)
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.textMuted)
                Spacer()
                if let actionTitle, let action {
                    PremiumButton(actionTitle, icon: actionIcon, style: .ghost, action: action)
                }
            }
        }
    }
}

struct ServiceStatusChip: View {
    let name: String
    let isOnline: Bool
    let detail: String

    var body: some View {
        GlassCard(padding: AtlasTheme.Spacing.sm, cornerRadius: AtlasTheme.CornerRadius.sm, showBorder: true, hoverEffect: false, surface: AtlasTheme.Colors.cardSurface) {
            HStack(spacing: 8) {
                GlowDot(color: isOnline ? AtlasTheme.Colors.success : AtlasTheme.Colors.warning, size: 6, glowRadius: 4)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(AtlasTheme.Typography.callout)
                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                    Text(detail)
                        .font(AtlasTheme.Typography.caption)
                        .foregroundColor(AtlasTheme.Colors.textMuted)
                }
            }
        }
    }
}
