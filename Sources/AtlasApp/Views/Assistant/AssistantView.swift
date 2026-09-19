import SwiftUI
import AtlasCore
import Luminare

/// The Assistant page, which fronts two different brains.
///
/// **Direct** goes straight to an uncensored model on Featherless — no tools, no
/// approvals, nothing between the prompt and the reply but a short persona.
/// Transcripts are saved in the encrypted `ChatStore`.
///
/// **Sovereign** is the Hermes mission path, unchanged: context files, tool calls,
/// risk classification, approvals, and the activity ledger.
///
/// Both render into the same hardened transcript web view; see
/// `AssistantChatWebView` for why that web view is locked down the way it is.
struct AssistantView: View {
    @EnvironmentObject var appState: AtlasAppState
    @ObservedObject private var stateManager = SovereignPresenceStateManager.shared
    @ObservedObject private var voiceService = SovereignVoiceService.shared
    @ObservedObject private var hermesConnector = HermesConnector.shared
    @ObservedObject private var direct = DirectChatSession.shared

    @State private var mode = AssistantMode.restore()
    @State private var railOpen = false
    @State private var showingModelPicker = false
    @State private var showingSettings = false
    @State private var exportNotice: String? = nil
    /// Set while the composer holds an earlier message being rewritten.
    @State private var editingMessageID: String? = nil

    /// The Hermes-side transcript. Direct mode keeps its own in `DirectChatSession`.
    @State private var sovereignMessages: [ChatMessage] = [
        ChatMessage(
            role: .assistant,
            text: "Welcome to ATLAS Sovereign Assistant. Context selection extracts bounded files (up to 8KB per file / 32KB max, excluding secrets). How can I assist you with your mission today?",
            executionLocation: .local
        )
    ]
    @State private var inputText: String = ""
    @State private var isProcessing: Bool = false
    @State private var selectedProjects: Set<AtlasProject> = []
    @State private var selectedVaults: Set<AtlasVault> = []
    @State private var activeMissionToken: SovereignMissionToken? = nil
    @State private var activeHermesHandle: HermesRequestHandle? = nil
    /// The message currently being written into, so the page can show a cursor.
    @State private var streamingMessageID: String? = nil
    /// Owns the transcript web view. Held here so streaming updates reach a
    /// page that outlives any single body evaluation.
    @State private var chat = AssistantChatBridge()

    private var isOffline: Bool {
        let authState = hermesConnector.authState
        return authState == .loginRequired || authState == .notInstalled || authState == .notConfigured
    }

    /// Direct mode cannot run without a Featherless key.
    private var directUnavailable: Bool { !FeatherlessClient.shared.hasKey }

    private var isBusy: Bool { mode == .direct ? direct.isStreaming : isProcessing }

