import Foundation
import UIKit

struct LoopdyShortcutAgent: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let role: String
    let isDefault: Bool
}

struct LoopdyShortcutModel: Identifiable, Equatable, Hashable, Sendable {
    let providerID: String
    let providerName: String
    let modelID: String

    var id: String { "\(providerID):\(modelID)" }
}

enum LoopdyShortcutReasoningLevel: String, CaseIterable, Equatable, Sendable {
    case automatic
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    var sessionValue: String {
        self == .automatic ? "reset" : rawValue
    }
}

struct LoopdyShortcutChatRequest: Equatable, Sendable {
    let message: String
    let agentID: String?
    let model: LoopdyShortcutModel?
    let reasoning: LoopdyShortcutReasoningLevel?
    let attachments: [ChatAttachment]
    let waitForResponse: Bool
}

struct LoopdyShortcutChatResult: Equatable, Sendable {
    enum Delivery: Equatable, Sendable {
        case queued
        case completed(String)
    }

    let sessionID: String
    let agentName: String
    let delivery: Delivery
}

struct LoopdyShortcutVoiceResult: Equatable, Sendable {
    let sessionID: String
    let agentName: String
}

enum LoopdyShortcutServiceError: LocalizedError, Equatable {
    case connectionUnavailable
    case agentUnavailable
    case sessionUnavailable
    case modelUnavailable
    case reasoningUnavailable
    case deliveryFailed
    case responseUnavailable
    case foregroundUnavailable
    case emptyMessage

    var errorDescription: String? {
        switch self {
        case .connectionUnavailable:
            "bighelp could not connect to your host. Open bighelp to check your account and connection, then run the shortcut again."
        case .agentUnavailable:
            "That agent is not available in Hermes."
        case .sessionUnavailable:
            "bighelp could not create the chat session."
        case .modelUnavailable:
            "That model is not available for this session."
        case .reasoningUnavailable:
            "That reasoning level is not available for this session."
        case .deliveryFailed:
            "Hermes could not complete the message. Open bighelp and try again."
        case .responseUnavailable:
            "No final text response was received. Open the chat in bighelp to check its progress."
        case .foregroundUnavailable:
            "Open bighelp to wait for a response, or turn off Wait for response to send in the background."
        case .emptyMessage:
            "Enter a message for your agent."
        }
    }
}

/// The stores that must travel together for one shortcut invocation. Native
/// workspaces own their own stores, so an intent cannot safely borrow the
/// app-level Link stores after a host is selected.
@MainActor
struct LoopdyShortcutWorkspace {
    let appState: AppState
    let agents: AgentDirectoryStore
    let runtimeDefaults: any AgentRuntimeDefaultsClient
    let catalog: SessionCatalogStore
    let featureStore: ShellFeatureStore
    let newChatCoordinator: NewChatCoordinator

    init(
        appState: AppState,
        agents: AgentDirectoryStore,
        runtimeDefaults: any AgentRuntimeDefaultsClient,
        catalog: SessionCatalogStore,
        featureStore: ShellFeatureStore,
        newChatCoordinator: NewChatCoordinator
    ) {
        self.appState = appState
        self.agents = agents
        self.runtimeDefaults = runtimeDefaults
        self.catalog = catalog
        self.featureStore = featureStore
        self.newChatCoordinator = newChatCoordinator
    }

    init(runtime: NativeWorkspaceRuntime) {
        self.init(
            appState: runtime.appState,
            agents: runtime.agents,
            runtimeDefaults: runtime.defaults,
            catalog: runtime.sessions,
            featureStore: runtime.features,
            newChatCoordinator: runtime.newChat
        )
    }
}

struct LoopdyShortcutWorkspaceKey: Equatable, Sendable {
    let hostID: UUID?
    let registryGeneration: UUID
    let owner: WorkspaceOwner?

    func stillAdmits(_ current: Self) -> Bool {
        hostID == current.hostID
            && registryGeneration == current.registryGeneration
            && (owner == nil || owner == current.owner)
    }
}

