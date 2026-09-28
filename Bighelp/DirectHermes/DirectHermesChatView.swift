import SwiftUI

struct DirectHermesChatView: View {
    let chat: DirectHermesChat
    let store: DirectHermesWorkspaceStore
    @State private var showsSupport = false
    @State private var showsControls = false
    @State private var showsAttention = false
    @State private var composerFocusRequest = 0

    @BighelpThemeReader private var theme

    private var agentName: String {
        store.profiles.first(where: { $0.id == chat.client.profile })?.name ?? "Hermes"
    }

    var body: some View {
        VStack(spacing: 0) {
            if !chat.client.prompts.isEmpty {
                Button {
                    showsAttention = true
                } label: {
                    Label("Hermes needs your response",
                        systemImage: "exclamationmark.bubble")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityIdentifier("direct-hermes.attention")
            }
            if !chat.client.connected {
                Button("Reconnect to this host", systemImage: "arrow.clockwise") {
                    Task { await store.suspend(); await store.reconnect() }
                }
                .accessibilityIdentifier("direct-hermes.reconnect")
            }
            ChatView(model: chat.model, agentName: agentName, agentRole: chat.client.profile,
                agentStatus: "Direct · \(chat.client.status)",
                directHermesClient: chat.client,
                directHermesClarifications: chat.client.prompts.filter { $0.kind == .clarification },
                composerFocusRequest: composerFocusRequest,
                onAttachmentTap: nil,
                onProjectChangesTap: { showsSupport = true },
                onVoiceTap: { showsSupport = true },
                onApprovalTap: { _ in showsAttention = true },
                onPeopleTap: { showsSupport = true },
                onWorkspaceTap: { store.showSessions() },
                showsWorkspaceButton: true,
                onNewChatTap: { Task { await store.newChat() } },
                sessionControlAccessory: ChatSessionControlAccessory(
                    title: chat.client.modelName,
                    isEnabled: chat.client.connected,
                    accessibilityIdentifier: "direct-hermes.controls",
                    action: { showsControls = true }
                ),
                workspaceButtonLabel: "Chats")
                .environment(\.chatSurfaceCapabilities, .standaloneDirect)
        }
        .background(theme.canvas.ignoresSafeArea())
        .sheet(isPresented: $showsSupport) { DirectHermesSupportView() }
        .sheet(isPresented: $showsControls) { DirectHermesControlsView(chat: chat) }
        .sheet(isPresented: $showsAttention) { DirectHermesAttentionView(client: chat.client) }
        .task(id: chat.id) {
            // Match the app's new-chat preparation: mounting an empty native
            // chat is an explicit request to write, not to reopen account input.
            guard chat.model.items.isEmpty else { return }
            await Task.yield()
            composerFocusRequest += 1
        }
    }
}

private struct DirectHermesControlsView: View {
    let chat: DirectHermesChat
    @Environment(\.dismiss) private var dismiss
    @State private var modelIdentifier = ""
    @State private var commands: [(name: String, detail: String)] = []
    @State private var error: String?
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Current model", value: chat.client.modelName)
                    TextField("Model or provider:model identifier", text: $modelIdentifier)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("direct-hermes.model")
                    Button("Use for this session") {
                        isApplying = true
                        Task {
                            defer { isApplying = false }
                            do { try await chat.client.setSessionModel(modelIdentifier); error = nil }
                            catch { self.error = DirectHermesConversationClient.safeMessage(error) }
                        }
                    }
                    .disabled(isApplying || chat.model.isSending || modelIdentifier.isEmpty || !chat.client.connected)
                    .accessibilityIdentifier("direct-hermes.model-apply")
                } header: { Text("Model") } footer: {
                    Text("This changes only the native session, not profile defaults. Models stay fixed while a turn is running.")
                }
                if let error { Section { Text(error).foregroundStyle(.secondary) } }
                Section {
                    ForEach(commands, id: \.name) { command in
                        Button {
                            // Stage, never auto-send or erase an existing draft.
                            chat.model.draft += (chat.model.draft.isEmpty ? "" : "\n") + command.name + " "
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(command.name)
                                Text(command.detail).bighelpFont(.metadata).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Advanced · Host commands") } footer: {
                    Text("A command is inserted into your draft, never sent automatically. Review its arguments; some commands change host configuration.")
                }
            }
            .bighelpFormSurface()
            .navigationTitle("Session settings")
            // "Later", not "Done": the card's own Done is what answers.
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
            .task {
                modelIdentifier = chat.client.modelName
                do { commands = try await chat.client.commandCatalog() }
                catch { self.error = DirectHermesConversationClient.safeMessage(error) }
            }
        }
    }
}

