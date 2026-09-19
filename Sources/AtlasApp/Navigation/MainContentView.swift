import SwiftUI
import AtlasCore

struct MainContentView: View {
    @EnvironmentObject var appState: AtlasAppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            ZStack {
                AtlasBackdrop()

                switch appState.selectedSection {
                case .overview:
                    HUDView()
                case .assistant:
                    // The HTML Assistant is opt-in until it has been driven
                    // in anger: ATLAS_ASSISTANT_HTML=1 picks it, anything else
                    // keeps the SwiftUI page that has been working all along.
                    if ProcessInfo.processInfo.environment["ATLAS_ASSISTANT_HTML"] == "1" {
                        AssistantPage()
                    } else {
                        AssistantView()
                    }
                case .projects:
                    ProjectsView()
                case .notes:
                    NotesView()
                case .business:
                    BusinessView()
                case .calendar:
                    CalendarView()
                case .board:
                    KanbanView()
                case .journal:
                    JournalView()
                case .canvas:
                    CanvasView()
                case .finances:
                    FinancesView()
                case .cinema:
                    CinemaView()
                case .automations:
                    AutomationsView()
                case .connections:
                    ConnectionsView()
                case .activity:
                    ActivityView()
                case .settings:
                    SettingsView()
                }

                if appState.isCommandPaletteOpen {
                    GlobalCommandPaletteView()
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        appState.isCommandPaletteOpen.toggle()
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AtlasTheme.Colors.champagneGold)
                        Text("Search & Actions")
                            .font(AtlasTheme.Typography.caption)
                            .foregroundColor(AtlasTheme.Colors.textSecondary)
                        Spacer(minLength: 16)
                        Text("⌘K")
                            .font(AtlasTheme.Typography.monoSmall)
                            .foregroundColor(AtlasTheme.Colors.textSubtle)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(AtlasTheme.Colors.background.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .frame(width: 240)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(AtlasTheme.Colors.cardElevated)
                    .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous)
                            .stroke(AtlasTheme.Colors.borderLuminous, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            ToolbarItem(placement: .automatic) {
                HStack(spacing: 14) {
                    ForEach(appState.serviceStatuses) { status in
                        HStack(spacing: 5) {
                            GlowDot(
                                color: status.isOnline ? AtlasTheme.Colors.success : AtlasTheme.Colors.error,
                                size: 6,
                                glowRadius: 4
                            )
                            Text(status.name.components(separatedBy: " ").first ?? status.name)
                                .font(AtlasTheme.Typography.monoSmall)
                                .foregroundColor(AtlasTheme.Colors.textMuted)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Sidebar

private struct SidebarNavGroup {
    let title: String
    let sections: [NavigationSection]
}

private let navGroups: [SidebarNavGroup] = [
    SidebarNavGroup(title: "WORKSPACE", sections: [.overview, .assistant, .projects, .notes]),
    SidebarNavGroup(title: "OPERATIONS", sections: [.calendar, .board, .journal, .canvas, .business, .finances, .cinema]),
    SidebarNavGroup(title: "SYSTEM", sections: [.automations, .connections, .activity, .settings]),
]

struct SidebarView: View {
    @EnvironmentObject var appState: AtlasAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — Logo & Brand
            HStack(spacing: 12) {
                AnimatedLogoMark()

                VStack(alignment: .leading, spacing: 2) {
                    Text("ATLAS")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                        .tracking(1.0)
                    Text("Command Center")
                        .font(AtlasTheme.Typography.footnote)
                        .foregroundColor(AtlasTheme.Colors.champagneGold)
                }
                Spacer()
            }
            .padding(.horizontal, AtlasTheme.Spacing.lg)
            .padding(.vertical, 18)

            SidebarDivider()

            // Navigation Groups
            ScrollView(showsIndicators: false) {
                VStack(spacing: AtlasTheme.Spacing.xl) {
                    ForEach(navGroups.indices, id: \.self) { idx in
                        let group = navGroups[idx]
                        VStack(alignment: .leading, spacing: 2) {
                            // Group label
                            Text(group.title)
                                .font(AtlasTheme.Typography.label)
                                .foregroundColor(AtlasTheme.Colors.textSubtle)
                                .tracking(1.5)
                                .padding(.horizontal, AtlasTheme.Spacing.lg)
                                .padding(.bottom, 4)

                            ForEach(group.sections) { section in
                                SidebarNavItem(
                                    section: section,
                                    isSelected: appState.selectedSection == section,
                                    badgeCount: section == .activity ? appState.pendingApprovals.count : 0
                                ) {
                                    appState.selectedSection = section
                                }
                            }
                        }
                    }
                }
                .padding(.top, AtlasTheme.Spacing.lg)
                .padding(.horizontal, AtlasTheme.Spacing.sm)
            }

            Spacer()

            SidebarDivider()

            // Footer — Agent Status
            HStack(spacing: 10) {
                GlowDot(color: AtlasTheme.Colors.success, size: 6, glowRadius: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sovereign Agent")
                        .font(AtlasTheme.Typography.footnote)
                        .fontWeight(.semibold)
                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                    Text("Hermes v0.9")
                        .font(AtlasTheme.Typography.monoSmall)
                        .foregroundColor(AtlasTheme.Colors.textMuted)
                }
                Spacer()
            }
            .padding(.horizontal, AtlasTheme.Spacing.lg)
            .padding(.vertical, AtlasTheme.Spacing.md)
        }
        .background(AtlasTheme.Colors.surfaceDark)
    }
}

// MARK: - Animated Logo Mark

/// A quiet white-light mark. The previous gold shimmer competed with every
/// screen and made the navigation feel ornamental rather than precise.
private struct AnimatedLogoMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous)
                .fill(AtlasTheme.Gradients.champagneAccent)
                .frame(width: 34, height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous)
                        .stroke(Color.primary.opacity(0.16), lineWidth: 0.7)
                )
                .shadow(color: Color.white.opacity(0.10), radius: 16, y: -3)

            Text("A")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AtlasTheme.Colors.background)
        }
    }
}

// MARK: - Sidebar Item

private struct SidebarNavItem: View {
    let section: NavigationSection
    let isSelected: Bool
    let badgeCount: Int
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                // Gold accent bar for active state
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isSelected ? AtlasTheme.Colors.champagneGold : Color.clear)
                    .frame(width: 3, height: 18)
                    .padding(.trailing, 10)

                Image(systemName: section.iconName)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? AtlasTheme.Colors.champagneGold : AtlasTheme.Colors.textSecondary)
                    .frame(width: 22)

                Text(section.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? AtlasTheme.Colors.textPrimary : AtlasTheme.Colors.textSecondary)
                    .padding(.leading, 10)

                Spacer()

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AtlasTheme.Colors.warning)
                        .foregroundColor(.black)
                        .clipShape(Capsule())
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, AtlasTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous)
                    .fill(isSelected ? AtlasTheme.Colors.cardSurface : (isHovered ? AtlasTheme.Colors.cardSurface.opacity(0.5) : Color.clear))
            )
            // The whole row is the target, not just the glyphs.
            //
            // A Spacer and a Color.clear background draw nothing, and SwiftUI
            // does not hit-test what it did not draw — so without this the row
            // only answered a click or a hover directly over the icon or the
            // label, and the padding and the empty space beside it were dead.
            .contentShape(
                RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Sidebar Divider

private struct SidebarDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [AtlasTheme.Colors.borderLuminous.opacity(0), AtlasTheme.Colors.borderLuminous, AtlasTheme.Colors.borderLuminous.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}
