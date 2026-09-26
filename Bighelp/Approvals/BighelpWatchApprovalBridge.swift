import CryptoKit
import Foundation
import WatchConnectivity

private struct WatchPhoneReplyHandler: @unchecked Sendable {
    let call: ([String: Any]) -> Void
}

/// Single WCSession owner. Watch is a paired display/controller, never a separately enrolled client.
@MainActor
final class BighelpWatchApprovalBridge: NSObject {
    private let session: WCSession
    private let loader: any ApprovalRequestLoading
    private let dashboardSource: (any DashboardDataSource)?
    private let clarificationClient: (any DashboardClarificationClient)?
    private let coordinator: WatchApprovalDecisionCoordinator
    private weak var featureStore: ShellFeatureStore?
    private weak var sessionCatalog: SessionCatalogStore?
    private weak var agentDirectory: AgentDirectoryStore?
    private var authority: () -> WatchPhoneAuthority = { .unavailable }
    private var reconnectPhone: () async -> Void = {}
    private var voiceClient: ((SessionRecord, AgentProfile?) -> any VoiceSessionClient)?
    private var refreshGeneration = UUID()
    private var journal = WatchCompanionJournal()
    private var storageAvailable = true
    private var offers: [WatchCompanionState] = []
    private var loadedApprovals: [String: WatchApprovalRequest] = [:]
    private var selectedSessionID: String?
    private var syncTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var operationDeadline: Task<Void, Never>?
    private var pendingDashboardRefresh = false
    private var pendingReconnect = false
    private var activeRequest: WatchCompanionActionRequest?
    private var lastContent: WatchCompanionSnapshot?
    private var lastLink: WatchPhoneLinkState?

