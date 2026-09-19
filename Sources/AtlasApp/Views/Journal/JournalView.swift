import SwiftUI
import AtlasCore

/// The daily journal.
///
/// Deliberately native rather than a web page: the calendar and board are dense
/// grids that iterate faster in HTML, but this is a text box and a list of days,
/// and a real `NSTextView` is a better writing surface than anything in a web view.
///
/// The top of each note is assembled from what ATLAS already knows — the day's
/// events and the commits made — and is rewritten every time it is opened.
/// Everything below the marker is yours and is never touched.
struct JournalView: View {
    @EnvironmentObject var appState: AtlasAppState

    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var entry: JournalEntry?
    @State private var text = ""
    @State private var days: [Date] = []
    @State private var savedAt: Date?
    @State private var error: String?
    @State private var composerHeight: CGFloat = 200

    private let service = JournalService.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(AtlasTheme.Colors.borderLuminous)
            HStack(spacing: 0) {
                dayRail
                editor
            }
        }
        .background(AtlasTheme.Colors.background)
        .onAppear {
            // Another surface may have asked for a particular day — the calendar's
            // journal button, or the ⌘K verb.
            if let requested = appState.pendingJournalDay {
                day = Calendar.current.startOfDay(for: requested)
                appState.pendingJournalDay = nil
            }
            load()
        }
        .onChange(of: appState.pendingJournalDay) { requested in
            guard let requested else { return }
            saveIfChanged()
            day = Calendar.current.startOfDay(for: requested)
            appState.pendingJournalDay = nil
            load()
        }
        .onDisappear(perform: saveIfChanged)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AtlasTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Journal")
                    .font(AtlasTheme.Typography.headline)
                    .foregroundColor(AtlasTheme.Colors.textPrimary)
                Text(Self.longDate.string(from: day))
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.textSecondary)
            }

            Spacer()

            if let error {
                Text(error)
                    .font(AtlasTheme.Typography.footnote)
                    .foregroundColor(AtlasTheme.Colors.error)
                    .lineLimit(1)
            } else if let savedAt {
                Text("Saved \(Self.clock.string(from: savedAt))")
                    .font(AtlasTheme.Typography.monoSmall)
                    .foregroundColor(AtlasTheme.Colors.textSubtle)
            }

            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .foregroundColor(AtlasTheme.Colors.textMuted)
            Button {
                saveIfChanged()
                day = Calendar.current.startOfDay(for: Date())
                load()
            } label: {
                Text("TODAY")
                    .font(AtlasTheme.Typography.label)
                    .tracking(1.3)
                    .foregroundColor(AtlasTheme.Colors.champagneGold)
            }
            .buttonStyle(.plain)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .foregroundColor(AtlasTheme.Colors.textMuted)

            Button(action: save) {
                Text("Save")
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.champagneGold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(AtlasTheme.Colors.champagneMuted)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: .command)

            Button {
                saveIfChanged()
                if let url = entry?.url { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .foregroundColor(AtlasTheme.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .help("Open in Obsidian")
        }
        .padding(AtlasTheme.Spacing.lg)
        .background(AtlasTheme.Colors.surfaceDark)
    }

    // MARK: - Rail

    private var dayRail: some View {
        VStack(spacing: 0) {
            Text("ENTRIES")
                .font(AtlasTheme.Typography.label)
                .tracking(1.9)
                .foregroundColor(AtlasTheme.Colors.champagneGold.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AtlasTheme.Spacing.md)
                .padding(.vertical, AtlasTheme.Spacing.sm)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(days, id: \.self) { entryDay in
                        let isCurrent = Calendar.current.isDate(entryDay, inSameDayAs: day)
                        HStack(spacing: 8) {
                            Rectangle()
                                .fill(isCurrent ? AtlasTheme.Colors.champagneGold : Color.clear)
                                .frame(width: 2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Self.shortDate.string(from: entryDay))
                                    .font(AtlasTheme.Typography.caption)
                                    .foregroundColor(isCurrent ? AtlasTheme.Colors.textPrimary
                                                              : AtlasTheme.Colors.textSecondary)
                                Text(Self.weekday.string(from: entryDay))
                                    .font(AtlasTheme.Typography.monoSmall)
                                    .foregroundColor(AtlasTheme.Colors.textSubtle)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 5)
                        .padding(.trailing, AtlasTheme.Spacing.sm)
                        .background(isCurrent ? AtlasTheme.Colors.champagneMuted : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            saveIfChanged()
                            day = entryDay
                            load()
                        }
                    }
                    if days.isEmpty {
                        Text("No entries yet.")
                            .font(AtlasTheme.Typography.caption)
                            .foregroundColor(AtlasTheme.Colors.textSubtle)
                            .padding(AtlasTheme.Spacing.md)
                    }
                }
            }
        }
        .frame(width: 168)
        .background(AtlasTheme.Colors.surfaceDark)
        .overlay(Rectangle().fill(AtlasTheme.Colors.borderLuminous).frame(width: 1), alignment: .trailing)
    }

    // MARK: - Editor

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AtlasTheme.Spacing.lg) {
                if let entry {
                    assembledCard(entry.assembled)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("YOUR ENTRY")
                        .font(AtlasTheme.Typography.label)
                        .tracking(1.6)
                        .foregroundColor(AtlasTheme.Colors.textMuted)
                    // The same text view the composer uses, so writing here
                    // behaves like writing anywhere else in ATLAS.
                    GrowingTextView(text: $text, measuredHeight: $composerHeight, onSubmit: {})
                        .frame(height: max(320, composerHeight))
                        .background(AtlasTheme.Colors.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous)
                                .stroke(AtlasTheme.Colors.borderLuminous, lineWidth: 1)
                        )
                }
            }
            .padding(AtlasTheme.Spacing.lg)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// What ATLAS assembled, shown read-only: editing it would be pointless
    /// because it is rewritten from the calendar and git every time.
    private func assembledCard(_ markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ASSEMBLED FOR YOU")
                .font(AtlasTheme.Typography.label)
                .tracking(1.6)
                .foregroundColor(AtlasTheme.Colors.textMuted)
            Text(Self.stripFrontmatter(markdown))
                .font(AtlasTheme.Typography.monoSmall)
                .foregroundColor(AtlasTheme.Colors.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AtlasTheme.Spacing.md)
                .background(AtlasTheme.Colors.cardSurface.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.md, style: .continuous)
                        .stroke(AtlasTheme.Colors.borderSubtle, lineWidth: 1)
                )
        }
    }

    /// Frontmatter is for Obsidian, not for reading on screen.
    static func stripFrontmatter(_ markdown: String) -> String {
        guard markdown.hasPrefix("---\n"),
              let end = markdown.range(of: "\n---\n", range: markdown.index(markdown.startIndex, offsetBy: 3)..<markdown.endIndex)
        else { return markdown.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(markdown[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Data

    private func load() {
        let loaded = service.entry(for: day, projects: appState.projects)
        entry = loaded
        text = loaded.written
        days = service.recentDays()
        // A day being read for the first time is not yet an entry on disk, so
        // show it in the rail anyway rather than having the selection vanish.
        if !days.contains(where: { Calendar.current.isDate($0, inSameDayAs: day) }) {
            days.insert(day, at: 0)
            days.sort(by: >)
        }
        savedAt = nil
        error = nil
    }

    private func step(_ direction: Int) {
        saveIfChanged()
        day = Calendar.current.date(byAdding: .day, value: direction, to: day) ?? day
        load()
    }

    private func save() {
        guard var current = entry else { return }
        current.written = text
        // Re-assemble on save: the day may have gained events or commits since
        // it was opened, and the written half is untouched by that.
        current.assembled = service.assemble(day, projects: appState.projects)
        do {
            try service.save(current)
            entry = current
            savedAt = Date()
            error = nil
            days = service.recentDays()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Saves on the way out, but only when there is something written — otherwise
    /// merely looking at a day would litter the vault with empty notes.
    private func saveIfChanged() {
        guard let entry else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != entry.written.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        guard !trimmed.isEmpty || !entry.isNew else { return }
        save()
    }

    private static let longDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        return formatter
    }()
    private static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()
    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
