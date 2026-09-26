import SwiftUI

struct WatchCompanionRootView: View {
    @Bindable var store: WatchCompanionStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: WatchDesign.Spacing.standard) {
                        Image("BighelpMarkColor")
                            .resizable().scaledToFit().frame(width: 28, height: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: WatchDesign.Spacing.tight) {
                            Text("bighelp").font(.headline)
                            Text(store.isFresh ? store.phoneLinkLabel : "Waiting for iPhone")
                                .font(.caption2).foregroundStyle(WatchDesign.Color.secondaryText)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    NavigationLink {
                        WatchSessionsPage(store: store)
                    } label: {
                        WatchMenuRow(title: "Voice & chats", subtitle: "Choose a session", symbol: "waveform", count: nil)
                    }
                    NavigationLink {
                        WatchAttentionPage(store: store)
                    } label: {
                        WatchMenuRow(title: "Needs you", subtitle: "Questions & updates", symbol: "bubble.left.and.exclamationmark.bubble.right", count: store.snapshot.inbox.count)
                    }
                    NavigationLink {
                        WatchApprovalsPage(store: store)
                    } label: {
                        WatchMenuRow(title: "Approvals", subtitle: "Review exact scope", symbol: "checkmark.shield", count: store.snapshot.approvals.count)
                    }
                    NavigationLink {
                        WatchConnectionsPage(store: store)
                    } label: {
                        WatchMenuRow(title: "Connections", subtitle: store.connectionLabel, symbol: "iphone.radiowaves.left.and.right", count: nil)
                    }
                }
                if store.hasPendingRequest || store.lastReceipt != nil {
                    Section("Latest request") { WatchRequestStatus(store: store) }
                }
                if let error = store.errorMessage {
                    Section {
                        Text(error).font(.caption)
                        Button("Dismiss notice") { store.clearNotice() }
                    }
                }
            }
            .navigationTitle(" ")
            .listStyle(.carousel)
            .background(WatchDesign.Color.canvas)
        }
        .tint(WatchDesign.Color.orange)
        .privacySensitive()
        .task { store.foreground(true) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.foreground(true) }
            // System dictation may make the app inactive. Only background cancels it.
            if phase == .background { store.foreground(false) }
        }
    }
}

private struct WatchMenuRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let count: Int?
    var body: some View {
        HStack(spacing: WatchDesign.Spacing.standard) {
            Image(systemName: symbol)
                .foregroundStyle(WatchDesign.Color.orange)
                .frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WatchDesign.Spacing.tight) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption2).foregroundStyle(WatchDesign.Color.secondaryText)
            }
            if let count, count > 0 {
                Spacer(minLength: 0)
                Text(count, format: .number).font(.caption.bold()).monospacedDigit()
            }
        }
        .frame(minHeight: WatchDesign.minimumControlHeight)
        .accessibilityElement(children: .combine)
    }
}

