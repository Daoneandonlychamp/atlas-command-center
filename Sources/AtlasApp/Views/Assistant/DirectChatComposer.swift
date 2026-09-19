import SwiftUI
import AtlasCore

/// A text view that grows with its content, where Enter sends and Shift+Enter
/// adds a line.
///
/// SwiftUI's `TextEditor` is not used here: it applies its own text insets that
/// are neither documented nor readable, so an overlaid placeholder never lines up
/// with the caret, and its frame cannot be made to hug a single line. Owning an
/// `NSTextView` means the insets are exactly what this file says they are, and
/// the height comes from the layout manager instead of a guess about line counts.
struct GrowingTextView: NSViewRepresentable {
    @Binding var text: String
    /// Reported back so the container can size itself to the text.
    @Binding var measuredHeight: CGFloat
    let onSubmit: () -> Void

    /// Shared with the placeholder so both start at the same pixel.
    static let inset = NSSize(width: 5, height: 7)
    static let maxHeight: CGFloat = 150

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none

        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        // Dynamic colours, not fixed ones: an NSTextView keeps whatever it was
        // handed, so a hardcoded white caret and white text simply vanish the
        // moment the interface is light.
        textView.textColor = .atlasAdaptive(light: 0x1D1B18, dark: 0xF0F0EE, alpha: 0.94)
        textView.insertionPointColor = .atlasAdaptive(light: 0x1D1B18, dark: 0xD4B059)
        textView.textContainerInset = Self.inset
        // Zeroed so the placeholder's leading padding is the whole story.
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.reportHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Only write back when the model changed underneath us — assigning during
        // typing would reset the insertion point to the end on every keystroke.
        if textView.string != text {
            textView.string = text
            context.coordinator.reportHeight()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: GrowingTextView
        weak var textView: NSTextView?

        init(_ parent: GrowingTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            reportHeight()
        }

        /// Enter sends. Shift+Enter arrives as a different selector, and inserts a
        /// newline like any other text view.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            default:
                return false
            }
        }

        /// Height of the laid-out text plus the insets — the frame then hugs the
        /// content, which is the only way a single line reads as centred.
        func reportHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer
            else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let line = layoutManager.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 14))
            let height = min(GrowingTextView.maxHeight,
                             max(line, used) + GrowingTextView.inset.height * 2)
            if abs(parent.measuredHeight - height) > 0.5 {
                parent.measuredHeight = height
            }
        }
    }
}

/// The Direct-mode composer: a growing box where Enter sends and Shift+Enter adds
/// a line, plus the saved-prompt list.
struct DirectComposer: View {
    @Binding var text: String
    let placeholder: String
    let savedPrompts: [String]
    let onSend: () -> Void
    let onSavePrompt: (String) -> Void
    let onDeletePrompt: (String) -> Void

    @State private var height: CGFloat = 32

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !savedPrompts.isEmpty || !text.isEmpty {
                promptMenu
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    // Same insets as the text view, so the placeholder sits exactly
                    // where the first character will.
                    Text(placeholder)
                        .font(AtlasTheme.Typography.body)
                        .foregroundColor(AtlasTheme.Colors.textSubtle)
                        .padding(.leading, GrowingTextView.inset.width)
                        .padding(.top, GrowingTextView.inset.height)
                        .allowsHitTesting(false)
                }
                GrowingTextView(text: $text, measuredHeight: $height, onSubmit: onSend)
            }
            .frame(height: height)
        }
    }

    private var promptMenu: some View {
        Menu {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Save this prompt") { onSavePrompt(text) }
                Divider()
            }
            ForEach(savedPrompts, id: \.self) { prompt in
                Button(String(prompt.prefix(60))) { text = prompt }
            }
            if !savedPrompts.isEmpty {
                Divider()
                Menu("Remove") {
                    ForEach(savedPrompts, id: \.self) { prompt in
                        Button(String(prompt.prefix(60))) { onDeletePrompt(prompt) }
                    }
                }
            }
        } label: {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 13))
                .foregroundColor(AtlasTheme.Colors.textMuted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 18)
        .padding(.bottom, 5)
        .help("Saved prompts")
    }
}

