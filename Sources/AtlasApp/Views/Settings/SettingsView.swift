import SwiftUI
import AtlasCore
import Luminare

struct SettingsView: View {
    @EnvironmentObject var appState: AtlasAppState
    @ObservedObject private var voiceService = SovereignVoiceService.shared
    @AppStorage("atlas.appearance") private var appearance = AtlasAppearance.system.rawValue

    @State private var railwayToken: String = KeychainManager.shared.get(key: "RAILWAY_BEARER_TOKEN") ?? ""
    @State private var tmdbKey: String = KeychainManager.shared.get(key: CinemaBridge.tmdbKeychainAccount) ?? ""
    @State private var tmdbMessage: String = ""
    @State private var launchAtLogin: Bool = false
    @State private var saveMessage: String = ""

    private var obsidianConnected: Bool {
        let obsConfig = NSString(string: "~/Library/Application Support/obsidian/obsidian.json").expandingTildeInPath
        return FileManager.default.fileExists(atPath: obsConfig)
    }

    /// Probes the folders the user actually gave ATLAS, not a guessed one.
    /// With none configured there is nothing to be denied, so this reports the
    /// honest answer rather than a red light.
    private var scopesReadable: Bool {
        let scopes = WorkspaceSettings.companionScopes
        guard !scopes.isEmpty else { return false }
        return scopes.allSatisfy { FileManager.default.isReadableFile(atPath: $0) }
    }

