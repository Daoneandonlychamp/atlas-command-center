import SwiftUI
import AtlasCore

/// Direct chat in the menu bar, for the question that is not worth opening a
/// window for.
///
/// It is the *same* conversation as the Assistant page — one `DirectChatSession`,
/// one encrypted store — so a thread started here is already open in the app, and
/// vice versa. Only the chrome is smaller.
struct MenuBarChatView: View {
    @ObservedObject private var session = DirectChatSession.shared
    @State private var input = ""
    @State private var chat = AssistantChatBridge()

    /// The Assistant page has its own bridge; this one drives its own copy of the
    /// page, so both stay in step with the session rather than with each other.
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(AtlasTheme.Colors.borderLuminous)

            AssistantChatWebView(bridge: chat)
                .frame(minHeight: 260)

            Divider().background(AtlasTheme.Colors.borderLuminous)

            if session.isStreaming {
                StreamStatusLine(progress: session.progress)
                    .padding(.horizontal, AtlasTheme.Spacing.md)
                    .padding(.top, 6)
            }

            HStack(alignment: .bottom, spacing: 10) {
                DirectComposer(
                    text: $input,
                    placeholder: "Ask…",
                    savedPrompts: session.settings.savedPrompts,
                    onSend: send,
                    onSavePrompt: { _ in },
                    onDeletePrompt: { _ in }
                )
                if session.isStreaming {
                    Button(action: session.stop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(AtlasTheme.Colors.error)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 4)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(input.isEmpty ? AtlasTheme.Colors.textMuted
                                                           : AtlasTheme.Colors.champagneGold)
                    }
                    .buttonStyle(.plain)
                    .disabled(input.isEmpty)
                    .padding(.bottom, 4)
                }
            }
            .padding(AtlasTheme.Spacing.md)
        }
        .frame(width: 460, height: 560)
        .background(AtlasTheme.Colors.background)
        .onAppear { chat.setAll(session.messages, streamingID: streamingID) }
        .onChange(of: session.messages) { _ in
            chat.sync(session.messages, streamingID: streamingID)
        }
    }

    private var streamingID: String? {
        session.isStreaming ? session.messages.last?.id : nil
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(FeatherlessModel.displayName(session.settings.model))
                .font(AtlasTheme.Typography.caption)
                .foregroundColor(AtlasTheme.Colors.textPrimary)
                .lineLimit(1)
            if FeatherlessModel.looksUncensored(session.settings.model) {
                UncensoredFlag()
            }
            Spacer()
            Button {
                session.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11))
                    .foregroundColor(AtlasTheme.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .help("New conversation")

            Button {
                AtlasMenuBarController.shared.openAssistantWindow()
            } label: {
                HStack(spacing: 4) {
                    Text("Open ATLAS")
                    Image(systemName: "arrow.up.right")
                }
                .font(AtlasTheme.Typography.footnote)
                .foregroundColor(AtlasTheme.Colors.champagneGold)
            }
            .buttonStyle(.plain)
            .help("Show this conversation in the Assistant page")
        }
        .padding(.horizontal, AtlasTheme.Spacing.md)
        .padding(.vertical, AtlasTheme.Spacing.sm)
        .background(AtlasTheme.Colors.surfaceDark)
    }

    private func send() {
        let prompt = input
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        input = ""
        session.send(prompt)
    }
}
