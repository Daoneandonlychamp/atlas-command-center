import SwiftUI
import UniformTypeIdentifiers
import AtlasCore
import Luminare

struct ProjectsView: View {
    @EnvironmentObject var appState: AtlasAppState

    @State private var searchQuery: String = ""
    @State private var pinnedProjectIds: Set<String> = []
    @State private var preferredEditor: String = UserDefaults.standard.string(forKey: "ATLAS_PREFERRED_EDITOR") ?? "Cursor"
    
    @State private var hoveredProjectId: String? = nil
    @StateObject private var archify = ArchifyIndex()

    private var filteredProjects: [AtlasProject] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list = appState.projects.filter { p in
            query.isEmpty || p.name.lowercased().contains(query) || p.path.lowercased().contains(query)
        }

        return list.sorted { p1, p2 in
            let isP1Pinned = pinnedProjectIds.contains(p1.id)
            let isP2Pinned = pinnedProjectIds.contains(p2.id)
            if isP1Pinned != isP2Pinned {
                return isP1Pinned && !isP2Pinned
            }
            return p1.name.lowercased() < p2.name.lowercased()
        }
    }

    private var pinnedProjectsList: [AtlasProject] {
        filteredProjects.filter { pinnedProjectIds.contains($0.id) }
    }

    private var unpinnedProjectsList: [AtlasProject] {
        filteredProjects.filter { !pinnedProjectIds.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Project Sidebar
            VStack(alignment: .leading, spacing: 0) {
                // Header & Search Bar
                VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                    HStack {
                        Text("Projects (\(appState.projects.count))")
                            .font(AtlasTheme.Typography.headline)
                            .foregroundColor(AtlasTheme.Colors.textPrimary)
                        Spacer()
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(AtlasTheme.Colors.textMuted)
                            .font(.system(size: 11))
                        TextField("Search projects by name or path…", text: $searchQuery)
                            .font(AtlasTheme.Typography.body)
                            .textFieldStyle(.plain)
                            .foregroundColor(AtlasTheme.Colors.textPrimary)
                    }
                    .padding(AtlasTheme.Spacing.sm)
                    .background(AtlasTheme.Colors.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
                }
                .padding(AtlasTheme.Spacing.md)

                Divider().background(AtlasTheme.Colors.borderLuminous)

                // Projects List (Pinned vs All) — translucent panels (native clickable rows)
                ScrollView {
                    VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                        if !pinnedProjectsList.isEmpty {
                            ProjectListPanel(title: "PINNED") {
                                ForEach(pinnedProjectsList) { proj in
                                    projectRow(proj, isPinned: true)
                                    if proj.id != pinnedProjectsList.last?.id {
                                        Divider().background(AtlasTheme.Colors.borderSubtle)
                                    }
                                }
                            }
                        }

                        ProjectListPanel(title: "ALL PROJECTS") {
                            if unpinnedProjectsList.isEmpty && pinnedProjectsList.isEmpty {
                                Text("No matching projects found.")
                                    .font(AtlasTheme.Typography.body)
                                    .foregroundColor(AtlasTheme.Colors.textMuted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(AtlasTheme.Spacing.md)
                            } else {
                                ForEach(unpinnedProjectsList) { proj in
                                    projectRow(proj, isPinned: false)
                                    if proj.id != unpinnedProjectsList.last?.id {
                                        Divider().background(AtlasTheme.Colors.borderSubtle)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, AtlasTheme.Spacing.sm)
                    .padding(.top, AtlasTheme.Spacing.sm)
                }
            }
            .frame(width: 290)
            .background(AtlasTheme.Colors.surfaceDark)

            Divider().background(AtlasTheme.Colors.borderLuminous)

            // Detail View
            if let proj = appState.selectedProject ?? filteredProjects.first {
                ProjectDetailView(
                    project: proj,
                    isPinned: pinnedProjectIds.contains(proj.id),
                    archify: archify,
                    preferredEditor: $preferredEditor,
                    onTogglePin: {
                        if pinnedProjectIds.contains(proj.id) {
                            pinnedProjectIds.remove(proj.id)
                        } else {
                            pinnedProjectIds.insert(proj.id)
                        }
                        savePins()
                    }
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 32))
                        .foregroundColor(AtlasTheme.Colors.textMuted)
                    Text("No projects discovered in workspace")
                        .font(AtlasTheme.Typography.body)
                        .foregroundColor(AtlasTheme.Colors.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .luminareTint(overridingWith: AtlasTheme.Colors.champagneGold)
        .onAppear {
            loadPins()
            if appState.selectedProject == nil {
                appState.selectedProject = filteredProjects.first
            }
        }
    }

    private func loadPins() {
        if let data = UserDefaults.standard.data(forKey: "ATLAS_PINNED_PROJECTS"),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            pinnedProjectIds = ids
        }
    }

    private func savePins() {
        if let data = try? JSONEncoder().encode(pinnedProjectIds) {
            UserDefaults.standard.set(data, forKey: "ATLAS_PINNED_PROJECTS")
        }
    }

    @ViewBuilder
    private func projectRow(_ proj: AtlasProject, isPinned: Bool) -> some View {
        ProjectRowItem(
            project: proj,
            isSelected: appState.selectedProject?.id == proj.id,
            isHovered: hoveredProjectId == proj.id,
            isPinned: isPinned,
            hasDiagram: archify.hasDiagram(proj),
            onSelect: { appState.selectedProject = proj }
        )
        .onHover { hovering in
            if hovering { hoveredProjectId = proj.id }
            else if hoveredProjectId == proj.id { hoveredProjectId = nil }
        }
    }
}

/// Translucent grouped panel with a header label. Rows stay natively clickable
/// (no gesture interception, unlike LuminareSection).
struct ProjectListPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AtlasTheme.Typography.label)
                .foregroundColor(AtlasTheme.Colors.textSecondary)
                .padding(.horizontal, AtlasTheme.Spacing.sm)

            VStack(spacing: 0) {
                content()
            }
            .background(AtlasTheme.Colors.cardSurface.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous)
                    .stroke(AtlasTheme.Colors.borderSubtle, lineWidth: 1)
            )
        }
    }
}

