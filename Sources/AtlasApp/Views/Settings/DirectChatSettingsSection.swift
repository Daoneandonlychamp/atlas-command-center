import SwiftUI
import AtlasCore

/// Settings for everything added in the Direct-chat, journal and notification
/// work: the Featherless key, alert behaviour, the journal folder, and the
/// transcript encryption key.
struct AtlasNewSettingsSections: View {
    @ObservedObject private var direct = DirectChatSession.shared

    @State private var apiKeyDraft = ""
    @State private var apiKeySaved: Bool?
    @State private var notify = NotificationScheduler.Settings.load()
    @State private var notifyStatus = "checking…"
    @State private var revealedKey: String?
    @State private var showKeyWarning = false

    @State private var projectPaths = WorkspaceSettings.projectSearchPaths
    @State private var companionScopes = WorkspaceSettings.companionScopes
    @State private var hermesURL = WorkspaceSettings.hermesGatewayURL
    @State private var hermesBinary = WorkspaceSettings.hermesBinaryPath
    @State private var voicePython = WorkspaceSettings.voicePythonPath
    @State private var voiceModel = WorkspaceSettings.voiceModelPath

    var body: some View {
        VStack(alignment: .leading, spacing: AtlasTheme.Spacing.xl) {
            workspace
            featherless
            notifications
            journal
            transcripts
        }
        .onAppear {
            refreshNotificationStatus()
        }
    }

    // MARK: - Featherless

