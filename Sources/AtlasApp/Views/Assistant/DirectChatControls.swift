import SwiftUI
import AtlasCore

/// Which brain answers. Direct is the default: straight to the uncensored model,
/// no tools between you and it. Sovereign is the Hermes mission path.
enum AssistantMode: String, CaseIterable, Identifiable {
    case direct = "DIRECT"
    case sovereign = "SOVEREIGN"

    var id: String { rawValue }

    private static let defaultsKey = "atlas.assistant.mode"

    static func restore() -> AssistantMode {
        AssistantMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .direct
    }

    func remember() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// The DIRECT | SOVEREIGN switch.
struct ModeToggle: View {
    @Binding var mode: AssistantMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AssistantMode.allCases) { option in
                let selected = option == mode
                Button {
                    mode = option
                    option.remember()
                } label: {
                    Text(option.rawValue)
                        .font(AtlasTheme.Typography.label)
                        .tracking(1.4)
                        .foregroundColor(selected ? AtlasTheme.Colors.champagneGold
                                                  : AtlasTheme.Colors.textMuted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(selected ? AtlasTheme.Colors.champagneMuted : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(option == .direct
                      ? "Talk straight to the model. No tools, no approvals."
                      : "Run a Hermes mission with tools and approvals.")
            }
        }
        .padding(2)
        .background(AtlasTheme.Colors.surfaceDark)
        .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm + 2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm + 2, style: .continuous)
                .stroke(AtlasTheme.Colors.borderLuminous, lineWidth: 1)
        )
    }
}

/// Model name plus the UNCENSORED flag, opening the catalogue picker.
struct ModelBadge: View {
    let modelID: String
    @Binding var showingPicker: Bool