    private var visibleMessages: [ChatMessage] {
        mode == .direct ? direct.messages : sovereignMessages
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(AtlasTheme.Colors.borderLuminous)

            HStack(spacing: 0) {
                if railOpen && mode == .direct {
                    ConversationRail(session: direct, isOpen: $railOpen)
                        .transition(.move(edge: .leading))
                }
                // Both modes render here; see AssistantChatWebView.
                AssistantChatWebView(bridge: chat)
            }

            Divider().background(AtlasTheme.Colors.borderLuminous)

            inputBar
        }
        .onAppear {
            syncPresenceStateWithSystem()
            voiceService.warmWorker()
            pushTranscript()

            if let pending = appState.pendingAssistantProjectContext {
                selectedProjects.insert(pending)
                appState.pendingAssistantProjectContext = nil
                // A project handed over from elsewhere is a Hermes job.
                mode = .sovereign
            }
        }
        .onChange(of: hermesConnector.authState) { _ in
            syncPresenceStateWithSystem()
        }
        .onChange(of: mode) { _ in
            // The other mode's transcript is a different conversation entirely,
            // so the page is replaced rather than patched.
            chat.setAll(visibleMessages, streamingID: streamingMessageID)
        }
        .onChange(of: inputText) { newValue in
            if !newValue.isEmpty && stateManager.currentState == .idle && !isBusy {
                stateManager.setRestingState(.listening)
            } else if newValue.isEmpty && stateManager.currentState == .listening {
                stateManager.setRestingState(.idle)
            }
        }
        .onChange(of: direct.messages) { _ in
            guard mode == .direct else { return }
            streamingMessageID = direct.isStreaming ? direct.messages.last?.id : nil
            pushTranscript()
        }
        .onChange(of: direct.isStreaming) { streaming in
            guard mode == .direct else { return }
            if !streaming {
                streamingMessageID = nil
                pushTranscript()
                speakDirectReplyIfWanted()
            }
        }
        .sheet(isPresented: $showingModelPicker) {
            ModelPickerSheet(session: direct)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AtlasTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Assistant")
                        .font(AtlasTheme.Typography.headline)
                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                    ModeToggle(mode: $mode)
                }
                Text(mode == .direct
                     ? (direct.conversationTitle.isEmpty ? "Direct model · no tools" : direct.conversationTitle)
                     : "Direct Sovereign Agent mission interface")
                    .font(AtlasTheme.Typography.caption)
                    .foregroundColor(AtlasTheme.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if mode == .direct {
                directControls
            } else {
                sovereignContextPickers
            }
        }
        .padding(AtlasTheme.Spacing.lg)
        .background(AtlasTheme.Colors.surfaceDark)
    }

    private var directControls: some View {
        HStack(spacing: AtlasTheme.Spacing.md) {
            ModelBadge(modelID: direct.settings.model, showingPicker: $showingModelPicker)

            if voiceService.state.isPlaying || stateManager.currentState == .speaking {
                Button(action: stopSpeaking) {
                    HStack(spacing: 5) {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 11))
                        Text("Stop")
                            .font(AtlasTheme.Typography.footnote)
                    }
                    .foregroundColor(AtlasTheme.Colors.champagneGold)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(AtlasTheme.Colors.champagneGlow)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Stop speaking")
            }

            // Sampling, voice and personas live behind this rather than on the
            // bar — the header was turning into a cockpit for settings that are
            // changed occasionally.
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .foregroundColor(AtlasTheme.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .help("Sampling, voice and persona")
            .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                DirectSettingsPopover(session: direct)
            }

            Button {
                direct.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12))
                    .foregroundColor(AtlasTheme.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .help("New conversation")

            Button {
                withAnimation(.easeOut(duration: 0.16)) { railOpen.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12))
                    .foregroundColor(railOpen ? AtlasTheme.Colors.champagneGold
                                              : AtlasTheme.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .help("Saved conversations")
        }
    }

    private var sovereignContextPickers: some View {
        HStack(spacing: 8) {
            if voiceService.state.isPlaying || stateManager.currentState == .speaking {
                Button(action: stopSpeaking) {
                    HStack(spacing: 5) {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 11))
                        Text("Stop")
                            .font(AtlasTheme.Typography.footnote)
                    }
                    .foregroundColor(AtlasTheme.Colors.champagneGold)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(AtlasTheme.Colors.champagneGlow)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Stop speaking")
            }

            Menu {
                ForEach(appState.projects) { p in
                    Button(action: {
                        if selectedProjects.contains(p) { selectedProjects.remove(p) }
                        else { selectedProjects.insert(p) }
                    }) {
                        HStack {
                            Text(p.name)
                            if selectedProjects.contains(p) { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(selectedProjects.isEmpty ? "Context Projects (\(appState.projects.count))" : "\(selectedProjects.count) Selected")
                }
                .font(AtlasTheme.Typography.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(AtlasTheme.Colors.champagneMuted)
                .foregroundColor(AtlasTheme.Colors.textPrimary)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(appState.vaults) { v in
                    Button(action: {
                        if selectedVaults.contains(v) { selectedVaults.remove(v) }
                        else { selectedVaults.insert(v) }
                    }) {
                        HStack {
                            Text(v.name)
                            if selectedVaults.contains(v) { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                    Text(selectedVaults.isEmpty ? "Context Vaults (\(appState.vaults.count))" : "\(selectedVaults.count) Selected")
                }
                .font(AtlasTheme.Typography.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(AtlasTheme.Colors.champagneMuted)
                .foregroundColor(AtlasTheme.Colors.textPrimary)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        VStack(spacing: 0) {
            if mode == .direct, let error = direct.lastError {
                notice(error, color: AtlasTheme.Colors.error)
            } else if mode == .direct, directUnavailable {
                notice("No Featherless API key. Set FEATHERLESS_API_KEY in ~/.hermes/.env, or add one in Settings.",
                       color: AtlasTheme.Colors.warning)
            } else if mode == .direct, direct.didSummarize {
                notice("Earlier turns were condensed to stay inside this model's context window.",
                       color: AtlasTheme.Colors.textMuted)
            }

            if mode == .direct {
                TranscriptMetaBar(session: direct, onEditLast: editLastMessage,
                                  exportNotice: $exportNotice)
                Divider().background(AtlasTheme.Colors.borderSubtle)
            }

            HStack(alignment: .bottom, spacing: 10) {
                if mode == .direct {
                    DirectComposer(
                        text: $inputText,
                        placeholder: "Message the model…",
                        savedPrompts: direct.settings.savedPrompts,
                        onSend: send,
                        onSavePrompt: { prompt in
                            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty,
                                  !direct.settings.savedPrompts.contains(trimmed) else { return }
                            direct.settings.savedPrompts.append(trimmed)
                        },
                        onDeletePrompt: { prompt in
                            direct.settings.savedPrompts.removeAll { $0 == prompt }
                        }
                    )
                } else {
                    TextField("Send mission prompt to Sovereign Agent…", text: $inputText)
                        .font(AtlasTheme.Typography.body)
                        .textFieldStyle(.plain)
                        .foregroundColor(AtlasTheme.Colors.textPrimary)
                        .onSubmit { send() }
                }

                if isBusy {
                    Button(action: cancel) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(AtlasTheme.Colors.error)
                            .frame(width: 24, height: 24)
                            .background(AtlasTheme.Colors.error.opacity(0.16))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(AtlasTheme.Colors.error.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 2)
                    .help(mode == .direct ? "Stop generating" : "Cancel mission")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(sendDisabled ? AtlasTheme.Colors.textMuted : AtlasTheme.Colors.champagneGold)
                            .shadow(color: sendDisabled ? Color.clear : AtlasTheme.Colors.champagneGold.opacity(0.5), radius: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(sendDisabled)
                    .padding(.bottom, 1)
                    .help("Send · Shift+Enter for a new line")
                }
            }
            .padding(.horizontal, AtlasTheme.Spacing.md)
            .padding(.vertical, AtlasTheme.Spacing.sm)
        }
        .background(AtlasTheme.Colors.cardElevated)
        .clipShape(RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AtlasTheme.CornerRadius.lg, style: .continuous)
                .stroke(AtlasTheme.Gradients.cardBorder, lineWidth: 1)
        )
        .padding(AtlasTheme.Spacing.lg)
        .background(AtlasTheme.Colors.surfaceDark)
    }

    private var sendDisabled: Bool {
        if inputText.isEmpty { return true }
        return mode == .direct ? directUnavailable : isOffline
    }

    private func notice(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text(text)
                .font(AtlasTheme.Typography.footnote)
                .lineLimit(2)
            Spacer()
        }
        .foregroundColor(color)
        .padding(.horizontal, AtlasTheme.Spacing.md)
        .padding(.top, AtlasTheme.Spacing.sm)
    }

    // MARK: - Transcript plumbing

    /// Pushes only what changed; see `AssistantChatBridge.sync`.
    private func pushTranscript() {
        chat.sync(visibleMessages, streamingID: streamingMessageID)
    }

    /// Puts the last thing you said back in the composer. Sending again rewrites
    /// the conversation from that point, discarding what followed.
    private func editLastMessage() {
        guard let last = direct.messages.last(where: { $0.role == .user }) else { return }
        inputText = last.text
        editingMessageID = last.id
    }

    private func send() {
        guard !sendDisabled else { return }
        let prompt = inputText
        inputText = ""
        switch mode {
        case .direct: sendDirect(prompt)
        case .sovereign: sendMission(prompt)
        }
    }

    private func cancel() {
        switch mode {
        case .direct:
            direct.stop()
            streamingMessageID = nil
            pushTranscript()
        case .sovereign:
            cancelMission()
        }
    }

    // MARK: - Direct mode

    private func sendDirect(_ prompt: String) {
        // A new prompt supersedes whatever is being spoken.
        voiceService.stop()
        exportNotice = nil
        if let editing = editingMessageID {
            editingMessageID = nil
            direct.editAndResend(editing, to: prompt)
        } else {
            direct.send(prompt)
        }
        streamingMessageID = direct.messages.last?.id
        pushTranscript()
    }

    /// Direct mode has its own voice switch, deliberately separate from the
    /// Hermes auto-speak setting.
    private func speakDirectReplyIfWanted() {
        guard direct.settings.speakReplies,
              direct.lastError == nil,
              let reply = direct.messages.last,
              reply.role == .assistant,
              !reply.text.isEmpty
        else { return }
        voiceService.speak(text: reply.text, deliveryMode: .conversational)
    }

    // MARK: - Sovereign mode

    private func syncPresenceStateWithSystem() {
        guard !isBusy else { return }
        if mode == .sovereign && isOffline {
            stateManager.setRestingState(.offline)
        } else if EmergencyStopManager.shared.isEmergencyStopActive {
            stateManager.setRestingState(.error)
        } else if stateManager.currentState == .offline || stateManager.currentState == .error {
            stateManager.setRestingState(.idle)
        }
    }

    private func sendMission(_ prompt: String) {
        guard !isProcessing else { return }

        // Stop active Sovereign voice session immediately when a new prompt is sent
        voiceService.stop()

        let userMsg = ChatMessage(role: .user, text: prompt, executionLocation: .local)
        sovereignMessages.append(userMsg)

        isProcessing = true

        let streamMsg = ChatMessage(role: .assistant, text: "Thinking…", executionLocation: .local)
        sovereignMessages.append(streamMsg)
        let assistantMsgId = streamMsg.id
        streamingMessageID = assistantMsgId
        pushTranscript()

        // Warm voice worker
        voiceService.warmWorker()

        // Begin new mission token
        let mission = stateManager.beginMission(description: prompt)
        self.activeMissionToken = mission

        // Check security governance approval requirement
        let riskTier = SecurityGovernance.shared.classifyAction(toolName: "HermesTask", payload: prompt)
        if SecurityGovernance.shared.requiresApproval(tier: riskTier) {
            stateManager.transition(to: .awaitingApproval, for: mission)
        }

        let handle = hermesConnector.sendMessage(
            prompt: prompt,
            contextProjects: Array(selectedProjects),
            contextVaults: Array(selectedVaults),
            onToken: { partial in
                DispatchQueue.main.async {
                    guard self.stateManager.isMissionActive(mission) else { return }
                    if let idx = sovereignMessages.firstIndex(where: { $0.id == assistantMsgId }) {
                        sovereignMessages[idx].text = partial
                        pushTranscript()
                    }
                    // Streaming tokens do NOT trigger .speaking state!
                }
            },
            onCompletion: { finalMsg in
                DispatchQueue.main.async {
                    guard self.stateManager.isMissionActive(mission) else { return }

                    // Hermes returns a message with a fresh id. Re-stamping it
                    // with the streaming id keeps it the same node in the page,
                    // instead of stranding the "Thinking…" bubble above it.
                    let settled = finalMsg.withID(assistantMsgId)
                    if let idx = sovereignMessages.firstIndex(where: { $0.id == assistantMsgId }) {
                        sovereignMessages[idx] = settled
                    }
                    self.isProcessing = false
                    self.streamingMessageID = nil
                    self.activeHermesHandle = nil
                    pushTranscript()

                    // Evaluate ending state
                    let endingState: SovereignState
                    if finalMsg.isPendingApproval {
                        endingState = .awaitingApproval
                    } else if finalMsg.text.contains("Authentication Required") || finalMsg.text.contains("Expired") {
                        endingState = .offline
                    } else if finalMsg.text.contains("Execution Blocked") || finalMsg.text.contains("failed") {
                        endingState = .error
                    } else {
                        endingState = .idle
                    }

                    // Check if voice should speak completed message
                    if self.voiceService.isVoiceEnabled && self.voiceService.isAutoSpeakEnabled && endingState == .idle {
                        self.stateManager.transition(to: .preparingSpeech, for: mission)

                        self.voiceService.speak(
                            text: finalMsg.text,
                            deliveryMode: .conversational,
                            for: mission,
                            onPlaybackStarted: {
                                // Handled automatically by service state transition to .speaking
                            },
                            onPlaybackCompleted: { outcome in
                                DispatchQueue.main.async {
                                    guard self.stateManager.isMissionActive(mission) else { return }

                                    // Voice failure or completion: preserve text and complete mission with original Hermes ending state
                                    self.stateManager.completeMission(mission, endingState: endingState)
                                    self.activeMissionToken = nil
                                    self.appState.refreshAllData()
                                }
                            }
                        )
                    } else {
                        // Voice disabled or non-speaking ending state: complete mission immediately
                        self.stateManager.completeMission(mission, endingState: endingState)
                        self.activeMissionToken = nil
                        self.appState.refreshAllData()
                    }
                }
            }
        )

        self.activeHermesHandle = handle
    }

    private func stopSpeaking() {
        voiceService.stop()
        if let mission = activeMissionToken {
            stateManager.completeMission(mission, endingState: .idle)
            activeMissionToken = nil
        } else {
            stateManager.setRestingState(.idle)
        }
    }

    private func cancelMission() {
        isProcessing = false
        streamingMessageID = nil

        voiceService.stop()

        if let handle = activeHermesHandle {
            handle.cancel()
            activeHermesHandle = nil
        }

        if let mission = activeMissionToken {
            stateManager.interruptMission(mission)
            activeMissionToken = nil
        } else {
            stateManager.interruptAll()
        }

        // Replace any pending "Thinking..." stream message with cancelled indicator
        if let lastMsg = sovereignMessages.last, lastMsg.role == .assistant, lastMsg.text == "Thinking…" {
            if let idx = sovereignMessages.firstIndex(where: { $0.id == lastMsg.id }) {
                sovereignMessages[idx] = ChatMessage(id: lastMsg.id, role: .assistant,
                                                     text: "❌ Mission Cancelled.", executionLocation: .local)
            }
        }
        pushTranscript()
    }
}
