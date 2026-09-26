import SwiftUI
import UIKit

extension ChatView {
    private var canvasRows: [ChatCanvasRow] {
        var rows: [ChatCanvasRow] = []
        if model.hasPreviousHistory {
            rows.append(.previousHistory(model.isLoadingPreviousHistory, model.previousHistoryErrorMessage))
        }
        if model.shouldShowNewConversationWelcome {
            rows.append(.welcome)
        } else {
            if model.isBotMode, !model.presentedItems.isEmpty {
                rows.append(.divider("Earlier with \(agentName)"))
                rows += model.presentedItems.map(ChatCanvasRow.earlierMessage)
            }
            if model.isBotMode, model.timelineEvents.contains(where: { $0.kind == .botModeStarted }) {
                rows.append(.divider("Group chat started"))
            }
            rows += ChatCanvasTranscriptProjection.rows(from: displayedTranscriptRows, disclosures: model.activityDisclosures)
        }
        if let status = model.botModeStatus { rows.append(.botStatus(status)) }
        rows += model.pendingBotModeApprovals.map(ChatCanvasRow.botApproval)
        if model.hasNativeBotModeRetryActions { rows.append(.botRetry) }
        rows += model.memberFailures.map(ChatCanvasRow.memberFailure)
        if dashboardModel != nil { rows += chatClarifications.map(ChatCanvasRow.clarification) }
        rows += directHermesClarifications.map(ChatCanvasRow.directClarification)
        if showsPendingMessage { rows.append(.pending(model.workingAgentName ?? agentName, model.isBotMode)) }
        if let message = model.failureMessage { rows.append(.failure(message)) }
        else if !model.retainedUnsentSubmissions.isEmpty {
            rows.append(.failure("Unsent drafts retained: \(model.retainedUnsentSubmissions.count)"))
        }
        if model.shouldShowNewConversationWelcome { rows.append(.quickActions) }
        rows.append(.bottom)
        return rows
    }
    var timeline: some View {
        let rows = canvasRows
        let firstID = rows.first?.id
        let groupedIDs = Self.groupedMessageRowIDs(rows)
        let continuedIDs = Self.continuedMessageRowIDs(rows)
        return NativeChatTimeline(conversationID: model.conversationID, ownerID: ObjectIdentifier(model), rows: rows,
                           controller: timelineController, entryCount: model.transcriptEntries.count,
                           contentInsets: UIEdgeInsets(
                            top: headerHeight, left: 0,
                            bottom: composerHeight + ChatCanvasLayout.composerInsetSpacing, right: 0)) { row in
            canvasRowContent(row)
                .frame(maxWidth: horizontalSizeClass == .regular ? 800 : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, LoopdyTokens.space12)
                .padding(.top, row.id == firstID ? LoopdyTokens.space12 : 0)
                .padding(.bottom, groupedIDs.contains(row.id)
                         ? ChatMessageGrouping.groupedSpacing : canvasRowBottomSpacing(row))
                .environment(\.chatMessageContinuesGroup, groupedIDs.contains(row.id))
                .environment(\.chatMessageContinuesPrevious, continuedIDs.contains(row.id))
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: LoopdyTokens.space8) {
                if !timelineController.isAtBottom {
                    LoopdyIconButton(systemImage: "arrow.down", accessibilityLabel: "Return to latest messages",
                                     style: .neutralGlass,
                                     action: { timelineController.scrollToLatest(animated: !reduceMotion) })
                        .accessibilityIdentifier("chat.return-to-latest")
                }
                if let progress = model.nativeSessionResumeProgress.visibleIndicator {
                    Label {
                        Text(progress.message)
                    } icon: {
                        ProgressView()
                            .controlSize(.small)
                    }
                    .loopdyFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LoopdyTokens.space12)
                    .padding(.vertical, LoopdyTokens.space8)
                    .background(theme.canvas.opacity(0.94), in: Capsule())
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("chat.session-resume-progress")
                }
                if model.isHydratingHistory {
                    Text(verbatim: "Getting the latest changes...")
                        .loopdyFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .loopdyActiveCallShimmer(isActive: botActivityScenePhase == .active, color: .white)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, LoopdyTokens.space12)
                        .padding(.vertical, LoopdyTokens.space8)
                        .background(theme.canvas.opacity(0.94), in: Capsule())
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("chat.hydration-status")
                }
            }
            .padding(.bottom, composerHeight + LoopdyTokens.space12)
        }
        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
        .onChange(of: fittingRailScrollRequest.generation) { _, _ in
            switch fittingRailScrollRequest.direction {
            case .towardLatest: timelineController.scrollToLatest(animated: !reduceMotion)
            case .towardOldest: timelineController.scrollToOldest()
            }
        }
    }
    @ViewBuilder
    private func canvasRowContent(_ row: ChatCanvasRow) -> some View {
        switch row {
        case .transcript(let row): transcriptRow(row)
        case .workTrailHeader(let turn):
            ChatWorkTrailCard(turn: turn, rendersExpandedEvents: false, onDisclosureChange: beginDisclosureReview)
        case .activityDetail(let event):
            ChatActivityRow(event: event, onDisclosureChange: beginDisclosureReview)
                .padding(.horizontal, LoopdyTokens.space4)
                .padding(.leading, LoopdyTokens.space4)
                .modifier(ChatToolDetailStyle())
        case .workTrailEnd:
            Divider().padding(.horizontal, LoopdyTokens.space4)
        case .earlierMessage(let item):
            TimelineItemView(item: item, onApprovalTap: onApprovalTap,
                             pendingMidSessionBehavior: model.pendingMidSessionBehavior(for: item.id),
                             senderResolver: senderResolver, showsSenderName: model.isBotMode)
        case .divider(let title): timelineDivider(title)
        case .previousHistory: previousHistoryButton
        case .welcome: emptyTimeline
        case .quickActions: QuickActionsView(model: model)
        case .bottom:
            Color.clear.frame(height: ChatBottomAnchorVisibility.contentBottomPadding + ChatBottomAnchorVisibility.anchorHeight)
        case .botStatus(let status):
            Label(status, systemImage: "person.2.fill")
                .loopdyFont(.metadata, weight: .semibold)
                .foregroundStyle(theme.action)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("chat.bot-mode-status")
        case .botApproval(let approval):
            BotModeApprovalCard(
                approvalID: approval.id,
                agentName: model.nativeRoomParticipants.first(where: { $0.memberID == approval.memberID })?.displayName
                    ?? model.memberProfiles.first(where: { $0.id == approval.memberID })?.name ?? approval.memberID,
                command: approval.command,
                detail: approval.description,
                allowsOnce: approval.choices.contains(.once),
                allowsDeny: approval.choices.contains(.deny),
                isSubmitting: model.botModeApprovalSubmissions.contains(approval.id),
                errorMessage: model.botModeApprovalErrors[approval.id],
                onAllowOnce: { Task { await model.resolveBotModeApproval(approval, choice: .once) } },
                onDeny: { Task { await model.resolveBotModeApproval(approval, choice: .deny) } }
            )
        case .botObservedTool(let tool, let expanded):
            BotModeObservedToolView(
                row: tool,
                memberName: model.nativeRoomParticipants.first(where: { $0.memberID == tool.observation.memberId })?.displayName
                    ?? "Unavailable participant",
                isExpanded: expanded,
                onToggle: {
                    beginDisclosureReview()
                    model.botModeRoomStore?.activity.toggleTool(tool.id)
                }
            )
        case .botActivityNotice(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("bot-mode.activity-notice")
        case .botRetry:
            LoopdyCard {
                VStack(alignment: .leading, spacing: LoopdyTokens.space12) {
                    Text("Hermes has interrupted work waiting for your decision.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry interrupted work") { Task { await model.retry() } }
                        .buttonStyle(LoopdyV2ButtonStyle(emphasis: .primary))
                        .disabled(!model.canRetry)
                        .accessibilityIdentifier("chat.bot-mode.retry")
                }
            }
        case .memberFailure(let failure): memberFailure(failure)
        case .clarification(let item):
            if case .clarification(let request) = item.interaction, let dashboardModel {
                DashboardClarificationAttentionCard(itemID: item.id, request: request,
                                                    model: dashboardModel, accessibilityPrefix: "chat")
            }
        case .directClarification(let prompt):
            if let directHermesClient {
                DirectHermesPromptResponseView(
                    client: directHermesClient,
                    prompt: prompt,
                    inline: true
                )
            }
        case .pending(let name, let isGroup): PendingMessageView(agentName: name, isGroup: isGroup)
        case .failure(let message): failure(message: message)
        }
    }
    /// Plain message rows immediately followed by a message from the same sender.
    static func groupedMessageRowIDs(_ rows: [ChatCanvasRow]) -> Set<String> {
        func entry(_ row: ChatCanvasRow) -> ChatTranscriptEntry? {
            if case .transcript(.entry(let entry)) = row { return entry }
            return nil
        }
        var ids = Set<String>()
        for (row, next) in zip(rows, rows.dropFirst()) {
            guard let current = entry(row), let following = entry(next),
                  ChatMessageGrouping.continuesGroup(current, next: following) else { continue }
            ids.insert(row.id)
        }
        return ids
    }
    /// Plain message rows immediately preceded by a message from the same sender.
    static func continuedMessageRowIDs(_ rows: [ChatCanvasRow]) -> Set<String> {
        func entry(_ row: ChatCanvasRow) -> ChatTranscriptEntry? {
            if case .transcript(.entry(let entry)) = row { return entry }
            return nil
        }
        var ids = Set<String>()
        for (previous, row) in zip(rows, rows.dropFirst()) {
            guard let earlier = entry(previous), let current = entry(row),
                  ChatMessageGrouping.continuesGroup(earlier, next: current) else { continue }
            ids.insert(row.id)
        }
        return ids
    }
    private func canvasRowBottomSpacing(_ row: ChatCanvasRow) -> CGFloat {
        switch row {
        case .bottom: 0
        case .workTrailHeader, .activityDetail: LoopdyTokens.space8
        default: LoopdyTokens.space16
        }
    }
    private var displayedTranscriptRows: [ChatTurnDisplayRow] {
        ChatCompletedTurnProjection.rows(
            from: ChatCardTranscriptProjection.removingSupersededLiveCards(from: model.transcriptEntries),
            isSending: model.isSending,
            enabled: foldCompletedTurns,
            activityEvents: model.activityLedger.allEvents
        )
    }
    @ViewBuilder
    private func transcriptRow(_ row: ChatTurnDisplayRow) -> some View {
        switch row {
        case .entry(let entry):
            transcriptEntry(entry)
        case .completed(let turn):
            ChatCompletedTurnView(
                turn: turn,
                disclosures: model.activityDisclosures,
                onDisclosureChange: beginDisclosureReview
            ) { entry in
                transcriptEntry(entry)
            }
            .id(row.id)
        }
    }
    @ViewBuilder
    private func transcriptEntry(_ entry: ChatTranscriptEntry) -> some View {
        switch entry {
        case .message(let item):
            let nativeReaction = messageReactionPresentation(for: item)
            TimelineItemView(
                item: item,
                onApprovalTap: onApprovalTap,
                onFork: model.isBotMode ? nil : onForkMessage,
                pendingMidSessionBehavior: model.pendingMidSessionBehavior(for: item.id),
                senderResolver: senderResolver,
                showsSenderName: model.isBotMode,
                messageReaction: nativeReaction,
                onMessageReaction: nativeReaction == nil ? nil : { emoji in
                    setMessageReaction(emoji, for: item)
                }
            )
            .id(entry.id)
        case .activity(let turn):
            ChatActivityTurnView(
                turn: turn,
                senderResolver: senderResolver,
                onDisclosureChange: beginDisclosureReview
            )
            .id(entry.id)
        }
    }
    private func messageReactionPresentation(for item: TimelineItem) -> NativeMessageReactionPresentation? {
        if model.nativeConversationClient != nil {
            return model.nativeMessageReactionPresentation(for: item)
        }
        guard usesNativeReactionAcceptanceFixture,
              let rowID = NativeMessageReactionRowIdentity.rowID(from: item.id) else { return nil }
        return NativeMessageReactionPresentation(
            rowID: rowID,
            reactions: [],
            availability: .available,
            isUpdating: false,
            errorMessage: nil
        )
    }
    private func setMessageReaction(_ emoji: String?, for item: TimelineItem) {
        if model.nativeConversationClient != nil {
            Task { @MainActor in await model.setNativeMessageReaction(emoji, for: item.id) }
            return
        }
        guard usesNativeReactionAcceptanceFixture else { return }
        // The UI fixture exercises the shipping menu and picker without
        // mutating a host or pretending that an offline selection persisted.
    }
    private var usesNativeReactionAcceptanceFixture: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-use-demo-fixtures")
            && arguments.contains("-test-native-reaction-ui")
        #else
        return false
        #endif
    }
    private var showsPendingMessage: Bool {
        guard model.isSending else { return false }
        // Only the work card at the live tail can replace the waiting status.
        // Scanning the whole ledger lets old running events suppress a new
        // response, even after a newer human/assistant message is on screen.
        guard case .activity(let turn)? = model.transcriptEntries.last else { return true }
        return !turn.events.contains { $0.lifecycle == .running }
    }
    var chatClarifications: [DashboardAttentionItem] {
        ChatClarificationProjection.items(
            for: model.conversationID,
            in: dashboardModel?.snapshot
        )
    }
    private var previousHistoryButton: some View {
        Button(action: {
            timelineController.beginReview()
            onLoadPreviousMessages()
        }) {
            HStack(spacing: LoopdyTokens.space12) {
                Image(systemName: model.isLoadingPreviousHistory ? "folder.badge.clock" : "folder")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.action)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                    Text(model.isLoadingPreviousHistory ? "Loading previous messages" : "Show previous messages")
                        .loopdyFont(.metadata, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                    if let message = model.previousHistoryErrorMessage {
                        Text(message)
                            .loopdyFont(.metadata)
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if model.isLoadingPreviousHistory {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.tertiaryText)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget, alignment: .leading)
            .padding(.horizontal, LoopdyTokens.space16)
            .padding(.vertical, LoopdyTokens.space8)
            .loopdySurface(.card)
        }
        .buttonStyle(.plain)
        .disabled(model.isLoadingPreviousHistory)
        .accessibilityIdentifier("chat.show-previous-messages")
    }
    private func timelineDivider(_ title: String) -> some View {
        HStack(spacing: LoopdyTokens.space8) {
            Rectangle()
                .fill(theme.border)
                .frame(height: LoopdyTokens.hairline)
            Text(title)
                .loopdyFont(.metadata, weight: .semibold)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle()
                .fill(theme.border)
                .frame(height: LoopdyTokens.hairline)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
    private var emptyTimeline: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
            Text("What can \(agentName) help with?")
                .loopdyFont(.screenTitle, weight: .bold)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, LoopdyTokens.space8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
    private func failure(message: String) -> some View {
        LoopdyCard {
            VStack(alignment: .leading, spacing: LoopdyTokens.space12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LoopdyTokens.space12) {
                        failureText(message)
                        Spacer(minLength: LoopdyTokens.space12)
                        if model.canRetry { retryButton }
                    }
                    VStack(alignment: .leading, spacing: LoopdyTokens.space12) {
                        failureText(message)
                        if model.canRetry { retryButton }
                    }
                }
                if !model.retainedUnsentSubmissions.isEmpty {
                    DisclosureGroup("Review unsent drafts") {
                        ForEach(model.retainedUnsentSubmissions) { submission in
                            VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
                                Text(submission.text).textSelection(.enabled)
                                if let attachments = submission.attachments, !attachments.isEmpty {
                                    ChatAttachmentGallery(attachments: attachments, alignsTrailing: false)
                                }
                                Button("Clear retained copy", role: .destructive) {
                                    model.nativeConversationClient?.markReviewed(submission.id)
                                }
                                .accessibilityHint("Removes only this local copy. It does not send a message or change the composer draft.")
                            }
                            .accessibilityIdentifier("chat.unsent-draft.\(submission.id)")
                        }
                    }
                    .accessibilityIdentifier("chat.unsent-drafts")
                }
            }
        }
    }
    private func memberFailure(_ failure: BotModeMemberFailure) -> some View {
        let name = model.memberProfiles.first(where: { $0.id == failure.memberID })?.name ?? failure.memberID
        return LoopdyCard {
            HStack(alignment: .top, spacing: LoopdyTokens.space12) {
                Label("\(name) could not respond: \(failure.message)", systemImage: "exclamationmark.triangle.fill")
                    .loopdyFont(.body)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: LoopdyTokens.space8)
                Button("Clear") {
                    do {
                        try model.clearMemberFailure(memberID: failure.memberID)
                    } catch {
                        // ChatModel exposes the recoverable persistence error in
                        // the visible failure card above.
                    }
                }
                .frame(minWidth: LoopdyTokens.hitTarget, minHeight: LoopdyTokens.hitTarget)
                .accessibilityLabel("Clear \(name) failure")
            }
        }
        .accessibilityIdentifier("chat.bot-mode-failure.\(failure.memberID)")
    }
    private func failureText(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .loopdyFont(.body)
            .foregroundStyle(theme.danger)
            .fixedSize(horizontal: false, vertical: true)
    }
    private var retryButton: some View {
        Button("Retry request") {
            Task { await model.retry() }
        }
        .loopdyFont(.label)
        .frame(minWidth: LoopdyTokens.hitTarget, minHeight: LoopdyTokens.hitTarget)
        .disabled(!model.canRetry)
        .accessibilityHint("Retries the failed request without adding another intent to the timeline.")
    }
    private func beginDisclosureReview() {
        timelineController.beginReview()
    }
    func requestFittingRailScroll(_ direction: ChatRailScrollDirection) {
        fittingRailScrollRequest = ChatRailScrollRequest(
            generation: fittingRailScrollRequest.generation + 1, direction: direction)
    }
}