    var body: some View {
        Button { showingPicker = true } label: {
            HStack(spacing: 8) {
                Text(FeatherlessModel.displayName(modelID))
                    .font(AtlasTheme.Typography.callout)
                    .foregroundColor(AtlasTheme.Colors.textPrimary)
                    .lineLimit(1)
                if FeatherlessModel.looksUncensored(modelID) {
                    UncensoredFlag()
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(AtlasTheme.Colors.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(AtlasTheme.Colors.cardSurface)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(AtlasTheme.Colors.borderLuminous, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(modelID)
    }
}

/// Deliberately loud. You should never have to wonder which brain answered.
struct UncensoredFlag: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8, weight: .bold))
            Text("UNCENSORED")
                .font(.system(size: 8, weight: .bold))
                .tracking(1.2)
        }
        .foregroundColor(AtlasTheme.Colors.warning)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(AtlasTheme.Colors.warning.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

/// Temperature and reply length, changeable mid-conversation — the next request
/// picks up whatever these say when you send it.
struct SamplingControls: View {
    @Binding var temperature: Double
    @Binding var maxTokens: Int

    var body: some View {
        HStack(spacing: AtlasTheme.Spacing.md) {
            HStack(spacing: 6) {
                Text("TEMP")
                    .font(AtlasTheme.Typography.label)
                    .tracking(1.2)
                    .foregroundColor(AtlasTheme.Colors.textMuted)
                Slider(value: $temperature, in: 0...2, step: 0.05)
                    .frame(width: 92)
                    .controlSize(.mini)
                Text(String(format: "%.2f", temperature))
                    .font(AtlasTheme.Typography.monoSmall)
                    .foregroundColor(AtlasTheme.Colors.champagneLight)
                    .frame(width: 32, alignment: .leading)
            }
            .help("Higher wanders further from the likeliest next word.")

            Menu {
                ForEach([1024, 2048, 4096, 8192], id: \.self) { limit in
                    Button {
                        maxTokens = limit
                    } label: {
                        HStack {
                            Text("\(limit) tokens")
                            if maxTokens == limit { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Text("MAX \(maxTokens)")
                    .font(AtlasTheme.Typography.label)
                    .tracking(1.2)
                    .foregroundColor(AtlasTheme.Colors.textMuted)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Longest reply the model may produce.")
        }
    }
}

/// Saved conversations. Collapsed by default so the transcript keeps the width,
/// pinned open when you are working across several threads.
struct ConversationRail: View {
    @ObservedObject var session: DirectChatSession
    @Binding var isOpen: Bool
    @State private var search = ""
    @State private var conversations: [ChatConversation] = []
    @State private var renaming: ChatConversation?
    @State private var newTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(AtlasTheme.Colors.textMuted)
                TextField("Search conversations…", text: $search)
                    .textFieldStyle(.plain)
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.textPrimary)
                    .onChange(of: search) { _ in reload() }
            }
            .padding(.horizontal, AtlasTheme.Spacing.md)
            .padding(.vertical, AtlasTheme.Spacing.sm)

            Divider().background(AtlasTheme.Colors.borderSubtle)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(conversations) { conversation in
                        ConversationRow(
                            conversation: conversation,
                            isCurrent: conversation.id == session.conversationID
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { session.load(conversation) }
                        .contextMenu {
                            Button("Rename…") {
                                renaming = conversation
                                newTitle = conversation.title
                            }
                            Button("Delete", role: .destructive) {
                                session.delete(conversation)
                                reload()
                            }
                        }
                    }
                    if conversations.isEmpty {
                        Text(search.isEmpty ? "No saved conversations yet."
                                            : "Nothing matches “\(search)”.")
                            .font(AtlasTheme.Typography.caption)
                            .foregroundColor(AtlasTheme.Colors.textSubtle)
                            .padding(AtlasTheme.Spacing.md)
                    }
                }
                .padding(.vertical, AtlasTheme.Spacing.xs)
            }

            Divider().background(AtlasTheme.Colors.borderSubtle)

            Button {
                session.newConversation()
                reload()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("New conversation")
                    Spacer()
                }
                .font(AtlasTheme.Typography.caption)
                .foregroundColor(AtlasTheme.Colors.champagneGold)
                .padding(.horizontal, AtlasTheme.Spacing.md)
                .padding(.vertical, AtlasTheme.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 232)
        .background(AtlasTheme.Colors.surfaceDark)
        .overlay(
            Rectangle().fill(AtlasTheme.Colors.borderLuminous).frame(width: 1),
            alignment: .trailing
        )
        .onAppear(perform: reload)
        // A finished reply updates the timestamp the rail sorts by.
        .onChange(of: session.isStreaming) { _ in reload() }
        .onChange(of: session.conversationID) { _ in reload() }
        .sheet(item: $renaming) { conversation in
            RenameSheet(title: $newTitle) { finalTitle in
                session.rename(conversation, to: finalTitle)
                reload()
            }
        }
    }

    private func reload() {
        conversations = session.conversations(matching: search)
    }
}

private struct ConversationRow: View {
    let conversation: ChatConversation
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(isCurrent ? AtlasTheme.Colors.champagneGold : Color.clear)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(isCurrent ? AtlasTheme.Colors.textPrimary
                                               : AtlasTheme.Colors.textSecondary)
                    .lineLimit(1)
                Text("\(conversation.messageCount) · \(Self.stamp.string(from: conversation.updatedAt))")
                    .font(AtlasTheme.Typography.monoSmall)
                    .foregroundColor(AtlasTheme.Colors.textSubtle)
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, AtlasTheme.Spacing.sm)
        .padding(.vertical, 5)
        .background(isCurrent ? AtlasTheme.Colors.champagneMuted : Color.clear)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()
}

private struct RenameSheet: View {
    @Binding var title: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
            Text("Rename conversation")
                .font(AtlasTheme.Typography.headline)
                .foregroundColor(AtlasTheme.Colors.textPrimary)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { onSave(trimmed) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AtlasTheme.Spacing.xl)
        .background(AtlasTheme.Colors.cardElevated)
    }
}
