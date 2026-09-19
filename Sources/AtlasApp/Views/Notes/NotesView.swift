import SwiftUI
import AtlasCore
import Luminare

struct NotesView: View {
    @EnvironmentObject var appState: AtlasAppState
    @State private var searchQuery: String = ""
    @State private var selectedVaultFilter: String = "All Vaults"
    @State private var searchResults: [AtlasNote] = []
    @State private var selectedNote: AtlasNote?
    @State private var isSearching: Bool = false

    private var filteredNotes: [AtlasNote] {
        if selectedVaultFilter == "All Vaults" {
            return searchResults
        }
        return searchResults.filter { $0.vaultName == selectedVaultFilter }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search Bar & Filter Controls
            VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notes & Knowledge Search")
                            .font(AtlasTheme.Typography.title)
                            .foregroundColor(AtlasTheme.Colors.textPrimary)
                        Text("Unified search across \(appState.vaults.count) registered Obsidian vaults")
                            .font(AtlasTheme.Typography.body)
                            .foregroundColor(AtlasTheme.Colors.textSecondary)
                    }
                    Spacer()

                    // Vault Filter Dropdown
                    Menu {
                        Button("All Vaults (\(appState.vaults.count))") {
                            selectedVaultFilter = "All Vaults"
                        }
                        Divider()
                        ForEach(appState.vaults) { v in
                            Button(v.name) {
                                selectedVaultFilter = v.name
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text(selectedVaultFilter)
                        }
                        .font(AtlasTheme.Typography.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AtlasTheme.Colors.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
                    }
                }

                // Search Input Field
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(AtlasTheme.Colors.champagneGold)
                    TextField("Search titles, tags, and content across Obsidian vaults…", text: $searchQuery)
                        .font(AtlasTheme.Typography.body)
                        .textFieldStyle(.plain)
                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                        .onSubmit { performSearch() }

                    if isSearching {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        PremiumButton("Search", style: .primary) {
                            performSearch()
                        }
                    }
                }
                .padding(AtlasTheme.Spacing.md)
                .background(AtlasTheme.Colors.cardElevated)
                .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous)
                        .stroke(AtlasTheme.Gradients.cardBorder, lineWidth: 1)
                )
            }
            .padding(AtlasTheme.Spacing.lg)
            .background(AtlasTheme.Colors.surfaceDark)

            Divider().background(AtlasTheme.Colors.borderLuminous)

            // Split View: Results List vs Note Preview Pane
            HStack(spacing: 0) {
                // Results List
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        SectionHeader(title: "NOTES (\(filteredNotes.count))")
                        Spacer()
                    }
                    .padding(AtlasTheme.Spacing.md)

                    Divider().background(AtlasTheme.Colors.borderLuminous)

                    if filteredNotes.isEmpty && !isSearching {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 24))
                                .foregroundColor(AtlasTheme.Colors.textMuted)
                            Text("No matching notes found")
                                .font(AtlasTheme.Typography.caption)
                                .foregroundColor(AtlasTheme.Colors.textMuted)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(filteredNotes, selection: $selectedNote) { note in
                            Button(action: { selectedNote = note }) {
                                GlassCard(padding: AtlasTheme.Spacing.sm, cornerRadius: AtlasTheme.CornerRadius.sm, showBorder: false, hoverEffect: true, surface: AtlasTheme.Colors.background) {
                                    HStack(spacing: 8) {
                                        AccentBar(color: AtlasTheme.Colors.champagneGold, width: 3, height: nil)
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(note.title)
                                                    .font(AtlasTheme.Typography.callout)
                                                    .foregroundColor(AtlasTheme.Colors.textPrimary)
                                                Spacer()
                                                Text(note.vaultName)
                                                    .font(AtlasTheme.Typography.monoSmall)
                                                    .foregroundColor(AtlasTheme.Colors.champagneGold)
                                            }
                                            Text(note.snippet)
                                                .font(AtlasTheme.Typography.caption)
                                                .foregroundColor(AtlasTheme.Colors.textSecondary)
                                                .lineLimit(2)

                                            HStack {
                                                Text(formattedModDate(note.modifiedDate))
                                                    .font(AtlasTheme.Typography.monoSmall)
                                                    .foregroundColor(AtlasTheme.Colors.textMuted)
                                                Spacer()
                                                if note.backlinksCount > 0 {
                                                    Text("\(note.backlinksCount) links")
                                                        .font(AtlasTheme.Typography.caption)
                                                        .foregroundColor(AtlasTheme.Colors.textMuted)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                            .listRowBackground(Color.clear)
                        }
                        .listStyle(.sidebar)
                    }
                }
                .frame(width: 340)

                Divider().background(AtlasTheme.Colors.borderLuminous)

                // Note Preview Pane
                if let note = selectedNote {
                    NoteDetailPreview(note: note)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 32))
                            .foregroundColor(AtlasTheme.Colors.textMuted)
                        Text("Select a note or perform a search to view details")
                            .font(AtlasTheme.Typography.callout)
                            .foregroundColor(AtlasTheme.Colors.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { performSearch() }
    }

    private func performSearch() {
        isSearching = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = ObsidianScanner.shared.searchNotes(query: searchQuery, in: appState.vaults)
            let sorted = res.sorted { $0.modifiedDate > $1.modifiedDate }
            DispatchQueue.main.async {
                self.searchResults = sorted
                if self.selectedNote == nil { self.selectedNote = sorted.first }
                self.isSearching = false
            }
        }
    }

    private func formattedModDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }
}

struct NoteDetailPreview: View {
    let note: AtlasNote

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AtlasTheme.Spacing.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title)
                            .font(AtlasTheme.Typography.title)
                            .foregroundColor(AtlasTheme.Colors.textPrimary)
                        Text("Vault: \(note.vaultName) • \(note.relativePath)")
                            .font(AtlasTheme.Typography.monoSmall)
                            .foregroundColor(AtlasTheme.Colors.champagneGold)
                    }
                    Spacer()

                    HStack(spacing: 8) {
                        PremiumButton("Open in Obsidian", icon: "arrow.up.forward.app", style: .primary) {
                            openInObsidian()
                        }
                        PremiumButton("Finder", icon: "folder", style: .secondary) {
                            openInFinder()
                        }
                    }
                }

                Divider().background(AtlasTheme.Colors.borderLuminous)

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "CONTENT PREVIEW & MATCHING SNIPPET")

                    GlassCard(padding: AtlasTheme.Spacing.md, cornerRadius: AtlasTheme.CornerRadius.md, showBorder: true, hoverEffect: false, surface: AtlasTheme.Colors.cardSurface) {
                        Text(note.snippet)
                            .font(AtlasTheme.Typography.mono)
                            .foregroundColor(AtlasTheme.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !note.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "TAGS")

                        HStack(spacing: 6) {
                            ForEach(note.tags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(AtlasTheme.Typography.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(AtlasTheme.Colors.surfaceDark)
                                    .foregroundColor(AtlasTheme.Colors.champagneGold)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
            .padding(AtlasTheme.Spacing.xl)
        }
    }

    private func openInObsidian() {
        let uri = "obsidian://open?vault=\(note.vaultName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&file=\(note.relativePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        _ = LocalCompanion.shared.openTarget(pathOrURI: uri)
    }

    private func openInFinder() {
        _ = LocalCompanion.shared.openTarget(pathOrURI: note.path)
    }
}