    private var featherless: some View {
        section("DIRECT CHAT · FEATHERLESS") {
            row("API key",
                detail: FeatherlessClient.shared.hasKey
                    ? "Set. Seeded from ~/.hermes/.env on first use, then read from the Keychain."
                    : "Missing. Direct mode cannot send without it.") {
                HStack(spacing: 6) {
                    SecureField("fw_…", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Button("Save") {
                        apiKeySaved = FeatherlessClient.shared.setAPIKey(
                            apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                        if apiKeySaved == true { apiKeyDraft = "" }
                    }
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let apiKeySaved {
                        Image(systemName: apiKeySaved ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(apiKeySaved ? AtlasTheme.Colors.success : AtlasTheme.Colors.error)
                    }
                }
            }

            row("Model", detail: direct.settings.model) {
                if FeatherlessModel.looksUncensored(direct.settings.model) { UncensoredFlag() }
            }

            row("Context window",
                detail: "\(direct.settings.contextTokens / 1024)K. Past this, older turns are condensed into a summary.") {
                EmptyView()
            }
        }
    }

    // MARK: - Notifications

    private var notifications: some View {
        section("NOTIFICATIONS") {
            row("System permission", detail: notifyStatus) {
                Button("Request") {
                    NotificationScheduler.shared.requestAccess { _ in refreshNotificationStatus() }
                }
            }

            toggleRow("Events", detail: "A few minutes before an event starts.", value: $notify.events)

            row("Lead time", detail: "How long before an event to speak up.") {
                Picker("", selection: $notify.eventLeadMinutes) {
                    ForEach([2, 5, 10, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
            }

            toggleRow("Reminders", detail: "When one comes due, plus one daily digest of overdue work.",
                      value: $notify.reminders)

            toggleRow("Stale cards", detail: "A daily digest of board cards nobody has touched.",
                      value: $notify.staleCards)

            row("Stale after", detail: "Matches the day count the board paints amber at.") {
                Picker("", selection: $notify.staleAfterDays) {
                    ForEach([3, 5, 7, 14, 30], id: \.self) { Text("\($0) days").tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
            }
        }
        // Any change rewrites the schedule, so the next alert already obeys it.
        .onChange(of: notify) { updated in
            NotificationScheduler.shared.settings = updated
            NotificationScheduler.shared.refresh()
        }
    }

    // MARK: - Journal

    private var journal: some View {
        section("JOURNAL") {
            row("Folder", detail: JournalService.shared.folder.path) {
                Button("Open") { NSWorkspace.shared.open(JournalService.shared.folder) }
            }
            row("Entries", detail: "\(JournalService.shared.recentDays().count) day(s) written") {
                EmptyView()
            }
        }
    }

    // MARK: - Transcripts

    /// The encryption key, revealed deliberately.
    ///
    /// Direct-chat transcripts are encrypted with a key held only in the login
    /// Keychain, which means losing that item loses every transcript with no way
    /// back. Some people want to hold a copy themselves. Revealing it is a real tradeoff —
    /// the key now exists somewhere outside the Keychain — so it takes two
    /// deliberate clicks and says plainly what it is.
    private var transcripts: some View {
        section("DIRECT CHAT TRANSCRIPTS") {
            row("Database", detail: ChatStore.shared.databaseURL.path) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ChatStore.shared.databaseURL])
                }
            }

            if let failure = ChatStore.shared.openFailure {
                Text(failure)
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.error)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Encryption key")
                    .font(AtlasTheme.Typography.callout)
                    .foregroundColor(AtlasTheme.Colors.textPrimary)
                Text("Transcripts are encrypted with a 256-bit key stored in your login Keychain. It exists nowhere else — lose it and every conversation is unreadable, permanently. Copy it into your password manager if you want a way back.")
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let revealedKey {
                    Text(revealedKey)
                        .font(AtlasTheme.Typography.monoSmall)
                        .foregroundColor(AtlasTheme.Colors.champagneLight)
                        .textSelection(.enabled)
                        .padding(AtlasTheme.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AtlasTheme.Colors.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
                    HStack(spacing: 8) {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(revealedKey, forType: .string)
                        }
                        Button("Hide") { self.revealedKey = nil }
                    }
                    .font(AtlasTheme.Typography.caption)
                } else if showKeyWarning {
                    HStack(spacing: 8) {
                        Text("This puts the key on screen and in your clipboard history.")
                            .font(AtlasTheme.Typography.footnote)
                            .foregroundColor(AtlasTheme.Colors.warning)
                        Button("Show it") {
                            revealedKey = ChatStore.shared.revealDatabaseKey()
                            showKeyWarning = false
                        }
                        Button("Cancel") { showKeyWarning = false }
                    }
                    .font(AtlasTheme.Typography.caption)
                } else {
                    Button("Reveal key…") { showKeyWarning = true }
                        .font(AtlasTheme.Typography.caption)
                }
            }
        }
    }

    // MARK: - Workspace

    /// Every path ATLAS is allowed to look at on this machine.
    ///
    /// All of it starts empty. Nothing here is guessed from the home directory,
    /// because a scanner pointed somewhere nobody chose finds either nothing or
    /// too much.
    private var workspace: some View {
        section("WORKSPACE · FOLDERS ON THIS MAC") {
            folderList(
                "Project folders",
                detail: projectPaths.isEmpty
                    ? "None yet. Projects stays empty until you add the folder your code lives in."
                    : "Scanned for git repositories.",
                paths: $projectPaths,
                prompt: "Choose a folder to scan for projects"
            ) { WorkspaceSettings.projectSearchPaths = $0 }

            Divider().overlay(AtlasTheme.Colors.borderSubtle)

            folderList(
                "Companion scope",
                detail: companionScopes.isEmpty
                    ? "Empty, so the Companion can read nothing and run nothing. Add only folders you want an agent touching — not your home directory."
                    : "The Companion may read and run inside these, and nowhere else.",
                paths: $companionScopes,
                prompt: "Choose a folder the Companion may work in"
            ) { WorkspaceSettings.companionScopes = $0 }

            Divider().overlay(AtlasTheme.Colors.borderSubtle)

            pathRow("Hermes gateway",
                    detail: "Base URL of a self-hosted Hermes gateway. Blank turns the integration off.",
                    placeholder: "https://…",
                    text: $hermesURL) { WorkspaceSettings.hermesGatewayURL = $0 }

            pathRow("Hermes binary",
                    detail: "Path to the hermes executable. Blank falls back to PATH.",
                    placeholder: "/usr/local/bin/hermes",
                    text: $hermesBinary) { WorkspaceSettings.hermesBinaryPath = $0 }

            Divider().overlay(AtlasTheme.Colors.borderSubtle)

            pathRow("Voice · Python",
                    detail: "Interpreter for the local TTS worker. Blank leaves voice off.",
                    placeholder: "…/venv/bin/python",
                    text: $voicePython) { WorkspaceSettings.voicePythonPath = $0 }

            pathRow("Voice · model",
                    detail: "Downloaded MLX model directory. Blank leaves voice off.",
                    placeholder: "…/Models/tts/model",
                    text: $voiceModel) { WorkspaceSettings.voiceModelPath = $0 }
        }
    }

    private func folderList(_ title: String, detail: String,
                            paths: Binding<[String]>, prompt: String,
                            save: @escaping ([String]) -> Void) -> some View {
        VStack(alignment: .leading, spacing: AtlasTheme.Spacing.sm) {
            row(title, detail: detail) {
                Button("Add folder…") {
                    guard let picked = chooseFolder(prompt: prompt) else { return }
                    guard !paths.wrappedValue.contains(picked) else { return }
                    paths.wrappedValue.append(picked)
                    save(paths.wrappedValue)
                }
            }
            ForEach(paths.wrappedValue, id: \.self) { path in
                HStack(spacing: AtlasTheme.Spacing.sm) {
                    Text(abbreviate(path))
                        .font(AtlasTheme.Typography.mono)
                        .foregroundColor(AtlasTheme.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: AtlasTheme.Spacing.sm)
                    Button("Remove") {
                        paths.wrappedValue.removeAll { $0 == path }
                        save(paths.wrappedValue)
                    }
                    .buttonStyle(.plain)
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.textMuted)
                }
            }
        }
    }

    private func pathRow(_ title: String, detail: String, placeholder: String,
                         text: Binding<String>,
                         save: @escaping (String) -> Void) -> some View {
        row(title, detail: detail) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(AtlasTheme.Typography.mono)
                .frame(width: 260)
                .onSubmit { save(text.wrappedValue) }
        }
    }

    private func chooseFolder(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.message = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }

    /// Home-relative paths read faster and keep the window narrow.
    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
            SectionHeader(title: title)
            VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                content()
            }
            .padding(AtlasTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AtlasTheme.Colors.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.lg, style: .continuous)
                    .stroke(AtlasTheme.Gradients.cardBorder, lineWidth: 1)
            )
        }
    }

    private func row<Trailing: View>(_ title: String, detail: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: AtlasTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AtlasTheme.Typography.callout)
                    .foregroundColor(AtlasTheme.Colors.textPrimary)
                Text(detail)
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AtlasTheme.Spacing.md)
            trailing()
        }
    }

    private func toggleRow(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        row(title, detail: detail) {
            Toggle("", isOn: value).labelsHidden().toggleStyle(.switch)
        }
    }

    private func refreshNotificationStatus() {
        guard NotificationScheduler.shared.isAvailable else {
            notifyStatus = "Unavailable — run the packaged app, not the bare executable."
            return
        }
        NotificationScheduler.shared.authorisationStatus { status in
            switch status {
            case .authorized, .provisional: notifyStatus = "Granted"
            case .denied: notifyStatus = "Denied — turn it on in System Settings › Notifications › ATLAS"
            case .notDetermined: notifyStatus = "Not asked yet"
            default: notifyStatus = "Unknown"
            }
        }
    }
}