    init(
        loader: any ApprovalRequestLoading,
        client: any ApprovalClient,
        // Kept only for source compatibility at the composition boundary. Never invoked.
        enrollDirectClient: ((WatchBighelpEnrollmentRequest) async throws -> WatchBighelpEnrollmentGrant)? = nil,
        session: WCSession = .default
    ) {
        self.session = session
        self.loader = loader
        self.dashboardSource = loader as? any DashboardDataSource
        self.clarificationClient = client as? any DashboardClarificationClient
        coordinator = WatchApprovalDecisionCoordinator(loader: loader, client: client)
        super.init()
        do {
            journal = try WatchCompanionPersistence.load(WatchCompanionJournal.self, name: "phone-journal-v2")
                ?? WatchCompanionJournal()
            journal.recover()
            try journal.save()
        } catch {
            // A missing replay fence is not permission to send the same request again.
            storageAvailable = false
        }
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        }
    }

    isolated deinit {
        syncTask?.cancel()
        refreshTask?.cancel()
        operation?.cancel()
        operationDeadline?.cancel()
    }

    func configure(
        featureStore: ShellFeatureStore,
        sessionCatalog: SessionCatalogStore,
        agentDirectory: AgentDirectoryStore,
        authority: @escaping () -> WatchPhoneAuthority = { .unavailable },
        reconnect: @escaping () async -> Void = {},
        voiceClient: ((SessionRecord, AgentProfile?) -> any VoiceSessionClient)? = nil
    ) {
        self.featureStore = featureStore
        self.sessionCatalog = sessionCatalog
        self.agentDirectory = agentDirectory
        self.authority = authority
        self.reconnectPhone = reconnect
        self.voiceClient = voiceClient
        syncTask?.cancel()
        syncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshProjection(refreshDashboard: false)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func publish(_ loaded: LoadedApprovalRequest) {
        // A notification callback can arrive after an account/host transition. Treat it
        // as a refresh hint, not as authority to install an unscoped permission offer.
        loadedApprovals.removeValue(forKey: loaded.request.id)
        refreshProjection(refreshDashboard: true)
    }

    func clear() {
        operation?.cancel()
        operationDeadline?.cancel()
        operation = nil
        activeRequest = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration = UUID()
        pendingDashboardRefresh = false
        pendingReconnect = false
        coordinator.clear()
        loadedApprovals.removeAll()
        selectedSessionID = nil
        offers.removeAll()
        lastContent = nil
        lastLink = nil
        journal.authorityID = UUID()
        journal.scopeDigest = ""
        journal.receipts.removeAll()
        for transfer in session.outstandingUserInfoTransfers {
            if transfer.userInfo[WatchCompanionWire.key] != nil { transfer.cancel() }
        }
        do { try journal.save() } catch { storageAvailable = false }
        publishSnapshot(force: true, empty: true)
    }

    private func reconcileAuthority() {
        let scope = authority().scope ?? ""
        let digest = Self.digest(scope)
        guard digest != journal.scopeDigest else { return }
        clear()
        journal.scopeDigest = digest
        do { try journal.save() } catch { storageAvailable = false }
    }

    private static func digest(_ scope: String) -> String {
        SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func owns(_ id: UUID) -> Bool {
        journal.authorityID == id && authority().scope != nil
            && Self.digest(authority().scope ?? "") == journal.scopeDigest
    }

    private func refreshProjection(refreshDashboard: Bool, reconnect: Bool = false) {
        reconcileAuthority()
        guard refreshTask == nil else {
            pendingDashboardRefresh = pendingDashboardRefresh || refreshDashboard
            pendingReconnect = pendingReconnect || reconnect
            return
        }
        let owner = journal.authorityID
        let generation = UUID()
        refreshGeneration = generation
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if refreshGeneration == generation {
                    refreshTask = nil
                    if pendingDashboardRefresh || pendingReconnect {
                        let refresh = pendingDashboardRefresh
                        let retry = pendingReconnect
                        pendingDashboardRefresh = false
                        pendingReconnect = false
                        refreshProjection(refreshDashboard: refresh, reconnect: retry)
                    }
                }
            }
            if reconnect, owns(owner), activeRequest == nil { await reconnectPhone() }
            if refreshDashboard, owns(owner) {
                await featureStore?.dashboardModel.refreshAfterExternalChange()
                guard owns(owner), !Task.isCancelled else { return }
                if activeRequest == nil {
                    try? await sessionCatalog?.load(requireAuthoritativeRefresh: true)
                }
            }
            guard owns(owner), !Task.isCancelled, refreshGeneration == generation else {
                if refreshGeneration == generation, authority().scope == nil { publishSnapshot(force: true) }
                return
            }
            for item in (featureStore?.dashboardModel.snapshot?.attentionItems ?? []).prefix(8) {
                guard case .approval(let summary) = item.interaction,
                      !summary.isExpired(at: .now), loadedApprovals[summary.approvalID] == nil else { continue }
                if let loaded = try? await loader.loadApproval(id: summary.approvalID) {
                    guard owns(owner), !Task.isCancelled else { return }
                    let request = WatchApprovalRequest(request: loaded.request, allowedDecisions: loaded.allowedDecisions)
                    if let valid = try? request.validated() { loadedApprovals[summary.approvalID] = valid }
                }
            }
            publishSnapshot()
        }
    }

    private func makeContent(empty: Bool = false, dashboard freshDashboard: DashboardSnapshot? = nil) -> WatchCompanionSnapshot {
        guard !empty, storageAvailable, authority().scope != nil,
              let featureStore, let sessionCatalog, let agentDirectory else { return Self.emptyContent }
        var names: [String: String] = [:]
        var roles: [String: String] = [:]
        for agent in agentDirectory.profiles { names[agent.id] = agent.name; roles[agent.id] = agent.role }
        var approvals: [WatchApprovalRequest] = []
        let dashboard = freshDashboard ?? featureStore.dashboardModel.snapshot
        for item in dashboard?.attentionItems ?? [] {
            guard case .approval(let summary) = item.interaction,
                  !summary.isExpired(at: .now),
                  var request = loadedApprovals[summary.approvalID],
                  Set(request.allowedDecisions) == Set(summary.allowedDecisions.map(WatchApprovalDecision.init)) else { continue }
            request.expiresAt = summary.expiresAt
            request.eventID = summary.eventID
            request.sessionID = item.sessionID
            request.agentID = item.agentID
            if (try? request.validated()) != nil { approvals.append(request) }
        }
        let retained = Set(approvals.map(\.requestID))
        loadedApprovals = loadedApprovals.filter { retained.contains($0.key) }
        return WatchCompanionProjection.make(
            dashboard: dashboard, sessions: sessionCatalog.records,
            selectedSessionID: selectedSessionID, agentNamesByID: names, agentRolesByID: roles,
            publishedApprovals: Array(approvals.prefix(8)), generatedAt: .distantPast
        )
    }

    private func publishSnapshot(force: Bool = false, empty: Bool = false) {
        guard session.activationState == .activated else { return }
        let content = makeContent(empty: empty)
        let link: WatchPhoneLinkState = empty || !storageAvailable ? .unavailable : authority().link
        let latestAge = offers.last.map { Date().timeIntervalSince($0.content.generatedAt) } ?? .infinity
        guard force || content != lastContent || link != lastLink || latestAge >= 45 else { return }
        let stamped = WatchCompanionSnapshot(
            generatedAt: .now, weather: content.weather, inbox: content.inbox,
            approvals: content.approvals, sessions: content.sessions,
            selectedSessionID: content.selectedSessionID, transcript: content.transcript
        )
        journal.revision &+= 1
        let state = WatchCompanionState(
            authorityID: journal.authorityID, revision: journal.revision, offerID: UUID(),
            phoneLink: link, content: stamped
        )
        do {
            try journal.save()
            let payload = try WatchCompanionWire.encode(.snapshot(state))
            try session.updateApplicationContext(payload)
            offers.append(state)
            offers = Array(offers.suffix(16))
            lastContent = content
            lastLink = link
        } catch {
            // The Watch keeps its old snapshot marked stale; no invented successful sync.
        }
    }

    private func receipt(
        _ request: WatchCompanionActionRequest, phase: WatchCompanionReceipt.Phase,
        message: String, voice: WatchVoiceResult? = nil
    ) -> WatchCompanionReceipt {
        WatchCompanionReceipt(
            id: request.id, authorityID: request.authorityID, targetID: request.action.targetID,
            phase: phase, message: message, completedAt: .now, voice: voice
        )
    }

    private func receive(_ packet: WatchCompanionPacket, reply: WatchPhoneReplyHandler) {
        reconcileAuthority()
        switch packet {
        case .refresh(_, let reconnect):
            publishSnapshot(force: true)
            if let state = offers.last, let data = try? WatchCompanionWire.encode(.snapshot(state)) {
                reply.call(data)
            } else { reply.call([:]) }
            refreshProjection(refreshDashboard: true, reconnect: reconnect)
        case .status(let id, let owner):
            let result = journal.receipts.first { $0.id == id && $0.authorityID == owner }
                ?? WatchCompanionReceipt(
                    id: id, authorityID: owner, targetID: "unknown", phase: .unconfirmed,
                    message: "No durable confirmation is available. Check iPhone before resending.", completedAt: .now
                )
            reply.call((try? WatchCompanionWire.encode(.receipt(result))) ?? [:])
        case .action(let request):
            // Deduplicate before performing any mutation. A retry is a status lookup, not a resend.
            if let previous = journal.receipts.first(where: { $0.id == request.id }) {
                reply.call((try? WatchCompanionWire.encode(.receipt(previous))) ?? [:])
                return
            }
            let age = Date().timeIntervalSince(request.createdAt)
            guard storageAvailable, activeRequest == nil, owns(request.authorityID),
                  !isResolved(request.action),
                  authority().link == .connected, age >= -30, age < 120,
                  let offer = offers.first(where: { $0.offerID == request.offerID }),
                  offer.authorityID == request.authorityID, offer.isFresh,
                  isOffered(request.action, in: offer.content) else {
                let rejected = receipt(request, phase: .rejected, message: "Not sent. Refresh Watch and check the connection on iPhone.")
                reply.call((try? WatchCompanionWire.encode(.receipt(rejected))) ?? [:])
                return
            }
            let pending = receipt(request, phase: .pending, message: "Received by iPhone. Waiting for actual confirmation.")
            do { try journal.record(pending) } catch {
                storageAvailable = false
                reply.call((try? WatchCompanionWire.encode(.receipt(receipt(
                    request, phase: .rejected, message: "Not sent. iPhone could not save a safe request record."
                )))) ?? [:])
                return
            }
            activeRequest = request
            reply.call((try? WatchCompanionWire.encode(.receipt(pending))) ?? [:])
            operation = Task { @MainActor [weak self] in
                await self?.perform(request, offered: offer.content)
            }
            operationDeadline?.cancel()
            operationDeadline = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(110))
                guard !Task.isCancelled, let self, activeRequest?.id == request.id,
                      owns(request.authorityID) else { return }
                operation?.cancel()
                operation = nil
                activeRequest = nil
                let result = receipt(request, phase: .unconfirmed, message: "iPhone confirmation timed out. Work may still finish. Check iPhone before resending.")
                do { try journal.record(result) } catch { storageAvailable = false }
                deliver(result)
            }
        default: reply.call([:])
        }
    }

    private func isResolved(_ action: WatchCompanionAction) -> Bool {
        switch action {
        case .selectSession, .voice: return false
        case .dismissUpdate, .respond, .approve:
            return journal.receipts.contains {
                $0.authorityID == journal.authorityID && $0.targetID == action.targetID && $0.phase == .committed
            }
        }
    }

    private func isOffered(_ action: WatchCompanionAction, in content: WatchCompanionSnapshot) -> Bool {
        switch action {
        case .selectSession(let id), .voice(let id, _):
            return content.sessions.contains { $0.id == id }
        case .dismissUpdate(let id):
            return content.inbox.contains { $0.id == id && $0.canDismiss }
        case .respond(let id, let text):
            guard let item = content.inbox.first(where: { $0.id == id }),
                  item.kind == .clarification, item.phoneActionReason == nil,
                  item.expiresAt.map({ $0 > .now }) ?? true else { return false }
            return item.allowsCustomResponse || item.choices.contains(text)
        case .approve(let id, let decision):
            guard let item = content.approvals.first(where: { $0.requestID == id }) else { return false }
            return item.allowedDecisions.contains(decision) && (item.expiresAt.map { $0 > .now } ?? false)
        }
    }

    private func perform(_ request: WatchCompanionActionRequest, offered: WatchCompanionSnapshot) async {
        var result: WatchCompanionReceipt
        do {
            guard let featureStore, let sessionCatalog, owns(request.authorityID), !Task.isCancelled else {
                throw WatchCompanionValidationError.invalidPayload
            }
            switch request.action {
            case .selectSession(let id):
                guard sessionCatalog.records.contains(where: { $0.id == id }) else { throw WatchCompanionValidationError.invalidPayload }
                _ = try await sessionCatalog.hydrateSession(id: id)
                guard owns(request.authorityID), !Task.isCancelled else { return }
                selectedSessionID = id
                result = receipt(request, phase: .committed, message: "Session loaded.")
            case .dismissUpdate(let id):
                guard let dashboardSource else { throw WatchCompanionValidationError.invalidPayload }
                let fresh = try await dashboardSource.loadDashboard()
                guard owns(request.authorityID), !Task.isCancelled,
                      let original = offered.inbox.first(where: { $0.id == id }),
                      makeContent(dashboard: fresh).inbox.contains(original), original.canDismiss else {
                    throw WatchCompanionValidationError.invalidPayload
                }
                try await dashboardSource.dismissDashboardEvent(id: id)
                result = receipt(request, phase: .committed, message: "Update dismissed on iPhone.")
            case .respond(let id, let text):
                guard let dashboardSource, let clarificationClient else { throw WatchCompanionValidationError.invalidPayload }
                // Do not use the presentation model's refresh: it intentionally keeps stale
                // rows and swallows load failures. Decisions require a successful fresh read.
                let fresh = try await dashboardSource.loadDashboard()
                guard owns(request.authorityID), !Task.isCancelled,
                      let original = offered.inbox.first(where: { $0.id == id }),
                      let current = makeContent(dashboard: fresh).inbox.first(where: { $0.id == id }), current == original,
                      isOffered(request.action, in: makeContent(dashboard: fresh)),
                      let item = fresh.attentionItems.first(where: { $0.id == id }),
                      case .clarification(let clarification) = item.interaction,
                      clarification.eventID == id, !clarification.isMultiSelect, !clarification.isExpired(at: .now),
                      clarification.allowsCustomResponse || clarification.choices.contains(text) else {
                    result = receipt(request, phase: .rejected, message: "The request changed or expired. Refresh and review it again.")
                    break
                }
                let confirmation = try await clarificationClient.respond(to: clarification, response: text)
                guard confirmation.eventID == clarification.eventID,
                      confirmation.requestID == clarification.requestID else {
                    throw WatchCompanionValidationError.invalidPayload
                }
                result = receipt(request, phase: .committed, message: "Response confirmed by iPhone.")
            case .approve(let id, let decision):
                guard let dashboardSource else { throw WatchCompanionValidationError.invalidPayload }
                let fresh = try await dashboardSource.loadDashboard()
                guard owns(request.authorityID), !Task.isCancelled,
                      let original = offered.approvals.first(where: { $0.requestID == id }),
                      makeContent(dashboard: fresh).approvals.contains(original) else {
                    result = receipt(request, phase: .rejected, message: "The approval changed or expired. Review it again on iPhone.")
                    break
                }
                coordinator.publish(original)
                let decisionResult = await coordinator.handle(
                    WatchApprovalDecisionMessage(requestID: id, decision: decision, attemptID: request.id.uuidString),
                    revalidate: { [weak self] in
                        guard let self else { return false }
                        return owns(request.authorityID) && makeContent().approvals.contains(original)
                    }
                )
                switch decisionResult {
                case .succeeded:
                    loadedApprovals.removeValue(forKey: id)
                    result = receipt(request, phase: .committed, message: "\(decision.buttonTitle) confirmed.")
                case .failed:
                    result = receipt(request, phase: .unconfirmed, message: "Approval result is unconfirmed. Check iPhone before trying again.")
                case nil:
                    loadedApprovals.removeValue(forKey: id)
                    result = receipt(request, phase: .rejected, message: "Approval no longer matches the offer. Refresh and review it again.")
                }
            case .voice(let id, let text):
                guard let record = sessionCatalog.session(id: id), let voiceClient,
                      !record.isActive else {
                    result = receipt(request, phase: .rejected, message: "Voice is unavailable or this session is busy. Open the session on iPhone.")
                    break
                }
                let agent = agentDirectory?.profiles.first { $0.id == record.agentIDs.first }
                let client = voiceClient(record, agent)
                sessionCatalog.markActiveForLocalTurn(id: id)
                // Use the phone's real client, but not a VoiceModel whose unscoped callbacks
                // could outlive a host switch. No microphone or phone speech is started.
                let response = try await client.respond(to: text, conversationID: id, onDraft: { _ in })
                guard owns(request.authorityID), !Task.isCancelled else { return }
                guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw WatchCompanionValidationError.invalidPayload
                }
                let human = TimelineItem(
                    id: "watch-user-\(request.id.uuidString)", role: .human,
                    sender: .user(snapshot: .init(name: "You")), content: .message(text),
                    metadata: .init(source: "Watch", delivery: "Sent", timestamp: request.createdAt)
                )
                featureStore.acceptExternal([human] + response.timelineItems, conversationID: id)
                sessionCatalog.markInactiveAfterAuthoritativeTerminal(id: id)
                result = receipt(request, phase: .committed, message: "Reply received.", voice: WatchVoiceResult(
                    attemptID: request.id.uuidString,
                    speaker: WatchCompanionWire.bounded(response.speaker, bytes: 120),
                    text: WatchCompanionWire.bounded(response.text, bytes: 1_200), errorMessage: nil
                ))
            }
        } catch {
            result = receipt(request, phase: .unconfirmed, message: "No final confirmation. Check the session on iPhone before resending.")
        }
        guard owns(request.authorityID), !Task.isCancelled else { return }
        do { try journal.record(result) } catch {
            // The side effect may have happened; retain the persisted pending fence.
            storageAvailable = false
            result = receipt(request, phase: .unconfirmed, message: "iPhone could not save the final confirmation. Check iPhone before resending.")
        }
        activeRequest = nil
        operation = nil
        operationDeadline?.cancel()
        deliver(result)
        publishSnapshot(force: true)
        refreshProjection(refreshDashboard: true)
    }

    private func deliver(_ result: WatchCompanionReceipt) {
        guard session.activationState == .activated,
              let payload = try? WatchCompanionWire.encode(.receipt(result)) else { return }
        // Immediate visibility plus OS-managed durable delivery. Status lookup remains the recovery path.
        if session.isReachable { session.sendMessage(payload, replyHandler: nil, errorHandler: nil) }
        if session.outstandingUserInfoTransfers.count < 64 { session.transferUserInfo(payload) }
    }

    private static var emptyContent: WatchCompanionSnapshot {
        WatchCompanionSnapshot(generatedAt: .distantPast, weather: nil, inbox: [], approvals: [],
                               sessions: [], selectedSessionID: nil, transcript: [])
    }
}

extension BighelpWatchApprovalBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        guard state == .activated, error == nil else { return }
        Task { @MainActor [weak self] in
            self?.reconcileAuthority()
            self?.publishSnapshot(force: true)
            self?.refreshProjection(refreshDashboard: false)
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.refreshProjection(refreshDashboard: false) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = WatchPhoneReplyHandler(call: replyHandler)
        guard let packet = try? WatchCompanionWire.decode(message) else {
            // Legacy independent enrollment is intentionally unsupported, including its passkey crash path.
            reply.call([:])
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { reply.call([:]); return }
            receive(packet, reply: reply)
        }
    }
}
