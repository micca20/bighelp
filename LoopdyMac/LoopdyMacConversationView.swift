import SwiftUI

@MainActor
struct LoopdyMacConversationView: View {
    @Bindable var workspace: LoopdyFoundationWorkspace
    let composerFocused: Bool
    let onComposerFocusChange: (Bool) -> Void
    @FocusState private var localComposerFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let session = workspace.selectedSession {
                header(session)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(session.orderedEvents) { event in
                                message(event)
                                    .id(event.id)
                            }
                        }
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                    }
                    .onChange(of: session.orderedEvents.count) { _, _ in
                        guard let id = workspace.selectedSession?.orderedEvents.last?.id else { return }
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
                Divider()
                composer
            } else {
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Choose a session from the sidebar.")
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("mac.conversation-canvas")
    }

    private func header(_ session: LoopdyFoundationSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text("with \(session.agentName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("Fixture connected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Fixture conversation connected")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func message(_ event: LoopdyFoundationEvent) -> some View {
        HStack {
            if event.role == .user { Spacer(minLength: 52) }
            Text(event.text)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(event.role == .user ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.quaternary))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel(event.role == .user ? "You: \(event.text)" : "\(workspace.selectedSession?.agentName ?? "Assistant"): \(event.text)")
            if event.role == .assistant { Spacer(minLength: 52) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Loopdy", text: draftBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($localComposerFocus)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("mac.composer")
                .onSubmit { workspace.sendDraft() }
                .onChange(of: localComposerFocus) { _, value in onComposerFocusChange(value) }
                .onChange(of: composerFocused) { _, value in localComposerFocus = value }

            if workspace.isResponding {
                Button("Cancel", systemImage: "stop.fill") {
                    workspace.cancelResponse()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(".", modifiers: .command)
                .accessibilityHint("Stops the current fixture response")
            } else {
                Button("Send", systemImage: "arrow.up") {
                    workspace.sendDraft()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(workspace.selectedSession?.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
            }
        }
        .padding(16)
        .background(.bar)
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { workspace.selectedSession?.draft ?? "" },
            set: { workspace.updateDraft($0) }
        )
    }
}
