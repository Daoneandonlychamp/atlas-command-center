import SwiftUI
import AtlasCore

/// Searches the Featherless catalogue — about 22,000 models — and picks one.
///
/// The old localhost proxy kept a three-model allowlist because a browser page
/// could reach its port. Nothing but ATLAS calls Featherless now, so the list is
/// open; favourites carry the models actually in daily use to the top.
struct ModelPickerSheet: View {
    @ObservedObject var session: DirectChatSession
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var uncensoredOnly = true
    @State private var onPlanOnly = true
    @State private var catalog: [FeatherlessModel] = []
    @State private var loading = true
    @State private var loadError: String?

    /// Ranked so the models you actually use are at the top, then a name match,
    /// then everything else alphabetically.
    private var results: [FeatherlessModel] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let favorites = Set(session.settings.favorites)
        return catalog
            .filter { model in
                if onPlanOnly && model.available_on_current_plan == false { return false }
                if uncensoredOnly && !model.looksUncensored && !favorites.contains(model.id) { return false }
                if term.isEmpty { return true }
                return model.id.lowercased().contains(term)
            }
            .sorted { a, b in
                let favA = favorites.contains(a.id), favB = favorites.contains(b.id)
                if favA != favB { return favA }
                return a.id.localizedCaseInsensitiveCompare(b.id) == .orderedAscending
            }
            .prefix(300)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(AtlasTheme.Colors.borderLuminous)
            content
            Divider().background(AtlasTheme.Colors.borderLuminous)
            footer
        }
        .frame(width: 620, height: 520)
        .background(AtlasTheme.Colors.background)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AtlasTheme.Spacing.sm) {
            HStack {
                Text("Choose a model")
                    .font(AtlasTheme.Typography.headline)
                    .foregroundColor(AtlasTheme.Colors.textPrimary)
                Spacer()
                Button {
                    Task { await load(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(AtlasTheme.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .help("Re-fetch the catalogue from Featherless")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(AtlasTheme.Colors.textMuted)
                TextField("Search \(catalog.count) models…", text: $search)
                    .textFieldStyle(.plain)
                    .font(AtlasTheme.Typography.body)
                    .foregroundColor(AtlasTheme.Colors.textPrimary)
            }
            .padding(.horizontal, AtlasTheme.Spacing.md)
            .padding(.vertical, AtlasTheme.Spacing.sm)
            .background(AtlasTheme.Colors.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))

            HStack(spacing: AtlasTheme.Spacing.md) {
                Toggle("Uncensored only", isOn: $uncensoredOnly)
                Toggle("On my plan", isOn: $onPlanOnly)
                Spacer()
            }
            .toggleStyle(.checkbox)
            .font(AtlasTheme.Typography.caption)
            .foregroundColor(AtlasTheme.Colors.textSecondary)
        }
        .padding(AtlasTheme.Spacing.lg)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            centered {
                ProgressView()
                Text("Fetching the catalogue…")
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.textMuted)
            }
        } else if let loadError {
            centered {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(AtlasTheme.Colors.error)
                Text(loadError)
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        } else if results.isEmpty {
            centered {
                Text("Nothing matches. Try turning off a filter.")
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.textSubtle)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { model in
                        ModelRow(
                            model: model,
                            isSelected: model.id == session.settings.model,
                            isFavorite: session.settings.favorites.contains(model.id),
                            toggleFavorite: { toggleFavorite(model) }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            session.settings.model = model.id
                            if let length = model.context_length {
                                session.settings.contextTokens = length
                            }
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(session.settings.model)
                .font(AtlasTheme.Typography.monoSmall)
                .foregroundColor(AtlasTheme.Colors.textMuted)
                .lineLimit(1)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(AtlasTheme.Spacing.md)
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: AtlasTheme.Spacing.sm) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleFavorite(_ model: FeatherlessModel) {
        if let index = session.settings.favorites.firstIndex(of: model.id) {
            session.settings.favorites.remove(at: index)
        } else {
            session.settings.favorites.append(model.id)
        }
    }

    private func load(force: Bool = false) async {
        loading = true
        loadError = nil
        do {
            catalog = try await FeatherlessClient.shared.catalog(forceRefresh: force)
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }
}

private struct ModelRow: View {
    let model: FeatherlessModel
    let isSelected: Bool
    let isFavorite: Bool
    let toggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: AtlasTheme.Spacing.sm) {
            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundColor(isFavorite ? AtlasTheme.Colors.champagneGold
                                                : AtlasTheme.Colors.textSubtle)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Remove from favourites" : "Pin to the top of the list")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(AtlasTheme.Typography.callout)
                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                        .lineLimit(1)
                    if model.looksUncensored { UncensoredFlag() }
                }
                HStack(spacing: 8) {
                    if !model.author.isEmpty {
                        Text(model.author)
                            .font(AtlasTheme.Typography.monoSmall)
                            .foregroundColor(AtlasTheme.Colors.textSubtle)
                    }
                    if let context = model.context_length {
                        Text("\(context / 1024)K ctx")
                            .font(AtlasTheme.Typography.monoSmall)
                            .foregroundColor(AtlasTheme.Colors.textSubtle)
                    }
                    if model.available_on_current_plan == false {
                        Text("NOT ON PLAN")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(1.1)
                            .foregroundColor(AtlasTheme.Colors.error)
                    }
                }
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(AtlasTheme.Colors.champagneGold)
            }
        }
        .padding(.horizontal, AtlasTheme.Spacing.lg)
        .padding(.vertical, AtlasTheme.Spacing.sm)
        .background(isSelected ? AtlasTheme.Colors.champagneMuted : Color.clear)
    }
}