/// What the request is doing right now, shown only while a reply is in flight.
///
/// Featherless answers instantly with heartbeat comments and only starts real
/// tokens once the model is loaded, so a cold 27B can sit silent for half a
/// minute. Showing "queued" for that period is the difference between waiting
/// and wondering whether it hung.
struct StreamStatusLine: View {
    let progress: DirectChatProgress

    /// Ticks the clock while queued so the seconds actually count up.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.55)
                .frame(width: 11, height: 11)
            if progress.isQueued {
                Text("Queued at Featherless")
                    .foregroundColor(AtlasTheme.Colors.textSecondary)
                Text("\(seconds)s")
                    .foregroundColor(AtlasTheme.Colors.textSubtle)
            } else {
                Text("Generating")
                    .foregroundColor(AtlasTheme.Colors.champagneGold)
                if let rate = progress.tokensPerSecond {
                    Text(String(format: "%.0f tok/s", rate))
                        .foregroundColor(AtlasTheme.Colors.textSubtle)
                }
            }
        }
        .font(AtlasTheme.Typography.monoSmall)
        .onReceive(tick) { now = $0 }
    }

    private var seconds: Int {
        guard let started = progress.startedAt else { return 0 }
        return max(0, Int(now.timeIntervalSince(started)))
    }
}

/// The same numbers once the reply has landed, kept quiet at the trailing edge.
struct StreamStatsLabel: View {
    let progress: DirectChatProgress

    var body: some View {
        if let ttft = progress.timeToFirstToken, progress.finishedAt != nil {
            HStack(spacing: 5) {
                Text(String(format: "%.1fs to first token", ttft))
                if let rate = progress.tokensPerSecond {
                    Text("·")
                    Text(String(format: "%.0f tok/s", rate))
                }
            }
            .font(AtlasTheme.Typography.monoSmall)
            .foregroundColor(AtlasTheme.Colors.textSubtle)
        }
    }
}

/// How full the context window is. Featherless caps at 32K, and once that fills,
/// older turns get condensed — this is the warning before that happens.
struct ContextMeter: View {
    let fill: Double
    let contextTokens: Int

    private var color: Color {
        if fill > 0.9 { return AtlasTheme.Colors.error }
        if fill > 0.7 { return AtlasTheme.Colors.warning }
        return AtlasTheme.Colors.champagneGold.opacity(0.7)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("CTX")
                .font(AtlasTheme.Typography.label)
                .tracking(1.2)
                .foregroundColor(AtlasTheme.Colors.textMuted)
            ZStack(alignment: .leading) {
                Capsule().fill(AtlasTheme.Colors.trackWash).frame(width: 56, height: 4)
                Capsule().fill(color).frame(width: max(2, 56 * fill), height: 4)
            }
            Text("\(Int(fill * 100))%")
                .font(AtlasTheme.Typography.monoSmall)
                .foregroundColor(AtlasTheme.Colors.textSubtle)
        }
        .help("\(contextTokens / 1024)K window. Past full, earlier turns are condensed into a summary.")
    }
}

/// The strip between transcript and composer: what the conversation is doing, or
/// what you can do to it, plus how full the context window is.
///
/// Streaming and idle share one row on purpose — showing the action buttons
/// mid-reply left an empty line with the meter stranded on the right.
///
/// These are native buttons rather than controls inside the transcript: the
/// transcript web view has no script message handler by design, so the page has
/// no way to call back into the app.
struct TranscriptMetaBar: View {
    @ObservedObject var session: DirectChatSession
    let onEditLast: () -> Void
    @Binding var exportNotice: String?

    private var hasConversation: Bool { !session.messages.isEmpty }