struct DirectHermesAttentionView: View {
    let client: DirectHermesConversationClient
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(client.prompts) { prompt in
                    DirectHermesPromptResponseView(client: client, prompt: prompt)
                }

            }
            .navigationTitle("Needs attention")
            // "Later", not "Done": the card's own Done is what answers.
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
            .onChange(of: client.prompts.map(\.id)) { _, promptIDs in
                if promptIDs.isEmpty { dismiss() }
            }
        }
    }
}

struct DirectHermesPromptResponseView: View {
    let client: DirectHermesConversationClient
    let prompt: DirectHermesPrompt
    var inline = false

    @Environment(\.directHermesWorkspace) private var workspace
    @State private var customAnswers: [Int: String] = [:]
    @State private var selections: [Int: Set<Int>] = [:]
    @State private var initializedPromptID: String?
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        Group {
            if inline {
                BighelpCard {
                    VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                        Label(prompt.title, systemImage: "questionmark.bubble.fill")
                            .bighelpFont(.sectionTitle)
                        content
                    }
                }
            } else {
                Section {
                    content
                } header: {
                    Text(prompt.title)
                }
            }
        }
        .disabled(isSubmitting || !client.connected)
        .task(id: prompt.id) {
            initializeDrafts()
            guard prompt.presentationAcknowledgement != nil else { return }
            await workspace?.acknowledgePresentation(of: prompt)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let approval = prompt.approval {
            if let command = approval.command, !command.isEmpty {
                Text(command)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            if let description = approval.description, !description.isEmpty {
                Text(description).textSelection(.enabled)
            }
            ForEach(approval.choices, id: \.rawValue) { decision in
                Button(role: decision == .deny ? .destructive : nil) {
                    submitApproval(decision)
                } label: {
                    Text(decision.buttonTitle)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityHint(decision.accessibilityHint)
                .accessibilityIdentifier("direct-hermes.approval.\(decision.rawValue).\(prompt.id)")
            }
        } else if let clarification = prompt.clarification {
            ForEach(Array(clarification.questions.enumerated()), id: \.offset) { questionIndex, question in
                clarificationQuestion(question, questionIndex: questionIndex, clarification: clarification)
            }
            Button("Done") { submitClarification(clarification) }
                .disabled(completeAnswers(for: clarification) == nil)
                .accessibilityIdentifier("direct-hermes.clarification.done.\(prompt.id)")
        }

        Button("Cancel request", role: .cancel) { cancelPrompt() }
            .accessibilityHint("Cancels this prompt without sending a chat message.")
            .accessibilityIdentifier("direct-hermes.prompt.cancel.\(prompt.id)")

        if let error {
            Text(error).bighelpFont(.metadata).foregroundStyle(.secondary)
        }
        if isSubmitting { ProgressView("Sending response") }
    }

    @ViewBuilder
    private func clarificationQuestion(
        _ question: DirectHermesPrompt.Question,
        questionIndex: Int,
        clarification: DirectHermesPrompt.Clarification
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.question)
                .textSelection(.enabled)
                .accessibilityIdentifier(
                    "direct-hermes.clarification.question.\(questionIndex).\(prompt.id)"
                )
            if let locked = question.lockedAnswer {
                Label(locked, systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Locked answer: \(locked)")
            } else {
                ForEach(Array(question.choices.enumerated()), id: \.offset) { choiceIndex, choice in
                    let selected = selections[questionIndex, default: []].contains(choiceIndex)
                    Button {
                        choose(
                            choiceIndex,
                            questionIndex: questionIndex,
                            question: question,
                            clarification: clarification
                        )
                    } label: {
                        Label(choice, systemImage: selected ? "checkmark.circle.fill" : "circle")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "direct-hermes.clarification.question.\(questionIndex).choice.\(choiceIndex).\(prompt.id)"
                    )
                }

                TextField(
                    "Type another response",
                    text: Binding(
                        get: { customAnswers[questionIndex] ?? "" },
                        set: { value in
                            customAnswers[questionIndex] = value
                            if !value.isEmpty {
                                selections[questionIndex] = []
                            }
                        }
                    ),
                    axis: .vertical
                )
                .lineLimit(1...4)
                .submitLabel(.done)
                .onSubmit { submitClarification(clarification) }
                .accessibilityIdentifier(
                    "direct-hermes.clarification.question.\(questionIndex).custom.\(prompt.id)"
                )
            }
        }
    }

    private func initializeDrafts() {
        guard initializedPromptID != prompt.id, let clarification = prompt.clarification else { return }
        initializedPromptID = prompt.id
        customAnswers = [:]
        selections = [:]
        for index in clarification.questions.indices {
            selections[index] = []
        }
    }

    private func choose(
        _ choiceIndex: Int,
        questionIndex: Int,
        question: DirectHermesPrompt.Question,
        clarification: DirectHermesPrompt.Clarification
    ) {
        guard question.choices.indices.contains(choiceIndex) else { return }
        var selected = selections[questionIndex, default: []]
        if question.isMultiSelect {
            if selected.contains(choiceIndex) { selected.remove(choiceIndex) }
            else { selected.insert(choiceIndex) }
        } else {
            selected = [choiceIndex]
        }
        customAnswers[questionIndex] = ""
        selections[questionIndex] = selected
        guard let complete = completeAnswers(for: clarification),
              !requiresExplicitDone(clarification) else { return }
        submitClarification(clarification, complete: complete)
    }

    private func completeAnswers(
        for clarification: DirectHermesPrompt.Clarification
    ) -> [String: String]? {
        var result: [String: String] = [:]
        for (questionIndex, question) in clarification.questions.enumerated() {
            let answer: String
            if let locked = question.lockedAnswer {
                answer = locked
            } else {
                let custom = (customAnswers[questionIndex] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let selected = selections[questionIndex, default: []].sorted()
                if !custom.isEmpty {
                    answer = custom
                } else if question.isMultiSelect {
                    let values = selected.compactMap { index in
                        question.choices.indices.contains(index) ? question.choices[index] : nil
                    }
                    guard !values.isEmpty,
                          let data = try? JSONEncoder().encode(values),
                          let value = String(data: data, encoding: .utf8) else { return nil }
                    answer = value
                } else {
                    guard selected.count == 1,
                          let index = selected.first,
                          question.choices.indices.contains(index) else { return nil }
                    answer = question.choices[index]
                }
            }
            guard result.updateValue(answer, forKey: question.id) == nil else { return nil }
        }
        return result.count == clarification.questions.count ? result : nil
    }

    private func requiresExplicitDone(_ clarification: DirectHermesPrompt.Clarification) -> Bool {
        clarification.isBatch
            || clarification.questions.contains(where: \.isMultiSelect)
            || clarification.questions.enumerated().contains { index, question in
                !(customAnswers[index] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || question.choices.isEmpty
            }
    }

    private func submitApproval(_ decision: ApprovalDecision) {
        perform { try await client.respond(to: prompt, decision: decision) }
    }

    private func submitClarification(_ clarification: DirectHermesPrompt.Clarification) {
        guard let complete = completeAnswers(for: clarification) else { return }
        submitClarification(clarification, complete: complete)
    }

    private func submitClarification(
        _ clarification: DirectHermesPrompt.Clarification,
        complete: [String: String]
    ) {
        if clarification.isBatch {
            perform { try await client.respond(to: prompt, answers: complete) }
        } else if let question = clarification.questions.first,
                  let answer = complete[question.id] {
            perform { try await client.respond(to: prompt, value: answer) }
        }
    }

    private func cancelPrompt() {
        perform { try await client.cancel(prompt) }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isSubmitting else { return }
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do { try await operation() }
            catch { self.error = DirectHermesConversationClient.safeMessage(error) }
        }
    }
}
