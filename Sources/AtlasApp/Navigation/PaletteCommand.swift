import SwiftUI
import AtlasCore

/// Things ⌘K can do besides jump between sections.
///
/// The palette used to be a section switcher, which meant the fastest path to
/// "add a reminder" was still three clicks. These are the verbs worth reaching
/// without leaving the keyboard.
///
/// Anything taking an argument reads it from what was typed after the verb, so
/// `card ship the build` and `journal friday` work in one line.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    /// Words that should match this command even when they are not in its title.
    let keywords: [String]
    /// Given whatever followed the verb, do the thing. Returns a message to
    /// flash, or nil for silence. Main-actor because these touch app state and
    /// the session objects the views are bound to.
    let run: @MainActor (String, AtlasAppState) -> String?

    @MainActor
    static func all() -> [PaletteCommand] {
        [
            PaletteCommand(
                id: "event",
                title: "New event",
                subtitle: "Opens the calendar on today, ready to add",
                icon: "calendar.badge.plus",
                keywords: ["meeting", "schedule", "appointment"]
            ) { _, state in
                state.selectedSection = .calendar
                return nil
            },

            PaletteCommand(
                id: "card",
                title: "New card",
                subtitle: "card <title> — adds a reminder to your default list",
                icon: "plus.rectangle.on.rectangle",
                keywords: ["task", "todo", "reminder", "board"]
            ) { argument, state in
                let title = argument.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else {
                    state.selectedSection = .board
                    return nil
                }
                switch CalendarManager.shared.createReminder(title: title, dueDate: nil,
                                                            notes: nil, listId: nil) {
                case .success:
                    state.refreshAllData()
                    return "Added “\(title)”"
                case .failure:
                    return "Could not add that reminder."
                }
            },

            PaletteCommand(
                id: "journal",
                title: "Today's journal",
                subtitle: "journal [today | yesterday | YYYY-MM-DD]",
                icon: "book.closed",
                keywords: ["diary", "write", "entry"]
            ) { argument, state in
                state.pendingJournalDay = parseDay(argument) ?? Date()
                state.selectedSection = .journal
                return nil
            },

            PaletteCommand(
                id: "chat",
                title: "New chat",
                subtitle: "Starts a fresh Direct conversation",
                icon: "bubble.left.and.text.bubble.right",
                keywords: ["assistant", "model", "ask", "direct"]
            ) { _, state in
                DirectChatSession.shared.newConversation()
                state.selectedSection = .assistant
                return nil
            },

            PaletteCommand(
                id: "board",
                title: "Board",
                subtitle: "Cards across your Reminders lists",
                icon: "rectangle.split.3x1",
                keywords: ["kanban", "cards", "columns"]
            ) { _, state in
                state.selectedSection = .board
                return nil
            },

            PaletteCommand(
                id: "refresh",
                title: "Refresh everything",
                subtitle: "Re-reads calendar, projects, notes and jobs",
                icon: "arrow.clockwise",
                keywords: ["reload", "rescan", "sync"]
            ) { _, state in
                state.refreshAllData()
                return "Refreshing"
            }
        ]
    }

    /// Day words live in AtlasCore as `PaletteDayParsing` so they can be tested
    /// and reused; this is just the spelling the palette uses.
    static func parseDay(_ text: String) -> Date? { PaletteDayParsing.parse(text) }

    /// Splits "card ship the build" into the matching command and "ship the build".
    @MainActor
    static func match(_ query: String) -> [(command: PaletteCommand, argument: String)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all().map { ($0, "") } }

        let lowered = trimmed.lowercased()
        let firstWord = lowered.split(separator: " ").first.map(String.init) ?? lowered
        let rest = trimmed.dropFirst(firstWord.count).trimmingCharacters(in: .whitespaces)

        return all().compactMap { command in
            // A leading verb takes the rest of the line as its argument.
            if command.id.hasPrefix(firstWord) || command.title.lowercased().hasPrefix(firstWord) {
                return (command, rest)
            }
            // Otherwise fall back to matching anywhere, with no argument.
            if command.title.lowercased().contains(lowered)
                || command.keywords.contains(where: { $0.contains(lowered) }) {
                return (command, "")
            }
            return nil
        }
    }
}