    var body: some View {
        if hasConversation || session.isStreaming {
            HStack(spacing: AtlasTheme.Spacing.sm) {
                if session.isStreaming {
                    StreamStatusLine(progress: session.progress)
                } else {
                    if session.lastReplyTruncated {
                        action("Continue", icon: "text.append", accent: true) { session.continueReply() }
                            .help("The reply stopped at the token limit. Pick up where it left off.")
                    }
                    action("Regenerate", icon: "arrow.triangle.2.circlepath") { session.regenerate() }
                    action("Edit last", icon: "pencil", action: onEditLast)
                        .help("Put your last message back in the composer and re-run from there.")
                    action("Export", icon: "square.and.arrow.up", action: export)
                        .help("Write this conversation into the Obsidian vault")
                }

                Spacer(minLength: AtlasTheme.Spacing.md)

                if let exportNotice {
                    Text(exportNotice)
                        .font(AtlasTheme.Typography.monoSmall)
                        .foregroundColor(AtlasTheme.Colors.champagneLight)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if !session.isStreaming {
                    StreamStatsLabel(progress: session.progress)
                }

                ContextMeter(fill: session.contextFill, contextTokens: session.settings.contextTokens)
            }
            .frame(height: 22)
            .padding(.horizontal, AtlasTheme.Spacing.md)
            .padding(.vertical, AtlasTheme.Spacing.sm)
        }
    }

    private func action(_ title: String, icon: String, accent: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title).font(AtlasTheme.Typography.footnote)
            }
            .foregroundColor(accent ? AtlasTheme.Colors.champagneGold : AtlasTheme.Colors.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(accent ? AtlasTheme.Colors.champagneMuted : AtlasTheme.Colors.chipWash)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(accent ? AtlasTheme.Colors.champagneGlow
                                             : AtlasTheme.Colors.borderSubtle, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func export() {
        do {
            let url = try session.exportToVault()
            exportNotice = "Exported \(url.lastPathComponent)"
            NSWorkspace.shared.open(url)
        } catch {
            exportNotice = error.localizedDescription
        }
    }
}

/// Everything that does not need to be on the header bar all the time.
struct DirectSettingsPopover: View {
    @ObservedObject var session: DirectChatSession
    @State private var personaText = ""
    @State private var editingModelPersona = false

    private var model: String { session.settings.model }

    var body: some View {
        VStack(alignment: .leading, spacing: AtlasTheme.Spacing.md) {
            SamplingControls(
                temperature: $session.settings.temperature,
                maxTokens: $session.settings.maxTokens
            )

            Divider()

            Toggle("Read replies aloud", isOn: $session.settings.speakReplies)
                .toggleStyle(.switch)
                .font(AtlasTheme.Typography.caption)
                .foregroundColor(AtlasTheme.Colors.textSecondary)
                .help("Separate from the Sovereign voice setting.")

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $editingModelPersona) {
                    Text("Default persona").tag(false)
                    Text("This model only").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: editingModelPersona) { _ in loadPersona() }

                TextEditor(text: $personaText)
                    .font(AtlasTheme.Typography.monoSmall)
                    .scrollContentBackground(.hidden)
                    .background(AtlasTheme.Colors.cardSurface)
                    .frame(width: 340, height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.sm, style: .continuous))

                HStack {
                    Text(editingModelPersona
                         ? (session.settings.modelPersonas[model] == nil
                            ? "No override — this model uses the default."
                            : "Overrides the default for this model.")
                         : "Used by every model without its own.")
                        .font(AtlasTheme.Typography.footnote)
                        .foregroundColor(AtlasTheme.Colors.textSubtle)
                    Spacer()
                    if editingModelPersona && session.settings.modelPersonas[model] != nil {
                        Button("Clear") {
                            session.settings.modelPersonas[model] = nil
                            loadPersona()
                        }
                        .buttonStyle(.link)
                    }
                    Button("Save") { savePersona() }
                        .disabled(personaText == currentPersona)
                }
            }
        }
        .padding(AtlasTheme.Spacing.lg)
        .frame(width: 380)
        .onAppear(perform: loadPersona)
    }

    private var currentPersona: String {
        editingModelPersona ? (session.settings.modelPersonas[model] ?? "")
                            : session.settings.defaultPersona
    }

    private func loadPersona() { personaText = currentPersona }

    private func savePersona() {
        if editingModelPersona {
            let trimmed = personaText.trimmingCharacters(in: .whitespacesAndNewlines)
            session.settings.modelPersonas[model] = trimmed.isEmpty ? nil : personaText
        } else {
            session.settings.defaultPersona = personaText
        }
    }
}
