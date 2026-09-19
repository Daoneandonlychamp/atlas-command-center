import SwiftUI
import AtlasCore

struct GlobalCommandPaletteView: View {
    @EnvironmentObject var appState: AtlasAppState
    @State private var query: String = ""
    @State private var hoveredSection: NavigationSection? = nil
    @State private var hoveredCommand: String? = nil
    @State private var flash: String? = nil

    /// Verbs matched against what was typed; see PaletteCommand.
    private var commands: [(command: PaletteCommand, argument: String)] {
        PaletteCommand.match(query)
    }
    @FocusState private var searchFocused: Bool

    var filteredSections: [NavigationSection] {
        if query.isEmpty { return NavigationSection.allCases }
        return NavigationSection.allCases.filter { $0.rawValue.lowercased().contains(query.lowercased()) }
    }

    var body: some View {
        ZStack {
            // Backdrop — material blur over content
            Color.black.opacity(0.55)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        appState.isCommandPaletteOpen = false
                    }
                }

            VStack(spacing: 0) {
                // Search Input
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(AtlasTheme.Colors.champagneGold)

                    TextField("Type a command or jump to section…", text: $query)
                        .font(.system(size: 16, weight: .medium))
                        .textFieldStyle(.plain)
                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                        .focused($searchFocused)
                        .onSubmit {
                            // A verb beats a section: typing "card fix the sink"
                            // should add the card, not jump to the board.
                            if let first = commands.first {
                                perform(first.command, first.argument)
                            } else if let first = filteredSections.first {
                                appState.selectedSection = first
                                close()
                            }
                        }

                    if !query.isEmpty {
                        Button(action: { query = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(AtlasTheme.Colors.textMuted)
                        }
                        .buttonStyle(.plain)
                    }

                    Text("ESC")
                        .font(AtlasTheme.Typography.monoSmall)
                        .foregroundColor(AtlasTheme.Colors.textSubtle)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(AtlasTheme.Colors.background.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(AtlasTheme.Colors.cardElevated)

                Rectangle()
                    .fill(AtlasTheme.Gradients.goldBorder)
                    .frame(height: 1)

                // Results list
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(query.isEmpty ? "COMMANDS" : "MATCHES")
                            .font(AtlasTheme.Typography.label)
                            .foregroundColor(AtlasTheme.Colors.textSubtle)
                            .tracking(1.2)
                            .padding(.horizontal, AtlasTheme.Spacing.lg)
                            .padding(.top, AtlasTheme.Spacing.md)
                            .padding(.bottom, 6)

                        ForEach(commands, id: \.command.id) { entry in
                            Button(action: { perform(entry.command, entry.argument) }) {
                                HStack(spacing: 14) {
                                    Image(systemName: entry.command.icon)
                                        .font(.system(size: 14))
                                        .foregroundColor(hoveredCommand == entry.command.id
                                                         ? AtlasTheme.Colors.champagneGold
                                                         : AtlasTheme.Colors.champagneGold.opacity(0.7))
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.argument.isEmpty
                                             ? entry.command.title
                                             : "\(entry.command.title) — \(entry.argument)")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(AtlasTheme.Colors.textPrimary)
                                        Text(entry.command.subtitle)
                                            .font(AtlasTheme.Typography.footnote)
                                            .foregroundColor(AtlasTheme.Colors.textSubtle)
                                    }

                                    Spacer()

                                    Text("Run")
                                        .font(AtlasTheme.Typography.footnote)
                                        .foregroundColor(AtlasTheme.Colors.textSubtle)
                                }
                                .padding(.horizontal, AtlasTheme.Spacing.lg)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous)
                                        .fill(hoveredCommand == entry.command.id
                                              ? AtlasTheme.Colors.cardSurface : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .onHover { hoveredCommand = $0 ? entry.command.id : nil }
                        }

                        if !commands.isEmpty && !filteredSections.isEmpty {
                            Text("SECTIONS")
                                .font(AtlasTheme.Typography.label)
                                .foregroundColor(AtlasTheme.Colors.textSubtle)
                                .tracking(1.2)
                                .padding(.horizontal, AtlasTheme.Spacing.lg)
                                .padding(.top, AtlasTheme.Spacing.md)
                                .padding(.bottom, 6)
                        }

                        ForEach(filteredSections) { sec in
                            Button(action: {
                                appState.selectedSection = sec
                                close()
                            }) {
                                HStack(spacing: 14) {
                                    Image(systemName: sec.iconName)
                                        .font(.system(size: 14))
                                        .foregroundColor(
                                            hoveredSection == sec
                                                ? AtlasTheme.Colors.champagneGold
                                                : AtlasTheme.Colors.textSecondary
                                        )
                                        .frame(width: 24)

                                    Text(sec.rawValue)
                                        .font(.system(size: 14, weight: hoveredSection == sec ? .semibold : .medium))
                                        .foregroundColor(AtlasTheme.Colors.textPrimary)

                                    Spacer()

                                    Text("Jump to")
                                        .font(AtlasTheme.Typography.footnote)
                                        .foregroundColor(AtlasTheme.Colors.textSubtle)
                                }
                                .padding(.horizontal, AtlasTheme.Spacing.lg)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous)
                                        .fill(hoveredSection == sec ? AtlasTheme.Colors.cardSurface : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .onHover { isHovered in
                                hoveredSection = isHovered ? sec : nil
                            }
                        }
                    }
                    .padding(.horizontal, AtlasTheme.Spacing.sm)
                    .padding(.bottom, AtlasTheme.Spacing.md)
                }
                .frame(maxHeight: 340)
            }
            .frame(width: 560)
            .background(AtlasTheme.Colors.surfaceDark)
            .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.xl, style: .continuous)
                    .stroke(AtlasTheme.Gradients.goldBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.7), radius: 40, y: 12)
            .shadow(color: AtlasTheme.Colors.champagneGold.opacity(0.05), radius: 60, y: 0)
            .padding(.top, 60)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
        }
        .overlay(alignment: .bottom) {
            if let flash {
                Text(flash)
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.champagneLight)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(AtlasTheme.Colors.cardElevated)
                    .clipShape(Capsule())
                    .padding(.bottom, 40)
            }
        }
    }

    private func perform(_ command: PaletteCommand, _ argument: String) {
        let message = command.run(argument, appState)
        close()
        // A command that says something worth hearing gets a moment on screen
        // even though the palette itself is already gone.
        if let message {
            flash = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { flash = nil }
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            appState.isCommandPaletteOpen = false
        }
    }
}