    private var scopeDetail: String {
        let scopes = WorkspaceSettings.companionScopes
        if scopes.isEmpty { return "No workspace folders configured yet" }
        return scopes.joined(separator: ", ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AtlasTheme.Spacing.xl) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Settings & System Permissions Matrix")
                            .font(AtlasTheme.Typography.title)
                            .foregroundColor(AtlasTheme.Colors.textPrimary)
                        Text("macOS Permissions, Sovereign Voice & Keychain Credential Management")
                            .font(AtlasTheme.Typography.body)
                            .foregroundColor(AtlasTheme.Colors.textSecondary)
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                    SectionHeader(title: "APPEARANCE")
                    GlassCard(hoverEffect: false) {
                        HStack(spacing: AtlasTheme.Spacing.xl) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Interface appearance")
                                    .font(AtlasTheme.Typography.callout)
                                    .foregroundColor(AtlasTheme.Colors.textPrimary)
                                Text("Follow macOS or keep ATLAS consistently light or dark.")
                                    .font(AtlasTheme.Typography.caption)
                                    .foregroundColor(AtlasTheme.Colors.textSecondary)
                            }
                            Spacer()
                            Picker("Appearance", selection: $appearance) {
                                ForEach(AtlasAppearance.allCases) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 230)
                        }
                    }
                }

                // Sovereign Voice Section
                VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                    SectionHeader(title: "SOVEREIGN VOICE SYSTEM")

                    GlassCard(padding: AtlasTheme.Spacing.lg, cornerRadius: AtlasTheme.CornerRadius.lg, showBorder: true, hoverEffect: false, surface: AtlasTheme.Colors.cardSurface) {
                        VStack(alignment: .leading, spacing: AtlasTheme.Spacing.lg) {
                            // Status indicator
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Chatterbox 4-bit Engine")
                                        .font(AtlasTheme.Typography.callout)
                                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                                    Text(voiceService.state.statusDescription)
                                        .font(AtlasTheme.Typography.caption)
                                        .foregroundColor(voiceService.state.isReady ? AtlasTheme.Colors.champagneGold : AtlasTheme.Colors.textMuted)
                                }
                                Spacer()
                                GlowDot(
                                    color: voiceService.state.isReady ? AtlasTheme.Colors.success : (voiceService.state.isPlaying ? AtlasTheme.Colors.champagneGold : AtlasTheme.Colors.warning),
                                    size: 8,
                                    glowRadius: 6
                                )
                            }

                            Divider().background(AtlasTheme.Colors.borderSubtle)

                            // Toggles (Luminare)
                            LuminareSection(hasPadding: false) {
                                LuminareToggle("Enable Sovereign Voice", isOn: $voiceService.isVoiceEnabled)
                                LuminareToggle("Auto-speak Assistant Responses", isOn: $voiceService.isAutoSpeakEnabled)
                                    .disabled(!voiceService.isVoiceEnabled)
                            }

                            // Volume Slider
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Output Volume")
                                        .font(AtlasTheme.Typography.callout)
                                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                                    Spacer()
                                    Text("\(Int(voiceService.outputVolume * 100))%")
                                        .font(AtlasTheme.Typography.monoSmall)
                                        .foregroundColor(AtlasTheme.Colors.champagneGold)
                                }
                                Slider(value: $voiceService.outputVolume, in: 0.0...1.0)
                                    .tint(AtlasTheme.Colors.champagneGold)
                                    .disabled(!voiceService.isVoiceEnabled)
                            }

                            Divider().background(AtlasTheme.Colors.borderSubtle)

                            // Test & Stop Controls
                            HStack(spacing: 12) {
                                if voiceService.state.isPlaying {
                                    PremiumButton("Stop Voice Playback", style: .secondary) {
                                        voiceService.stop()
                                    }
                                } else {
                                    PremiumButton("Test Lewis + Onyx Voice", style: .primary) {
                                        voiceService.testVoice()
                                    }
                                    .disabled(!voiceService.isVoiceEnabled || !voiceService.state.isReady)
                                }
                            }
                        }
                    }
                }

                // Launch at login setting (Honest disabled state)
                VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                    SectionHeader(title: "APPLICATION PREFERENCES")

                    LuminareSection(hasPadding: false) {
                        LuminareToggle(isOn: $launchAtLogin) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Launch ATLAS at Login (Disabled / Not Configured)")
                                    .font(AtlasTheme.Typography.callout)
                                    .foregroundColor(AtlasTheme.Colors.textMuted)
                                Text("SMAppService helper daemon registration requires developer signing and is currently unconfigured.")
                                    .font(AtlasTheme.Typography.caption)
                                    .foregroundColor(AtlasTheme.Colors.textMuted)
                            }
                            .padding(.horizontal, 8)
                        }
                        .disabled(true)
                    }
                }

                // System Permissions Matrix (Live Checked)
                AtlasNewSettingsSections()

                VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                    SectionHeader(title: "LIVE MACOS SYSTEM PERMISSIONS MATRIX")

                    PermissionRow(
                        name: "Files & Folders Scope",
                        statusText: scopesReadable ? "Readable" : "Not configured",
                        isGranted: scopesReadable,
                        detail: scopeDetail
                    )

                    PermissionRow(
                        name: "Obsidian Registry File",
                        statusText: obsidianConnected ? "Connected" : "Missing",
                        isGranted: obsidianConnected,
                        detail: "obsidian.json configuration file check"
                    )

                    PermissionRow(
                        name: "macOS Calendar (EventKit)",
                        statusText: CalendarManager.shared.calendarAuthorizationStatus.rawValue,
                        isGranted: CalendarManager.shared.calendarAuthorizationStatus == .authorized,
                        detail: "EKEventStore calendar events entitlement"
                    )

                    PermissionRow(
                        name: "macOS Reminders (EventKit)",
                        statusText: CalendarManager.shared.reminderAuthorizationStatus.rawValue,
                        isGranted: CalendarManager.shared.reminderAuthorizationStatus == .authorized,
                        detail: "EKEventStore reminders entitlement"
                    )

                    PermissionRow(
                        name: "Accessibility Services",
                        statusText: "Not Checked",
                        isGranted: false,
                        detail: "Requires explicit system privacy check"
                    )
                }

                // Keychain & Service Credentials
                VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                    SectionHeader(title: "MACOS KEYCHAIN CREDENTIALS")

                    GlassCard(padding: AtlasTheme.Spacing.lg, cornerRadius: AtlasTheme.CornerRadius.lg, showBorder: true, hoverEffect: false, surface: AtlasTheme.Colors.cardSurface) {
                        VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                            Text("Railway Sovereign Bearer Token")
                                .font(AtlasTheme.Typography.callout)
                                .foregroundColor(AtlasTheme.Colors.textPrimary)

                            SecureField("Bearer token for your Hermes gateway", text: $railwayToken)
                                .font(AtlasTheme.Typography.mono)
                                .textFieldStyle(.plain)
                                .padding(AtlasTheme.Spacing.md)
                                .background(AtlasTheme.Colors.surfaceDark)
                                .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous)
                                        .stroke(AtlasTheme.Colors.borderSubtle, lineWidth: 1)
                                )

                            HStack {
                                PremiumButton("Save to Keychain", style: .primary) {
                                    saveKeychainToken()
                                }

                                if !saveMessage.isEmpty {
                                    Text(saveMessage)
                                        .font(AtlasTheme.Typography.caption)
                                        .foregroundColor(saveMessage.contains("Failed") ? AtlasTheme.Colors.error : AtlasTheme.Colors.success)
                                }
                            }
                        }
                    }

                    GlassCard(padding: AtlasTheme.Spacing.lg, cornerRadius: AtlasTheme.CornerRadius.lg, showBorder: true, hoverEffect: false, surface: AtlasTheme.Colors.cardSurface) {
                        VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                            Text("TMDB API Key")
                                .font(AtlasTheme.Typography.callout)
                                .foregroundColor(AtlasTheme.Colors.textPrimary)

                            Text("Cinema reads this from the Keychain and hands it to the page at load. Without it, Cinema cannot search TMDB.")
                                .font(AtlasTheme.Typography.caption)
                                .foregroundColor(AtlasTheme.Colors.textSecondary)

                            SecureField("Enter your themoviedb.org API key", text: $tmdbKey)
                                .font(AtlasTheme.Typography.mono)
                                .textFieldStyle(.plain)
                                .padding(AtlasTheme.Spacing.md)
                                .background(AtlasTheme.Colors.surfaceDark)
                                .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous)
                                        .stroke(AtlasTheme.Colors.borderSubtle, lineWidth: 1)
                                )

                            HStack {
                                PremiumButton("Save to Keychain", style: .primary) {
                                    saveTMDBKey()
                                }

                                if !tmdbMessage.isEmpty {
                                    Text(tmdbMessage)
                                        .font(AtlasTheme.Typography.caption)
                                        .foregroundColor(tmdbMessage.contains("Failed") ? AtlasTheme.Colors.error : AtlasTheme.Colors.success)
                                }
                            }
                        }
                    }
                }
            }
            .padding(AtlasTheme.Spacing.xl)
        }
        .onAppear {
            voiceService.warmWorker()
        }
    }

    private func saveKeychainToken() {
        let success = KeychainManager.shared.save(key: "RAILWAY_BEARER_TOKEN", value: railwayToken)
        saveMessage = success ? "Saved securely to Keychain" : "Failed to save credential"
    }

    /// Cinema picks this up on its next load: the page is handed the key with
    /// the rest of its state, so there is nothing to paste into the HTML.
    private func saveTMDBKey() {
        let success = KeychainManager.shared.save(key: CinemaBridge.tmdbKeychainAccount, value: tmdbKey)
        tmdbMessage = success ? "Saved. Reopen Cinema to use it." : "Failed to save credential"
    }
}

struct PermissionRow: View {
    let name: String
    let statusText: String
    let isGranted: Bool
    let detail: String

    var body: some View {
        GlassCard(padding: AtlasTheme.Spacing.md, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: true, hoverEffect: true, surface: AtlasTheme.Colors.cardSurface) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(AtlasTheme.Typography.callout)
                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                    Text(detail)
                        .font(AtlasTheme.Typography.caption)
                        .foregroundColor(AtlasTheme.Colors.textSecondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    GlowDot(color: isGranted ? AtlasTheme.Colors.success : AtlasTheme.Colors.warning, size: 8, glowRadius: 6)
                    Text(statusText)
                        .font(AtlasTheme.Typography.label)
                        .foregroundColor(isGranted ? AtlasTheme.Colors.success : AtlasTheme.Colors.warning)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isGranted ? AtlasTheme.Colors.success.opacity(0.15) : AtlasTheme.Colors.warning.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
            }
        }
    }
}