struct ProjectRowItem: View {
    let project: AtlasProject
    let isSelected: Bool
    let isHovered: Bool
    let isPinned: Bool
    let hasDiagram: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                if isSelected {
                    AccentBar(color: AtlasTheme.Colors.champagneGold, width: 3, height: nil)
                } else if isHovered {
                    AccentBar(color: AtlasTheme.Colors.borderLuminous, width: 3, height: nil)
                } else {
                    Spacer().frame(width: 3)
                }

                HStack(spacing: 8) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(AtlasTheme.Colors.champagneGold)
                    }

                    // A project with an architecture diagram gets its own
                    // colour. Gold already means selected and pinned here, so
                    // this uses info blue to stay a separate signal rather than
                    // a second meaning for the same hue.
                    if hasDiagram {
                        Image(systemName: "square.on.circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(AtlasTheme.Colors.info)
                            .help("Has an architecture diagram")
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(isSelected ? AtlasTheme.Typography.callout : AtlasTheme.Typography.body)
                            .foregroundColor(isSelected ? AtlasTheme.Colors.champagneGold : AtlasTheme.Colors.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Text(project.projectType.rawValue)
                                .font(AtlasTheme.Typography.label)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(AtlasTheme.Colors.surfaceDark)
                                .foregroundColor(AtlasTheme.Colors.textSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))

                            Text("• \(project.gitStatus)")
                                .font(AtlasTheme.Typography.caption)
                                .foregroundColor(AtlasTheme.Colors.textMuted)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, AtlasTheme.Spacing.md)
                .padding(.vertical, 10)
                .background(isSelected ? AtlasTheme.Colors.cardElevated : (isHovered ? AtlasTheme.Colors.cardSurface : Color.clear))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProjectDetailView: View {
    let project: AtlasProject
    let isPinned: Bool
    @ObservedObject var archify: ArchifyIndex
    @State private var isDiagramDropTargeted = false
    @Binding var preferredEditor: String
    let onTogglePin: () -> Void

    @EnvironmentObject var appState: AtlasAppState

    @State private var isRunningCommand: Bool = false
    @State private var activeHandle: AtlasCommandHandle? = nil
    @State private var commandOutput: String = ""
    @State private var commandExitCode: Int32? = nil
    @State private var commandDuration: Double = 0.0
    @State private var editorErrorMessage: String? = nil

    private var availableCommands: [ProjectCommandDefinition] {
        var cmds: [ProjectCommandDefinition] = []

        if project.isGitRepository {
            cmds.append(ProjectCommandDefinition(
                id: "git_status",
                label: "git status",
                command: "git status",
                isExecutable: true,
                isAllowlisted: true
            ))
            cmds.append(ProjectCommandDefinition(
                id: "git_branch",
                label: "git branch",
                command: "git branch",
                isExecutable: true,
                isAllowlisted: true
            ))
            cmds.append(ProjectCommandDefinition(
                id: "git_log",
                label: "git log",
                command: "git log -n 5 --oneline",
                isExecutable: true,
                isAllowlisted: true
            ))
        }

        if project.projectType == .swiftPackage {
            cmds.append(ProjectCommandDefinition(
                id: "swift_test",
                label: "swift test",
                command: "swift test",
                isExecutable: true,
                isAllowlisted: true
            ))
            cmds.append(ProjectCommandDefinition(
                id: "swift_build",
                label: "swift build",
                command: "swift build",
                isExecutable: true,
                isAllowlisted: true
            ))
        } else {
            cmds.append(ProjectCommandDefinition(
                id: "swift_test_unavail",
                label: "swift test",
                command: "swift test",
                isExecutable: false,
                isAllowlisted: false,
                unavailableReason: "Requires Swift Package (Package.swift)"
            ))
        }

        if project.projectType == .nodeProject || project.projectType == .clientWebsite || project.projectType == .monorepoApp {
            for script in project.availableScripts {
                let fullCmd = "npm run \(script)"
                let isAllowed = script == "test" || script == "build" || script == "check"
                cmds.append(ProjectCommandDefinition(
                    id: "npm_\(script)",
                    label: "npm run \(script)",
                    command: fullCmd,
                    isExecutable: isAllowed,
                    isAllowlisted: isAllowed,
                    unavailableReason: isAllowed ? nil : "Script requires security approval"
                ))
            }
        } else if !project.availableScripts.isEmpty {
            cmds.append(ProjectCommandDefinition(
                id: "npm_unavail",
                label: "npm scripts",
                command: "npm test",
                isExecutable: false,
                isAllowlisted: false,
                unavailableReason: "Requires Node.js project (package.json)"
            ))
        }

        return cmds
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AtlasTheme.Spacing.xl) {
                // Header Bar & Launchers
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(project.name)
                                .font(AtlasTheme.Typography.title)
                                .foregroundColor(AtlasTheme.Colors.textPrimary)

                            Text(project.projectType.rawValue)
                                .font(AtlasTheme.Typography.label)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(AtlasTheme.Gradients.champagneAccent)
                                .foregroundColor(.black)
                                .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))

                            Button(action: onTogglePin) {
                                Image(systemName: isPinned ? "pin.fill" : "pin")
                                    .foregroundColor(isPinned ? AtlasTheme.Colors.champagneGold : AtlasTheme.Colors.textMuted)
                            }
                            .buttonStyle(.plain)
                        }

                        HStack(spacing: 6) {
                            Text(project.path)
                                .font(AtlasTheme.Typography.mono)
                                .foregroundColor(AtlasTheme.Colors.textSecondary)

                            Button(action: copyProjectPath) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                    .foregroundColor(AtlasTheme.Colors.champagneGold)
                            }
                            .buttonStyle(.plain)
                        }

                        if project.isNestedApplication, let root = project.gitRootPath {
                            Text("Nested inside Git Root: \(root)")
                                .font(AtlasTheme.Typography.caption)
                                .foregroundColor(AtlasTheme.Colors.textMuted)
                        }
                    }
                    Spacer()

                    // Quick Action Launchers
                    HStack(spacing: 8) {
                        PremiumButton("Use in Assistant", icon: "sparkles", style: .primary) {
                            useInAssistant()
                        }
                        PremiumButton("Finder", icon: "folder", style: .secondary) {
                            openFinder()
                        }
                        PremiumButton("Terminal", icon: "terminal", style: .secondary) {
                            openTerminal()
                        }

                        Menu {
                            Button("Cursor") { setPreferredEditor("Cursor") }
                            Button("VS Code") { setPreferredEditor("VS Code") }
                            Button("Xcode") { setPreferredEditor("Xcode") }
                            Button("Finder") { setPreferredEditor("Finder") }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.pencil")
                                Text("Editor (\(preferredEditor))")
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(AtlasTheme.Colors.cardSurface)
                            .foregroundColor(AtlasTheme.Colors.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
                        }
                    }
                }

                // Editor Error Notification Banner
                if let err = editorErrorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(AtlasTheme.Colors.warning)
                        Text(err)
                            .font(AtlasTheme.Typography.body)
                            .foregroundColor(AtlasTheme.Colors.textPrimary)
                        Spacer()
                        Button("Dismiss") { editorErrorMessage = nil }
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(AtlasTheme.Colors.champagneGold)
                            .buttonStyle(.plain)
                    }
                    .padding(AtlasTheme.Spacing.md)
                    .background(AtlasTheme.Colors.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous))
                }

                // Available Commands (Capability-Based)
                VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                    SectionHeader(title: "PROJECT COMMANDS & AUTOMATIONS", actionTitle: nil, action: nil)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 8) {
                        ForEach(availableCommands) { cmd in
                            Button(action: { runSafeCommand(cmd) }) {
                                HStack(spacing: 6) {
                                    Image(systemName: cmd.isExecutable ? "play.circle.fill" : "lock.fill")
                                        .foregroundColor(cmd.isExecutable ? AtlasTheme.Colors.champagneGold : AtlasTheme.Colors.textMuted)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(cmd.label)
                                            .font(AtlasTheme.Typography.mono)
                                            .foregroundColor(cmd.isExecutable ? AtlasTheme.Colors.textPrimary : AtlasTheme.Colors.textMuted)
                                        if let reason = cmd.unavailableReason {
                                            Text(reason)
                                                .font(.system(size: 9))
                                                .foregroundColor(AtlasTheme.Colors.textMuted)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                // A runnable command reads as a raised surface;
                                // a locked one stays flat, so the difference is
                                // visible before you read the icon.
                                .background(cmd.isExecutable
                                            ? AnyShapeStyle(AtlasTheme.Gradients.buttonSecondary)
                                            : AnyShapeStyle(AtlasTheme.Colors.cardSurface))
                                .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous)
                                        .stroke(cmd.isExecutable ? AtlasTheme.Colors.borderLuminous : Color.clear, lineWidth: 1)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous)
                                        .strokeBorder(AtlasTheme.Gradients.edgeHighlight, lineWidth: 1)
                                        .opacity(cmd.isExecutable ? 1 : 0)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!cmd.isExecutable || isRunningCommand)
                        }
                    }

                    // Command Terminal Output View
                    if isRunningCommand || !commandOutput.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                HStack(spacing: 6) {
                                    if isRunningCommand {
                                        ProgressView().scaleEffect(0.6)
                                    }
                                    Text(isRunningCommand ? "COMMAND RUNNING…" : "COMMAND OUTPUT")
                                        .font(AtlasTheme.Typography.label)
                                        .foregroundColor(AtlasTheme.Colors.champagneGold)
                                }
                                Spacer()
                                if isRunningCommand {
                                    Button(action: cancelCommand) {
                                        Text("Cancel Execution")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(AtlasTheme.Colors.error)
                                    }
                                    .buttonStyle(.plain)
                                } else if let code = commandExitCode {
                                    Text("Exit Code: \(code) • \(String(format: "%.2fs", commandDuration))")
                                        .font(AtlasTheme.Typography.monoSmall)
                                        .foregroundColor(code == 0 ? AtlasTheme.Colors.success : AtlasTheme.Colors.error)
                                }
                            }

                            Text(commandOutput)
                                .font(AtlasTheme.Typography.mono)
                                .foregroundColor(AtlasTheme.Colors.textPrimary)
                                .padding(AtlasTheme.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AtlasTheme.Colors.background)
                                .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous))
                        }
                    }
                }

                // Status Summary Grid
                // No border on the container: each DetailCard already draws one,
                // and a bordered box around three bordered boxes reads as chrome
                // rather than structure.
                GlassCard(padding: 0, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: false, hoverEffect: false, surface: .clear) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: AtlasTheme.Spacing.md) {
                        DetailCard(label: "Git Repository", value: project.isGitRepository ? (project.isNestedApplication ? "Nested App" : "Initialized Root") : "Not Initialized", icon: "arrow.triangle.branch")
                        DetailCard(label: "Working Tree Status", value: project.gitStatus, icon: "tray")
                        DetailCard(label: "Deployment Target", value: project.deploymentStatus, icon: "server.rack")
                    }
                }

                // Architecture diagram, when archify has generated one for this
                // project. Read live from the vault, so regenerating a diagram
                // shows up here without rebuilding ATLAS.
                VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                    if let diagram = archify.diagramURL(for: project) {
                        SectionHeader(title: "ARCHITECTURE", actionTitle: "Open Full Size") {
                            NSWorkspace.shared.open(diagram)
                        }

                        GlassCard(padding: 0,
                                  cornerRadius: AtlasTheme.CornerRadius.md,
                                  showBorder: true,
                                  hoverEffect: false,
                                  surface: AtlasTheme.Colors.cardSurface) {
                            DiagramWebView(url: diagram)
                                .frame(height: 460)
                                .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md,
                                                            style: .continuous))
                        }
                        Text("Drop a new .html here to replace it.")
                            .font(AtlasTheme.Typography.footnote)
                            .foregroundColor(AtlasTheme.Colors.textSubtle)
                    } else {
                        SectionHeader(title: "ARCHITECTURE", actionTitle: nil, action: nil)

                        VStack(spacing: 8) {
                            Image(systemName: "square.on.circle")
                                .font(.system(size: 22))
                                .foregroundColor(isDiagramDropTargeted
                                                 ? AtlasTheme.Colors.info
                                                 : AtlasTheme.Colors.textMuted)
                            Text("Drop an archify diagram here")
                                .font(AtlasTheme.Typography.callout)
                                .foregroundColor(AtlasTheme.Colors.textSecondary)
                            // Naming is the part people get wrong, so say what
                            // the drop will do rather than leaving it implied.
                            Text("Saved as \(ArchifyDiagrams.slug(project.name)).html so ATLAS finds it")
                                .font(AtlasTheme.Typography.footnote)
                                .foregroundColor(AtlasTheme.Colors.textSubtle)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 26)
                        .background(isDiagramDropTargeted
                                    ? AtlasTheme.Colors.info.opacity(0.07)
                                    : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md,
                                                    style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                .foregroundColor(isDiagramDropTargeted
                                                 ? AtlasTheme.Colors.info
                                                 : AtlasTheme.Colors.borderSubtle)
                        )
                    }

                    if let problem = archify.lastError {
                        Text(problem)
                            .font(AtlasTheme.Typography.footnote)
                            .foregroundColor(AtlasTheme.Colors.error)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isDiagramDropTargeted)
                .onDrop(of: [.fileURL], isTargeted: $isDiagramDropTargeted) { providers in
                    archify.handleDrop(providers, for: project)
                }

                // Changed Files Section
                if project.isGitRepository {
                    VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                        SectionHeader(title: "CHANGED FILES (\(project.uncommittedChangesCount))", actionTitle: nil, action: nil)

                        if project.uncommittedChangesCount == 0 {
                            BriefingEmptyStateCard(title: "Working tree clean. No uncommitted changes.", icon: "checkmark.circle")
                        } else {
                            VStack(spacing: 4) {
                                ForEach(project.stagedFiles, id: \.self) { f in
                                    FileChangeRow(path: f, changeType: "Staged", color: AtlasTheme.Colors.success)
                                }
                                ForEach(project.modifiedFiles, id: \.self) { f in
                                    FileChangeRow(path: f, changeType: "Modified", color: AtlasTheme.Colors.warning)
                                }
                                ForEach(project.untrackedFiles, id: \.self) { f in
                                    FileChangeRow(path: f, changeType: "Untracked", color: .cyan)
                                }
                                ForEach(project.deletedFiles, id: \.self) { f in
                                    FileChangeRow(path: f, changeType: "Deleted", color: AtlasTheme.Colors.error)
                                }
                                ForEach(project.conflictedFiles, id: \.self) { f in
                                    FileChangeRow(path: f, changeType: "Conflicted", color: AtlasTheme.Colors.error)
                                }
                            }
                        }
                    }

                    // Recent Commits History
                    VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                        SectionHeader(title: "RECENT COMMITS", actionTitle: nil, action: nil)

                        if project.recentCommits.isEmpty {
                            BriefingEmptyStateCard(title: "No commit history found.", icon: "clock")
                        } else {
                            ForEach(project.recentCommits, id: \.self) { commitLine in
                                CommitRow(commitLine: commitLine)
                            }
                        }
                    }
                } else {
                    // Calm Non-Git State Card
                    GlassCard(padding: AtlasTheme.Spacing.lg, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: true, hoverEffect: false, surface: AtlasTheme.Colors.cardSurface) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundColor(AtlasTheme.Colors.textMuted)
                                Text("Git Not Initialized")
                                    .font(AtlasTheme.Typography.headline)
                                    .foregroundColor(AtlasTheme.Colors.textPrimary)
                            }
                            Text("This folder is tracked as a project, but is not currently a Git repository. You can open it in Finder or Terminal at any time.")
                                .font(AtlasTheme.Typography.body)
                                .foregroundColor(AtlasTheme.Colors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

            }
            .padding(AtlasTheme.Spacing.xl)
        }
    }

    private func setPreferredEditor(_ editor: String) {
        preferredEditor = editor
        UserDefaults.standard.set(editor, forKey: "ATLAS_PREFERRED_EDITOR")
    }

    private func useInAssistant() {
        appState.selectedProject = project
        appState.pendingAssistantProjectContext = project
        appState.selectedSection = .assistant
    }

    private func copyProjectPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(project.path, forType: .string)
    }

    private func openFinder() {
        guard FileManager.default.fileExists(atPath: project.path) else {
            editorErrorMessage = "Project directory path does not exist on disk."
            return
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
    }

    private func openTerminal() {
        guard FileManager.default.fileExists(atPath: project.path) else {
            editorErrorMessage = "Project directory path does not exist on disk."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([URL(fileURLWithPath: project.path)], withApplicationAt: terminalURL, configuration: configuration)
        } else {
            openFinder()
        }
    }

    private func runSafeCommand(_ cmdDef: ProjectCommandDefinition) {
        guard !isRunningCommand else { return }

        isRunningCommand = true
        commandOutput = "Running '\(cmdDef.command)' in \(project.name)…\n"
        commandExitCode = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let result = LocalCompanion.shared.executeCommand(
                command: cmdDef.command,
                projectPath: project.path,
                onHandleAssigned: { h in
                    DispatchQueue.main.async {
                        self.activeHandle = h
                    }
                }
            )

            DispatchQueue.main.async {
                self.isRunningCommand = false
                self.activeHandle = nil
                self.commandExitCode = result.exitCode
                self.commandDuration = result.duration

                if result.isCancelled {
                    self.commandOutput = "❌ Command Execution Cancelled."
                } else {
                    var outStr = ""
                    if !result.stdout.isEmpty { outStr += result.stdout }
                    if !result.stderr.isEmpty {
                        if !outStr.isEmpty { outStr += "\n--- STDERR ---\n" }
                        outStr += result.stderr
                    }
                    self.commandOutput = outStr.isEmpty ? "Command completed with empty output." : outStr
                }
                self.appState.refreshAllData()
            }
        }
    }

    private func cancelCommand() {
        activeHandle?.cancel()
    }
}