private struct WatchRequestStatus: View {
    @Bindable var store: WatchCompanionStore
    var targetID: String? = nil
    private var matches: Bool {
        targetID == nil || store.pendingTargetID == targetID || store.lastReceipt?.targetID == targetID
    }
    var body: some View {
        if matches {
            VStack(alignment: .leading, spacing: WatchDesign.Spacing.standard) {
                if let text = store.statusMessage {
                    Label(text, systemImage: symbol).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.hasPendingRequest {
                    Button("Check status", systemImage: "arrow.clockwise") { store.checkStatus() }
                        .disabled(!store.isReachable)
                    if store.isWaiting {
                        Button("Stop waiting") { store.stopWaiting() }
                        Text("This does not cancel work already sent to iPhone.")
                            .font(.caption2).foregroundStyle(WatchDesign.Color.secondaryText)
                    }
                }
            }
        }
        if let error = store.errorMessage {
            Text(error).font(.caption).foregroundStyle(WatchDesign.Color.danger)
        }
    }
    private var symbol: String {
        if store.hasPendingRequest { return "clock" }
        return store.lastReceipt?.phase == .committed ? "checkmark.circle" : "exclamationmark.circle"
    }
}

private struct WatchAttentionPage: View {
    @Bindable var store: WatchCompanionStore
    var body: some View {
        List {
            if store.snapshot.inbox.isEmpty {
                WatchEmptyState(title: store.isFresh ? "Nothing waiting" : "Waiting for iPhone", detail: "Refresh to check questions and updates.", store: store)
            }
            ForEach(store.snapshot.inbox) { item in
                NavigationLink {
                    WatchAttentionDetail(store: store, item: item, offer: store.state)
                } label: {
                    VStack(alignment: .leading, spacing: WatchDesign.Spacing.compact) {
                        Text(item.agentName).font(.caption2).foregroundStyle(WatchDesign.Color.orange)
                        Text(item.title).font(.headline).lineLimit(2)
                        Text(item.kind == .clarification ? "Needs an answer" : "Update")
                            .font(.caption2).foregroundStyle(WatchDesign.Color.secondaryText)
                    }
                    .frame(minHeight: WatchDesign.minimumControlHeight)
                }
            }
        }
        .navigationTitle("Needs you")
    }
}

private struct WatchAttentionDetail: View {
    @Bindable var store: WatchCompanionStore
    @State private var item: WatchInboxItem
    @State private var offer: WatchCompanionState?
    @State private var response = ""
    init(store: WatchCompanionStore, item: WatchInboxItem, offer: WatchCompanionState?) {
        self.store = store
        _item = State(initialValue: item)
        _offer = State(initialValue: offer)
    }
    private var canAct: Bool {
        store.canSend && store.snapshot.inbox.contains(item) && (offer?.isFresh == true)
            && (item.expiresAt.map { $0 > store.clock } ?? true)
            && !(store.lastReceipt?.targetID == item.id && store.lastReceipt?.phase == .committed)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WatchDesign.Spacing.section) {
                Text(item.agentName).font(.caption).foregroundStyle(WatchDesign.Color.orange)
                Text(item.title).font(.headline)
                Text(item.detail).font(.body).fixedSize(horizontal: false, vertical: true)
                if let expires = item.expiresAt {
                    Text("Expires \(expires.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(WatchDesign.Color.secondaryText)
                }
                if let reason = item.phoneActionReason {
                    Label(reason, systemImage: "iphone").font(.caption)
                } else if item.kind == .clarification {
                    ForEach(item.choices, id: \.self) { choice in
                        Button { store.submit(.respond(itemID: item.id, text: choice), offeredState: offer) } label: {
                            Text(choice).frame(maxWidth: .infinity, minHeight: WatchDesign.minimumControlHeight)
                        }.disabled(!canAct)
                    }
                    if item.allowsCustomResponse {
                        TextField("Your answer", text: $response)
                            .accessibilityHint("Use the system dictation or keyboard to enter an answer.")
                        Button("Send answer", systemImage: "paperplane") {
                            store.submit(.respond(itemID: item.id, text: response), offeredState: offer)
                        }
                        .disabled(!canAct || response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if item.canDismiss {
                    Button("Dismiss update") { store.submit(.dismissUpdate(item.id), offeredState: offer) }
                        .disabled(!canAct)
                }
                WatchRequestStatus(store: store, targetID: item.id)
                if !canAct && !store.hasPendingRequest {
                    Text("Refresh the list to get the latest request before acting.").font(.caption2)
                    Button("Refresh") { store.refresh() }
                }
            }.watchDetailPadding()
        }
        .navigationTitle("Review")
    }
}

private struct WatchApprovalsPage: View {
    @Bindable var store: WatchCompanionStore
    var body: some View {
        List {
            if store.snapshot.approvals.isEmpty {
                WatchEmptyState(title: "No approvals ready", detail: "Only complete, current permission requests are offered here. Other requests appear in Needs you.", store: store)
            }
            ForEach(store.snapshot.approvals, id: \.requestID) { request in
                NavigationLink {
                    WatchApprovalDetail(store: store, request: request, offer: store.state)
                } label: {
                    VStack(alignment: .leading, spacing: WatchDesign.Spacing.compact) {
                        Text(request.requester).font(.caption2).foregroundStyle(WatchDesign.Color.orange)
                        Text(request.action).font(.headline).lineLimit(3)
                    }.frame(minHeight: WatchDesign.minimumControlHeight)
                }
            }
        }.navigationTitle("Approvals")
    }
}

private struct WatchApprovalDetail: View {
    @Bindable var store: WatchCompanionStore
    @State private var request: WatchApprovalRequest
    @State private var offer: WatchCompanionState?
    init(store: WatchCompanionStore, request: WatchApprovalRequest, offer: WatchCompanionState?) {
        self.store = store
        _request = State(initialValue: request)
        _offer = State(initialValue: offer)
    }
    private var canAct: Bool {
        store.canSend && store.snapshot.approvals.contains(request) && offer?.isFresh == true
            && (request.expiresAt.map { $0 > store.clock } ?? false)
            && !(store.lastReceipt?.targetID == request.requestID && store.lastReceipt?.phase == .committed)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WatchDesign.Spacing.section) {
                WatchApprovalDisclosure(request: request)
                ForEach(request.allowedDecisions, id: \.rawValue) { decision in
                    if WatchApprovalConfirmationPolicy.requiresConfirmation(for: decision) {
                        NavigationLink {
                            WatchCompanionApprovalReview(store: store, request: request, decision: decision, offer: offer)
                        } label: {
                            Text("Review: \(decision.buttonTitle)")
                                .frame(maxWidth: .infinity, minHeight: WatchDesign.minimumControlHeight)
                        }.disabled(!canAct)
                    } else {
                        Button {
                            store.submit(.approve(requestID: request.requestID, decision: decision), offeredState: offer)
                        } label: {
                            Text(decision.buttonTitle).frame(maxWidth: .infinity, minHeight: WatchDesign.minimumControlHeight)
                        }
                        .disabled(!canAct)
                        .accessibilityIdentifier("watch.companion.approval.\(decision.rawValue)")
                    }
                }
                WatchRequestStatus(store: store, targetID: request.requestID)
                if !canAct && !store.hasPendingRequest {
                    Text("Refresh and reopen this approval if it has changed or expired.").font(.caption2)
                    Button("Refresh") { store.refresh() }
                }
            }.watchDetailPadding()
        }.navigationTitle("Permission")
    }
}

private struct WatchApprovalDisclosure: View {
    let request: WatchApprovalRequest
    var body: some View {
        VStack(alignment: .leading, spacing: WatchDesign.Spacing.standard) {
            Text(request.requester).font(.caption).foregroundStyle(WatchDesign.Color.orange)
            Text(request.action).font(.headline)
            if !request.vendor.isEmpty { Text(request.vendor).font(.caption) }
            if !request.amount.isEmpty { Text(request.amount).font(.body.bold()) }
            if !request.category.isEmpty { Text(request.category).font(.caption) }
            if let policy = request.policy, !policy.isEmpty {
                Text("Policy: \(policy)").font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Text(request.consequence).font(.body).fixedSize(horizontal: false, vertical: true)
            if let expiry = request.expiresAt {
                Text("Expires \(expiry.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(WatchDesign.Color.secondaryText)
            }
        }
    }
}

private struct WatchCompanionApprovalReview: View {
    @Bindable var store: WatchCompanionStore
    let request: WatchApprovalRequest
    let decision: WatchApprovalDecision
    let offer: WatchCompanionState?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WatchDesign.Spacing.section) {
                Label(decision.buttonTitle, systemImage: "checkmark.shield").font(.headline)
                Text(decision == .always
                     ? "Allows matching requests in future sessions. This is broader than approving once."
                     : "Allows matching requests for this session, not just this one action.")
                    .font(.body).fixedSize(horizontal: false, vertical: true)
                WatchApprovalDisclosure(request: request)
                Button {
                    store.submit(.approve(requestID: request.requestID, decision: decision), offeredState: offer)
                } label: {
                    Text("Confirm \(decision.buttonTitle)")
                        .frame(maxWidth: .infinity, minHeight: WatchDesign.minimumControlHeight)
                }
                .disabled(!store.canSend || !store.snapshot.approvals.contains(request)
                          || (store.lastReceipt?.targetID == request.requestID && store.lastReceipt?.phase == .committed)
                          || offer?.isFresh != true || (request.expiresAt.map { $0 <= store.clock } ?? true))
                .accessibilityIdentifier("watch.companion.approval.confirm")
                Button("Back without approving") { dismiss() }
                WatchRequestStatus(store: store, targetID: request.requestID)
            }.watchDetailPadding()
        }.navigationTitle("Review scope")
    }
}