@MainActor
final class LoopdyShortcutService: @unchecked Sendable {
    private let fallbackWorkspace: LoopdyShortcutWorkspace
    private let prepareConnection: @MainActor () async throws -> Void
    private var workspaceResolver: (@MainActor (LoopdyShortcutWorkspaceKey) async throws -> LoopdyShortcutWorkspace?)?
    private var nativeWorkspaceKey: (@MainActor () -> LoopdyShortcutWorkspaceKey?)?
    private var reconnectHost: (@MainActor () async -> Void)?
    private var liveCheck: (key: LoopdyShortcutWorkspaceKey?, task: Task<LoopdyShortcutWorkspace, Error>)?
    private var preparation: (
        id: UUID,
        key: LoopdyShortcutWorkspaceKey?,
        task: Task<LoopdyShortcutWorkspace, Error>
    )?

    init(
        appState: AppState,
        agents: AgentDirectoryStore,
        runtimeDefaults: any AgentRuntimeDefaultsClient,
        catalog: SessionCatalogStore,
        featureStore: ShellFeatureStore,
        newChatCoordinator: NewChatCoordinator,
        prepareConnection: @escaping @MainActor () async throws -> Void = {}
    ) {
        self.fallbackWorkspace = LoopdyShortcutWorkspace(
            appState: appState,
            agents: agents,
            runtimeDefaults: runtimeDefaults,
            catalog: catalog,
            featureStore: featureStore,
            newChatCoordinator: newChatCoordinator
        )
        self.prepareConnection = prepareConnection
    }

    /// Binds the current native workspace selection without changing the
    /// App Intent dependency. The resolver is deliberately invoked for every
    /// preparation flight so host retirement and cold launch cannot leave an
    /// intent using an old workspace.
    func bindNativeWorkspace(
        key: @escaping @MainActor () -> LoopdyShortcutWorkspaceKey?,
        resolve: @escaping @MainActor (LoopdyShortcutWorkspaceKey) async throws -> LoopdyShortcutWorkspace?,
        reconnect: (@MainActor () async -> Void)? = nil
    ) {
        self.nativeWorkspaceKey = key
        self.workspaceResolver = resolve
        self.reconnectHost = reconnect
        preparation?.task.cancel()
        preparation = nil
    }

    func availableAgents() async throws -> [LoopdyShortcutAgent] {
        let workspace = try await liveWorkspace()
        return workspace.agents.profiles.map {
            LoopdyShortcutAgent(
                id: $0.id,
                name: $0.name,
                role: $0.role,
                isDefault: $0.isDefault
            )
        }
    }

    func availableModels(agentID: String?) async throws -> [LoopdyShortcutModel] {
        let workspace = try await liveWorkspace()
        let agent = try resolveAgent(explicitID: agentID, in: workspace)
        return try await workspace.runtimeDefaults.loadModelProviders(agentID: agent.id).flatMap {
            provider in
            provider.models.map {
                LoopdyShortcutModel(
                    providerID: provider.id,
                    providerName: provider.name,
                    modelID: $0
                )
            }
        }
    }