struct ProjectCommandDefinition: Identifiable {
    let id: String
    let label: String
    let command: String
    let isExecutable: Bool
    let isAllowlisted: Bool
    var unavailableReason: String? = nil
}

struct FileChangeRow: View {
    let path: String
    let changeType: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            GlowDot(color: color, size: 6, glowRadius: 4)

            Text(changeType)
                .font(AtlasTheme.Typography.label)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.1))
                .foregroundColor(color)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))

            Text(path)
                .font(AtlasTheme.Typography.monoSmall)
                .foregroundColor(AtlasTheme.Colors.textPrimary)
                .lineLimit(1)

            Spacer()

            Button(action: copyPath) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundColor(AtlasTheme.Colors.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AtlasTheme.Spacing.md)
        .padding(.vertical, 6)
        .background(AtlasTheme.Colors.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

struct CommitRow: View {
    let commitLine: String

    private var hashPart: String {
        let parts = commitLine.components(separatedBy: " ")
        return parts.first ?? ""
    }

    private var subjectPart: String {
        let parts = commitLine.components(separatedBy: " ")
        return parts.dropFirst().joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(hashPart)
                .font(AtlasTheme.Typography.monoSmall)
                .foregroundColor(AtlasTheme.Colors.champagneGold)

            Text(subjectPart)
                .font(AtlasTheme.Typography.body)
                .foregroundColor(AtlasTheme.Colors.textPrimary)
                .lineLimit(1)

            Spacer()

            Button(action: copyHash) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundColor(AtlasTheme.Colors.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(AtlasTheme.Spacing.md)
        .background(AtlasTheme.Colors.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous))
    }

    private func copyHash() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hashPart, forType: .string)
    }
}