private struct WatchSessionsPage: View {
    @Bindable var store: WatchCompanionStore
    var body: some View {
        List {
            Section {
                Text("Choose where to send your voice or text reply.")
                    .font(.caption).foregroundStyle(WatchDesign.Color.secondaryText)
            }
            if store.snapshot.sessions.isEmpty {
                WatchEmptyState(title: "Start on iPhone", detail: "Create a chat in bighelp on iPhone, then refresh here.", store: store)
            }
            ForEach(store.snapshot.sessions) { session in
                NavigationLink {
                    WatchSessionDetail(store: store, session: session)
                } label: {
                    VStack(alignment: .leading, spacing: WatchDesign.Spacing.compact) {
                        Text(session.agentName).font(.caption2).foregroundStyle(WatchDesign.Color.orange)
                        Text(session.title).font(.headline).lineLimit(2)
                        Label(session.isActive ? "Working" : "Ready", systemImage: session.isActive ? "clock" : "bubble.left")
                            .font(.caption2).foregroundStyle(WatchDesign.Color.secondaryText)
                    }.frame(minHeight: WatchDesign.minimumControlHeight)
                }
            }
        }.navigationTitle("Voice & chats")
    }
}

private struct WatchSessionDetail: View {
    @Bindable var store: WatchCompanionStore
    let session: WatchSessionSummary
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: WatchDesign.Spacing.section) {
                Text(session.title).font(.headline)
                Text(session.agentName).font(.caption).foregroundStyle(WatchDesign.Color.orange)
                // Controls scroll with the content; no oversized pinned composer hides the transcript.
                Button("Dictate reply", systemImage: "mic") { store.dictate(to: session.id) }
                    .disabled(!store.canSend || store.isDictating)
                    .accessibilityIdentifier("watch.companion.dictate")
                TextField("Reply", text: $store.voiceDraft)
                    .disabled(store.hasPendingRequest)
                    .accessibilityHint("Dictate, Scribble or type. Review your words before sending.")
                Text("System dictation follows your Watch language and privacy settings. Nothing sends until you tap Send.")
                    .font(.caption2).foregroundStyle(WatchDesign.Color.secondaryText)
                Button("Send to \(session.agentName)", systemImage: "paperplane") {
                    store.sendDraft(to: session.id, offeredState: store.state)
                }
                .disabled(!store.canSend || store.voiceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("watch.companion.voice.send")
                WatchRequestStatus(store: store, targetID: session.id)
                if store.voiceSessionID == session.id, let response = store.voiceResponse {
                    VStack(alignment: .leading, spacing: WatchDesign.Spacing.standard) {
                        Text(response.speaker).font(.caption.bold())
                        Text(response.text).font(.body)
                        Button(store.speech.isSpeaking ? "Stop audio" : "Read reply aloud", systemImage: store.speech.isSpeaking ? "stop.fill" : "speaker.wave.2") {
                            if store.speech.isSpeaking { store.speech.stop() }
                            else { store.readReplyAloud() }
                        }
                    }.watchCard()
                }
                Text("Recent messages").font(.headline)
                if store.snapshot.selectedSessionID == session.id {
                    ForEach(store.snapshot.transcript) { item in
                        VStack(alignment: .leading, spacing: WatchDesign.Spacing.compact) {
                            Text(item.speaker).font(.caption2.bold()).foregroundStyle(WatchDesign.Color.orange)
                            Text(item.text).font(.body)
                        }.frame(maxWidth: .infinity, alignment: .leading).watchCard()
                    }
                    Text("A compact excerpt. Full conversation is on iPhone.")
                        .font(.caption2).foregroundStyle(WatchDesign.Color.secondaryText)
                } else {
                    Button("Load recent messages") { store.selectSession(session.id) }.disabled(!store.canSend)
                }
            }.watchDetailPadding()
        }
        .navigationTitle("Chat")
        .task { store.prepareDraft(for: session.id) }
        .onDisappear { store.cancelDictation(); store.speech.stop() }
    }
}