    func send(
        _ request: LoopdyShortcutChatRequest,
        continueInForeground: @MainActor () async throws -> Void = {}
    ) async throws -> LoopdyShortcutChatResult {
        let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw LoopdyShortcutServiceError.emptyMessage }
        try Task.checkCancellation()
        // Waiting no longer requires Loopdy in the foreground. The intent runs
        // in the app process, which keeps the Hermes socket alive while
        // Shortcuts waits. The hook stays for callers that still opt in.
        _ = continueInForeground
        Self.holdsHostConnection += 1
        // Ask iOS for background execution while the reply streams, so the
        // socket is not frozen when Shortcuts owns the foreground.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "bighelp Shortcut")
        defer {
            Self.holdsHostConnection -= 1
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        try Task.checkCancellation()
        let workspace = try await liveWorkspace()
        let agent = try resolveAgent(explicitID: request.agentID, in: workspace)
        defer { workspace.featureStore.flushChatPersistence() }
        let session = try await workspace.catalog.createDirect(agentID: agent.id)
        if request.waitForResponse {
            // Establish the visible handoff as soon as the host has created a
            // real session. Canvas/model preparation can perform additional
            // local restoration and must not leave the app on Sessions when it
            // is the only remaining step.
            workspace.appState.activateConversation(id: session.id, source: .newChat)
        }
        let model = try prepareChat(sessionID: session.id, in: workspace.featureStore)

        if let selection = request.model {
            try await applyModel(selection, to: model)
        }
        if let reasoning = request.reasoning, reasoning != .automatic {
            try await applyReasoning(reasoning, to: model)
        }

        // A just-created session is still attaching its event stream. send()
        // silently declines until then, which made waited Shortcuts report
        // "no response" and queued ones fail. Wait for the real readiness gate.
        try await Self.awaitTransportReady(model)

        if request.waitForResponse {
            let existingIDs = Set(model.items.map(\.id))
            model.draft = message
            for attachment in request.attachments {
                try model.addDraftAttachment(attachment)
            }
            var finished = false
            let turn = Task { @MainActor in await model.send(); finished = true }
            let deadline = ContinuousClock.now + responseWait
            while !finished, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(150))
            }
            try Task.checkCancellation()
            if !finished {
                // The system gives intents a limited budget. Stop waiting,
                // leave the turn running, and let notifications deliver it.
                return LoopdyShortcutChatResult(
                    sessionID: session.id, agentName: agent.name, delivery: .queued)
            }
            _ = await turn.value
            guard model.failureMessage == nil else {
                throw LoopdyShortcutServiceError.deliveryFailed
            }
            // Interim assistant messages can have their own identities. The
            // first new assistant item is not necessarily the final answer.
            let response = model.items.last { item in
                guard item.role == .assistant, !existingIDs.contains(item.id),
                      item.metadata.delivery != "Streaming",
                      case .message = item.content else { return false }
                return true
            }
            guard let response, case .message(let text) = response.content,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw LoopdyShortcutServiceError.responseUnavailable }
            let result = LoopdyShortcutChatResult(
                sessionID: session.id,
                agentName: agent.name,
                delivery: .completed(text)
            )
            return result
        }

        try await model.submitWithoutWaiting(
            message: message,
            attachments: request.attachments
        )
        let result = LoopdyShortcutChatResult(
            sessionID: session.id,
            agentName: agent.name,
            delivery: .queued
        )
        return result
    }

    /// iOS grants a background intent roughly 30 seconds. Hand off before
    /// the system suspends Loopdy so the Shortcut ends cleanly instead of
    /// failing; the running turn still finishes and notifies.
    var responseWait: Duration = .seconds(25)

    /// True while a Shortcut is sending or waiting. Backgrounding the scene
    /// must not retire the host socket underneath it.
    static private(set) var holdsHostConnection = 0

    static func awaitTransportReady(_ model: ChatModel, timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(model.directTransportIsReady && !model.isAwaitingAuthoritativeSessionAllocation) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw LoopdyShortcutServiceError.connectionUnavailable }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func startVoiceChat(agentID: String?) async throws -> LoopdyShortcutVoiceResult {
        let workspace = try await liveWorkspace()
        let agent = try resolveAgent(explicitID: agentID, in: workspace)
        let outcome = try await workspace.newChatCoordinator.start(explicitAgentID: agent.id)
        guard case .opened(let sessionID, _) = outcome else {
            throw LoopdyShortcutServiceError.sessionUnavailable
        }
        workspace.appState.requestVoiceMode(for: sessionID)
        return LoopdyShortcutVoiceResult(sessionID: sessionID, agentName: agent.name)
    }

    private func resolveAgent(
        explicitID: String?,
        in workspace: LoopdyShortcutWorkspace
    ) throws -> AgentProfile {
        guard let agent = workspace.agents.resolvedAgent(explicitID: explicitID) else {
            throw LoopdyShortcutServiceError.agentUnavailable
        }
        return agent
    }

    /// A workspace whose host actually answers. In the background the app closes
    /// its connection, and iOS can drop it while the app is suspended, yet the
    /// workspace may still look ready. Reading the agent list (small, and needed
    /// anyway) proves the connection; if the host is unreachable, reconnect once
    /// and try again before anything is sent.
    /// Simultaneous entity queries share one check, so their directory loads
    /// never supersede (and cancel) each other.
    private func liveWorkspace() async throws -> LoopdyShortcutWorkspace {
        let requestedKey = nativeWorkspaceKey?()
        if let liveCheck {
            if Self.keysCanShare(liveCheck.key, requestedKey) { return try await liveCheck.task.value }
            // The host changed underneath: stop the old check, never reuse it.
            liveCheck.task.cancel()
            self.liveCheck = nil
        }
        let check = Task { @MainActor in
            let workspace = try await self.prepareForUse()
            do {
                try await workspace.agents.load()
                return workspace
            } catch let error as WorkspaceClientError where error == .transportUnavailable || error == .ownerChanged {
                guard let reconnectHost = self.reconnectHost else { throw error }
                await reconnectHost()
                try Task.checkCancellation()
                let reconnected = try await self.prepareForUse()
                try await reconnected.agents.load()
                return reconnected
            }
        }
        liveCheck = (requestedKey, check)
        defer { if liveCheck?.task == check { liveCheck = nil } }
        return try await check.value
    }

    /// Shortcuts may run before a scene exists, and can resolve agent and model
    /// entities concurrently. Share readiness and directory loading across them.
    private func prepareForUse() async throws -> LoopdyShortcutWorkspace {
        try Task.checkCancellation()
        let requestedKey = nativeWorkspaceKey?()
        let flight: (
            id: UUID,
            key: LoopdyShortcutWorkspaceKey?,
            task: Task<LoopdyShortcutWorkspace, Error>
        )
        if let preparation {
            guard Self.keysCanShare(preparation.key, requestedKey) else {
                preparation.task.cancel()
                self.preparation = nil
                throw LoopdyShortcutServiceError.connectionUnavailable
            }
            flight = preparation
        } else {
            let workspaceResolver = self.workspaceResolver
            let fallbackWorkspace = self.fallbackWorkspace
            let prepareConnection = self.prepareConnection
            let nativeWorkspaceKey = self.nativeWorkspaceKey
            flight = (UUID(), requestedKey, Task { @MainActor in
                if let requestedKey {
                    guard let workspaceResolver,
                          let workspace = try await workspaceResolver(requestedKey) else {
                        throw LoopdyShortcutServiceError.connectionUnavailable
                    }
                    guard let currentKey = nativeWorkspaceKey?(),
                          requestedKey.stillAdmits(currentKey) else {
                        throw LoopdyShortcutServiceError.connectionUnavailable
                    }
                    return workspace
                }
                try await prepareConnection()
                try Task.checkCancellation()
                try await fallbackWorkspace.agents.load()
                return fallbackWorkspace
            })
            preparation = flight
        }
        defer {
            if preparation?.id == flight.id { preparation = nil }
        }
        let workspace = try await flight.task.value
        try Task.checkCancellation()
        return workspace
    }

    private static func keysCanShare(
        _ lhs: LoopdyShortcutWorkspaceKey?,
        _ rhs: LoopdyShortcutWorkspaceKey?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (.some(lhs), .some(rhs)):
            return lhs.stillAdmits(rhs) || rhs.stillAdmits(lhs)
        default:
            return false
        }
    }

    private func prepareChat(sessionID: String, in featureStore: ShellFeatureStore) throws -> ChatModel {
        let route = AppRoute.chat(conversationID: sessionID)
        guard
            featureStore.prepare(route),
            case .chat(let model)? = featureStore.preparedModel(for: route)
        else { throw LoopdyShortcutServiceError.sessionUnavailable }
        return model
    }

    private func applyModel(
        _ selection: LoopdyShortcutModel,
        to model: ChatModel
    ) async throws {
        guard let controls = model.runtimeControls else {
            throw LoopdyShortcutServiceError.modelUnavailable
        }
        await controls.loadModelPicker()
        guard controls.errorMessage == nil else {
            throw LoopdyShortcutServiceError.modelUnavailable
        }
        await controls.selectModel(
            providerID: selection.providerID,
            modelID: selection.modelID
        )
        guard
            controls.errorMessage == nil,
            controls.currentProvider == selection.providerID,
            controls.currentModel == selection.modelID
        else { throw LoopdyShortcutServiceError.modelUnavailable }
    }

    private func applyReasoning(
        _ reasoning: LoopdyShortcutReasoningLevel,
        to model: ChatModel
    ) async throws {
        guard let controls = model.runtimeControls else {
            throw LoopdyShortcutServiceError.reasoningUnavailable
        }
        await controls.loadReasoningPicker()
        guard controls.errorMessage == nil else {
            throw LoopdyShortcutServiceError.reasoningUnavailable
        }
        await controls.selectReasoning(value: reasoning.sessionValue)
        guard
            controls.errorMessage == nil,
            controls.currentReasoningValue == reasoning.sessionValue
        else { throw LoopdyShortcutServiceError.reasoningUnavailable }
    }
}