private struct WatchConnectionsPage: View {
    @Bindable var store: WatchCompanionStore
    var body: some View {
        List {
            Section("Companion") {
                Label(store.connectionLabel, systemImage: store.isReachable ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                    .font(.headline)
                Text("Your paired iPhone handles sign-in, credentials and all agent connections. No separate Watch pairing is needed.")
                    .font(.caption)
                Button(store.isRefreshing ? "Checking…" : "Reconnect", systemImage: "arrow.clockwise") { store.refresh(reconnect: true) }
                    .disabled(store.isRefreshing)
                    .accessibilityIdentifier("watch.companion.reconnect")
            }
            Section("Phone Link") {
                Label(store.phoneLinkLabel, systemImage: store.isFresh && store.state?.phoneLink == .connected ? "checkmark.circle" : "exclamationmark.circle")
                if let state = store.state {
                    Text("Last update \(state.content.generatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(WatchDesign.Color.secondaryText)
                }
                Text("Reconnect asks iPhone to retry Link when no request is running. If signed out, open bighelp on iPhone. Watch connectivity alone does not mean the agent is online.")
                    .font(.caption)
            }
            if store.hasPendingRequest { Section("Request recovery") { WatchRequestStatus(store: store) } }
            if let error = store.errorMessage { Section("Notice") { Text(error).font(.caption) } }
            Section {
                Text("Voice input starts only when you ask. Replies play only when you tap Read reply aloud. Background delivery is managed by watchOS, not an always-on microphone.")
                    .font(.caption2).foregroundStyle(WatchDesign.Color.secondaryText)
            }
        }.navigationTitle("Connections")
    }
}

private struct WatchEmptyState: View {
    let title: String
    let detail: String
    @Bindable var store: WatchCompanionStore
    var body: some View {
        VStack(alignment: .leading, spacing: WatchDesign.Spacing.standard) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(WatchDesign.Color.secondaryText)
            Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }.disabled(store.isRefreshing)
        }
    }
}

private extension View {
    func watchDetailPadding() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WatchDesign.Spacing.standard)
            .padding(.bottom, WatchDesign.Spacing.section)
    }
}
