import Foundation
import Testing
@testable import Loopdy

@MainActor
struct LoopdyShortcutServiceTests {
    @Test(arguments: [true, false])
    func automaticReasoningInheritsNewSessionDefaultsWithoutAnOverride(waitForResponse: Bool) async throws {
        let harness = try await ShortcutServiceHarness()
        _ = try await harness.service.send(.init(message: "Check this", agentID: "finance",
            model: nil, reasoning: .automatic, attachments: [], waitForResponse: waitForResponse))
        #expect(harness.controls.selections.isEmpty)
        #expect(harness.conversation.waitedMessages.count + harness.conversation.queuedMessages.count == 1)
    }

    @Test func waitedShortcutNeverAsksToOpenLoopdy() async throws {
        let harness = try await ShortcutServiceHarness()
        let result = try await harness.service.send(.init(message: "Check this", agentID: "finance",
            model: nil, reasoning: nil, attachments: [], waitForResponse: true)) {
                throw LoopdyShortcutServiceError.foregroundUnavailable
            }
        #expect(result.delivery == .completed("Finished from Finley"))
        #expect(harness.conversation.waitedMessages.count == 1)
    }

    @Test func slowTurnHandsOffInsteadOfFailingTheShortcut() async throws {
        let harness = try await ShortcutServiceHarness()
        harness.conversation.responseDelay = .seconds(5)
        harness.service.responseWait = .milliseconds(300)
        let result = try await harness.service.send(.init(message: "Check this", agentID: nil,
            model: nil, reasoning: nil, attachments: [], waitForResponse: true))
        #expect(result.delivery == .queued)
        #expect(harness.conversation.waitedMessages.count == 1)
    }

    @Test func sendOnlyDoesNotRequestForegroundContinuation() async throws {
        let harness = try await ShortcutServiceHarness()
        let result = try await harness.service.send(.init(message: "Check this", agentID: nil,
            model: nil, reasoning: nil, attachments: [], waitForResponse: false)) {
                throw LoopdyShortcutServiceError.foregroundUnavailable
            }
        #expect(result.delivery == .queued)
        #expect(harness.state.path.isEmpty)
        #expect(harness.conversation.queuedMessages.count == 1)
    }

    @Test func waitedShortcutReturnsTheFinalAnswerAfterInterimText() async throws {
        let harness = try await ShortcutServiceHarness()
        harness.conversation.interimText = "Let me check that."
        harness.conversation.responseDelay = .milliseconds(20)
        let result = try await harness.service.send(.init(message: "Check this", agentID: "finance",
            model: nil, reasoning: nil, attachments: [], waitForResponse: true))
        #expect(result.delivery == .completed("Finished from Finley"))
        #expect(harness.state.path == [.chat(conversationID: result.sessionID)])
    }

    @Test func waitedShortcutActivatesCreatedSessionBeforeCanvasPreparation() async throws {
        let harness = try await ShortcutServiceHarness()
        harness.sessionClient.returnsMetadataOnly = true

        await #expect(throws: LoopdyShortcutServiceError.sessionUnavailable) {
            try await harness.service.send(.init(
                message: "Open the created session",
                agentID: nil,
                model: nil,
                reasoning: nil,
                attachments: [],
                waitForResponse: true
            ))
        }

        #expect(harness.state.path == [.chat(conversationID: "session_shortcut_0001")])
    }

    @Test(arguments: [nil, "Let me check that."] as [String?])
    func waitedShortcutDoesNotClaimAnAnswerWhenNoFinalWasReceived(interimText: String?) async throws {
        let harness = try await ShortcutServiceHarness()
        harness.conversation.interimText = interimText
        harness.conversation.returnsEmptyResponse = true
        await #expect(throws: LoopdyShortcutServiceError.responseUnavailable) {
            try await harness.service.send(.init(message: "Check this", agentID: nil,
                model: nil, reasoning: nil, attachments: [], waitForResponse: true))
        }
    }

    @Test func cancellingAWaitedShortcutPropagatesCancellationWithoutSubmittingAgain() async throws {
        let harness = try await ShortcutServiceHarness()
        harness.conversation.responseDelay = .seconds(60)
        let send = Task { @MainActor in
            try await harness.service.send(.init(message: "Check this", agentID: nil,
                model: nil, reasoning: nil, attachments: [], waitForResponse: true))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while harness.conversation.waitedMessages.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(harness.conversation.waitedMessages.count == 1)
        send.cancel()
        await #expect(throws: CancellationError.self) { try await send.value }
        #expect(harness.catalog.records.count == 1)
        #expect(harness.conversation.waitedMessages.count == 1)
    }

    @Test func simultaneousShortcutEntityQueriesDoNotCancelEachOther() async throws {
        let harness = try await ShortcutServiceHarness()
        async let agents = harness.service.availableAgents()
        async let models = harness.service.availableModels(agentID: "finance")
        let choices = try await (agents, models)
        #expect(choices.0.count == 2)
        #expect(choices.1.count == 2)
    }

    @Test func shortcutUsesSelectedNativeWorkspaceAndRetainsLinkFallback() async throws {
        var fallbackPreparationCalls = 0
        let harness = try await ShortcutServiceHarness(prepareConnection: {
            fallbackPreparationCalls += 1
        })
        let nativeProfile = AgentProfile(
            id: "native-only",
            name: "Native Host Agent",
            role: "Native",
            summary: "The selected native host agent.",
            instructions: "",
            avatarFileName: nil,
            isDefault: true
        )
        let nativeAgents = AgentDirectoryStore(
            client: ShortcutAgentDirectoryClientFixture(profiles: [nativeProfile]),
            defaults: isolatedDefaults(),
            profiles: [nativeProfile]
        )
        let nativeState = AppState()
        let nativeCatalog = SessionCatalogStore(client: ShortcutSessionCatalogClientFixture())
        let nativeFeatureStore = ShellFeatureStore(
            timing: .immediate,
            catalog: nativeCatalog,
            agents: nativeAgents,
            conversationClient: { [conversation = harness.conversation] _, _ in conversation },
            sessionControlMessaging: harness.controls
        )
        let nativeNewChat = NewChatCoordinator(
            appState: nativeState,
            agents: nativeAgents,
            catalog: nativeCatalog,
            prepare: { [nativeFeatureStore] route in nativeFeatureStore.prepare(route) }
        )
        let nativeWorkspace = LoopdyShortcutWorkspace(
            appState: nativeState,
            agents: nativeAgents,
            runtimeDefaults: harness.runtimeDefaults,
            catalog: nativeCatalog,
            featureStore: nativeFeatureStore,
            newChatCoordinator: nativeNewChat
        )
        var nativeRoute = true
        var resolverCalls = 0
        let key = LoopdyShortcutWorkspaceKey(
            hostID: UUID(), registryGeneration: UUID(), owner: nil
        )
        harness.service.bindNativeWorkspace(key: { nativeRoute ? key : nil }) { _ in
            resolverCalls += 1
            return nativeWorkspace
        }

        #expect(try await harness.service.availableAgents().map(\.id) == ["native-only"])
        #expect(resolverCalls == 1)
        #expect(fallbackPreparationCalls == 0)
        let nativeResult = try await harness.service.send(.init(
            message: "Use the selected host",
            agentID: "native-only",
            model: nil,
            reasoning: nil,
            attachments: [],
            waitForResponse: false
        ))
        #expect(nativeResult.agentName == "Native Host Agent")
        #expect(nativeCatalog.records.count == 1)
        #expect(harness.catalog.records.isEmpty)

        nativeRoute = false
        #expect(try await harness.service.availableAgents().map(\.id) == ["default", "finance"])
        #expect(resolverCalls == 2)
        #expect(fallbackPreparationCalls == 1)
    }

    /// In the background the app closes its connection (or iOS drops it) while
    /// the workspace still looks ready. The Shortcut reconnects once instead of
    /// failing with "The host is unavailable".
    @Test func shortcutReconnectsOnceWhenTheHostConnectionWasDropped() async throws {
        let harness = try await ShortcutServiceHarness(prepareConnection: {})
        let profile = AgentProfile(id: "native-only", name: "Native Host Agent", role: "Native",
                                   summary: "", instructions: "", avatarFileName: nil, isDefault: true)
        let client = ShortcutAgentDirectoryClientFixture(profiles: [profile])
        client.failuresBeforeSuccess = 1
        let agents = AgentDirectoryStore(client: client, defaults: isolatedDefaults(), profiles: [profile])
        let state = AppState()
        let catalog = SessionCatalogStore(client: ShortcutSessionCatalogClientFixture())
        let featureStore = ShellFeatureStore(
            timing: .immediate, catalog: catalog, agents: agents,
            conversationClient: { [conversation = harness.conversation] _, _ in conversation },
            sessionControlMessaging: harness.controls
        )
        let workspace = LoopdyShortcutWorkspace(
            appState: state, agents: agents, runtimeDefaults: harness.runtimeDefaults, catalog: catalog,
            featureStore: featureStore,
            newChatCoordinator: NewChatCoordinator(appState: state, agents: agents, catalog: catalog,
                                                   prepare: { [featureStore] route in featureStore.prepare(route) })
        )
        let key = LoopdyShortcutWorkspaceKey(hostID: UUID(), registryGeneration: UUID(), owner: nil)
        var reconnects = 0
        harness.service.bindNativeWorkspace(key: { key }, resolve: { _ in workspace }, reconnect: { reconnects += 1 })

        #expect(try await harness.service.availableAgents().map(\.id) == ["native-only"])
        #expect(reconnects == 1)
        // A live connection is used as is.
        #expect(try await harness.service.availableAgents().map(\.id) == ["native-only"])
        #expect(reconnects == 1)

        // Without a way to reconnect, the honest error still surfaces.
        client.failuresBeforeSuccess = 1
        harness.service.bindNativeWorkspace(key: { key }, resolve: { _ in workspace })
        await #expect(throws: WorkspaceClientError.transportUnavailable) {
            try await harness.service.availableAgents()
        }
    }

    @Test func nativeShortcutPreparationRejectsHostSwitchWithoutLinkFallback() async throws {
        var fallbackPreparationCalls = 0
        let harness = try await ShortcutServiceHarness(prepareConnection: {
            fallbackPreparationCalls += 1
        })
        let firstKey = LoopdyShortcutWorkspaceKey(
            hostID: UUID(), registryGeneration: UUID(), owner: nil
        )
        let secondKey = LoopdyShortcutWorkspaceKey(
            hostID: UUID(), registryGeneration: UUID(), owner: nil
        )
        var requestedKey = firstKey
        var resolverStarted = false
        harness.service.bindNativeWorkspace(key: { requestedKey }) { _ in
            resolverStarted = true
            try await Task.sleep(for: .seconds(60))
            return nil
        }

        let first = Task { @MainActor in
            try await harness.service.availableAgents()
        }
        while !resolverStarted { await Task.yield() }
        requestedKey = secondKey
        await #expect(throws: LoopdyShortcutServiceError.connectionUnavailable) {
            try await harness.service.availableAgents()
        }
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(fallbackPreparationCalls == 0)
    }

    @Test func coldNativeShortcutAllowsOwnerToBeEstablishedDuringPreparation() async throws {
        var fallbackPreparationCalls = 0
        let harness = try await ShortcutServiceHarness(prepareConnection: {
            fallbackPreparationCalls += 1
        })
        let hostID = UUID()
        let registryGeneration = UUID()
        let authority = try WorkspaceAuthority.fixture(id: "shortcut-cold")
        let owner = WorkspaceOwner(
            authority: authority,
            authenticationGeneration: UUID(),
            connectionGeneration: UUID()
        )
        let initialKey = LoopdyShortcutWorkspaceKey(
            hostID: hostID,
            registryGeneration: registryGeneration,
            owner: nil
        )
        var currentKey = initialKey
        let workspace = LoopdyShortcutWorkspace(
            appState: harness.state,
            agents: harness.agents,
            runtimeDefaults: harness.runtimeDefaults,
            catalog: harness.catalog,
            featureStore: harness.featureStore,
            newChatCoordinator: harness.newChat
        )
        harness.service.bindNativeWorkspace(key: { currentKey }) { _ in
            currentKey = LoopdyShortcutWorkspaceKey(
                hostID: hostID,
                registryGeneration: registryGeneration,
                owner: owner
            )
            return workspace
        }

        #expect(try await harness.service.availableAgents().count == 2)
        #expect(fallbackPreparationCalls == 0)
    }

    @Test(arguments: ["agents", "models", "send", "voice"])
    func shortcutWaitsForConnectionBeforeUsingHostServices(operation: String) async throws {
        let harness = try await ShortcutServiceHarness(prepareConnection: { throw URLError(.notConnectedToInternet) })
        await #expect(throws: URLError.self) {
            switch operation {
            case "agents": _ = try await harness.service.availableAgents()
            case "models": _ = try await harness.service.availableModels(agentID: nil)
            case "voice": _ = try await harness.service.startVoiceChat(agentID: nil)
            default:
                _ = try await harness.service.send(.init(message: "Hello", agentID: nil, model: nil,
                    reasoning: nil, attachments: [], waitForResponse: false))
            }
        }
        #expect(harness.catalog.records.isEmpty)
        #expect(harness.conversation.queuedMessages.isEmpty)
        #expect(harness.state.path.isEmpty)
    }

    @Test func waitedShortcutCreatesSessionAppliesSessionOverridesAndReturnsFinalText() async throws {
        let harness = try await ShortcutServiceHarness()
        let attachment = try ChatAttachment(
            id: "shortcut_attachment_0001",
            fileName: "brief.pdf",
            mimeType: "application/pdf",
            data: Data("brief".utf8)
        )

        let result = try await harness.service.send(
            LoopdyShortcutChatRequest(
                message: "Summarize this brief",
                agentID: "finance",
                model: LoopdyShortcutModel(
                    providerID: "openai",
                    providerName: "OpenAI",
                    modelID: "gpt-5.6"
                ),
                reasoning: .high,
                attachments: [attachment],
                waitForResponse: true
            )
        )

        #expect(result.sessionID == "session_shortcut_0001")
        #expect(result.agentName == "Finley")
        #expect(result.delivery == .completed("Finished from Finley"))
        #expect(harness.conversation.waitedMessages == [
            .init(
                sessionID: "session_shortcut_0001",
                message: "Summarize this brief",
                attachments: [attachment]
            ),
        ])
        #expect(harness.controls.selections.count == 2)
        #expect(harness.controls.selections.allSatisfy {
            $0.sessionID == "session_shortcut_0001"
        })
        #expect(harness.controls.selections[0].provider == "openai")
        #expect(harness.controls.selections[0].model == "gpt-5.6")
        #expect(harness.controls.selections[1].value == "high")
        #expect(harness.state.path == [.chat(conversationID: result.sessionID)])
        #expect(harness.catalog.session(id: result.sessionID)?.items.count == 2)
    }

    @Test func queuedShortcutPersistsTheHumanTurnWithoutOpeningTheChat() async throws {
        let harness = try await ShortcutServiceHarness()

        let result = try await harness.service.send(
            LoopdyShortcutChatRequest(
                message: "Do this in the background",
                agentID: nil,
                model: nil,
                reasoning: nil,
                attachments: [],
                waitForResponse: false
            )
        )

        #expect(result.delivery == .queued)
        #expect(result.agentName == "Avery")
        #expect(harness.conversation.queuedMessages.map(\.message) == [
            "Do this in the background",
        ])
        #expect(harness.state.path.isEmpty)
        let session = try #require(harness.catalog.session(id: result.sessionID))
        #expect(session.agentIDs == ["default"])
        #expect(session.items.count == 1)
        #expect(session.items.first?.role == .human)
    }

    @Test func modelChoicesComeFromTheSelectedAgentsHermesCatalog() async throws {
        let harness = try await ShortcutServiceHarness()

        let choices = try await harness.service.availableModels(agentID: "finance")

        #expect(harness.runtimeDefaults.loadedModelAgentIDs == ["finance"])
        #expect(choices == [
            LoopdyShortcutModel(
                providerID: "nous",
                providerName: "Nous Research",
                modelID: "Hermes-4-405B"
            ),
            LoopdyShortcutModel(
                providerID: "openai",
                providerName: "OpenAI",
                modelID: "gpt-5.6"
            ),
        ])
    }

    @Test func voiceShortcutOpensANewSessionAndRequestsVoiceModeForIt() async throws {
        let harness = try await ShortcutServiceHarness()

        let result = try await harness.service.startVoiceChat(agentID: "finance")

        #expect(result == .init(sessionID: "session_shortcut_0001", agentName: "Finley"))
        #expect(harness.state.path == [
            .chat(conversationID: "session_shortcut_0001"),
        ])
        #expect(harness.state.pendingVoiceConversationID == "session_shortcut_0001")
        #expect(harness.state.consumeVoiceRequest(for: "another_session_0001") == false)
        #expect(harness.state.consumeVoiceRequest(for: "session_shortcut_0001"))
        #expect(harness.state.pendingVoiceConversationID == nil)
    }
}

@MainActor
private final class ShortcutServiceHarness {
    let state = AppState()
    let agents: AgentDirectoryStore
    let sessionClient: ShortcutSessionCatalogClientFixture
    let catalog: SessionCatalogStore
    let featureStore: ShellFeatureStore
    let newChat: NewChatCoordinator
    let conversation = ShortcutConversationClientFixture()
    let controls = ShortcutSessionControlMessagingFixture()
    let runtimeDefaults = ShortcutRuntimeDefaultsClientFixture()
    let service: LoopdyShortcutService

    init(prepareConnection: @escaping @MainActor () async throws -> Void = {}) async throws {
        let agents = AgentDirectoryStore(
            client: ShortcutAgentDirectoryClientFixture(
                profiles: [.defaultFixture, .financeFixture]
            ),
            defaults: isolatedDefaults()
        )
        try await agents.load()
        self.agents = agents
        let sessionClient = ShortcutSessionCatalogClientFixture()
        self.sessionClient = sessionClient
        let catalog = SessionCatalogStore(client: sessionClient)
        self.catalog = catalog
        let featureStore = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            agents: agents,
            conversationClient: { [conversation] _, _ in conversation },
            sessionControlMessaging: controls
        )
        self.featureStore = featureStore
        let newChat = NewChatCoordinator(
            appState: state,
            agents: agents,
            catalog: catalog,
            prepare: { [featureStore] route in featureStore.prepare(route) }
        )
        self.newChat = newChat
        service = LoopdyShortcutService(
            appState: state,
            agents: agents,
            runtimeDefaults: runtimeDefaults,
            catalog: catalog,
            featureStore: featureStore,
            newChatCoordinator: newChat,
            prepareConnection: prepareConnection
        )
    }
}

@MainActor
private final class ShortcutAgentDirectoryClientFixture: AgentDirectoryClient {
    let profiles: [AgentProfile]
    /// Reads that fail like a dropped host connection before one succeeds.
    var failuresBeforeSuccess = 0

    init(profiles: [AgentProfile]) {
        self.profiles = profiles
    }

    func list() async throws -> [AgentProfile] {
        await Task.yield()
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw WorkspaceClientError.transportUnavailable
        }
        return profiles
    }
    func create(_ draft: AgentDraft) async throws -> AgentProfile { fatalError("unused") }
    func update(id: String, draft: AgentDraft) async throws -> AgentProfile { fatalError("unused") }
}

@MainActor
private final class ShortcutSessionCatalogClientFixture: SessionCatalogClient {
    private var records: [SessionRecord] = []
    private var nextID = 1
    var returnsMetadataOnly = false

    func list() async throws -> [SessionRecord] { records }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        var record = SessionRecord(
            id: "session_shortcut_" + String(format: "%04d", nextID),
            kind: kind,
            agentIDs: agentIDs,
            title: "Shortcut chat"
        )
        if returnsMetadataOnly { record.localContentRevision = UUID() }
        nextID += 1
        records.append(record)
        return record
    }
}

@MainActor
private final class ShortcutConversationClientFixture:
    AttachmentConversationClient,
    QueuedConversationClient
{
    struct Submission: Equatable {
        let sessionID: String
        let message: String
        let attachments: [ChatAttachment]
    }

    private(set) var waitedMessages: [Submission] = []
    private(set) var queuedMessages: [Submission] = []
    var interimText: String?
    var responseDelay: Duration = .zero
    var returnsEmptyResponse = false

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        try await send(
            message: message,
            attachments: [],
            conversationID: conversationID,
            onDraft: { _ in }
        )
    }

    func send(
        message: String,
        attachments: [ChatAttachment],
        conversationID: String,
        onDraft: @escaping (TimelineItem) -> Void
    ) async throws -> ConversationResponse {
        waitedMessages.append(
            .init(sessionID: conversationID, message: message, attachments: attachments)
        )
        if let interimText {
            onDraft(TimelineItem(id: "shortcut_interim_0001", role: .assistant,
                sender: .agent(id: "finance", snapshot: .init(name: "Finley")),
                content: .message(interimText), metadata: .init(delivery: "Streaming")))
        }
        if responseDelay > .zero { try await Task.sleep(for: responseDelay) }
        if returnsEmptyResponse { return ConversationResponse(items: []) }
        return ConversationResponse(items: [
            TimelineItem(
                id: "shortcut_response_0001",
                role: .assistant,
                sender: .agent(id: "finance", snapshot: .init(name: "Finley")),
                content: .message("Finished from Finley"),
                metadata: .init(delivery: "Delivered")
            ),
        ])
    }

    func submit(
        message: String,
        attachments: [ChatAttachment],
        conversationID: String
    ) async throws {
        queuedMessages.append(
            .init(sessionID: conversationID, message: message, attachments: attachments)
        )
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        try await send(message: action.intent, conversationID: conversationID)
    }
}

@MainActor
private final class ShortcutRuntimeDefaultsClientFixture: AgentRuntimeDefaultsClient {
    private(set) var loadedModelAgentIDs: [String] = []

    func loadDefaults(agentID: String) async throws -> AgentRuntimeDefaults {
        .automatic
    }

    func loadModelProviders(agentID: String) async throws -> [LoopdyLinkModelProvider] {
        loadedModelAgentIDs.append(agentID)
        return [
            LoopdyLinkModelProvider(
                id: "nous",
                name: "Nous Research",
                isCurrent: true,
                isCustom: false,
                models: ["Hermes-4-405B"]
            ),
            LoopdyLinkModelProvider(
                id: "openai",
                name: "OpenAI",
                isCurrent: false,
                isCustom: false,
                models: ["gpt-5.6"]
            ),
        ]
    }

    func saveDefaults(_ defaults: AgentRuntimeDefaults, agentID: String) async throws {}
}

@MainActor
private final class ShortcutSessionControlMessagingFixture: LoopdyLinkSessionControlMessaging {
    private(set) var selections: [LoopdyLinkPickerSelection] = []

    func openPicker(_ request: LoopdyLinkPickerOpenRequest) async throws -> LoopdyLinkPicker {
        switch request.kind {
        case .model:
            return .model(try decodeModelPicker(sessionID: request.sessionID))
        case .reasoning:
            return .choice(try decodeReasoningPicker(sessionID: request.sessionID))
        }
    }

    func selectPicker(_ selection: LoopdyLinkPickerSelection) async throws -> LoopdyLinkPickerResult {
        selections.append(selection)
        let payload: [String: Any] = [
            "version": 1,
            "type": "picker.result",
            "pickerId": selection.pickerID,
            "sessionId": selection.sessionID,
            "kind": selection.kind.rawValue,
            "status": "completed",
            "message": "Updated",
            "sentAt": 1_788_000_010,
        ]
        return try JSONDecoder().decode(
            LoopdyLinkPickerResult.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    private func decodeModelPicker(sessionID: String) throws -> LoopdyLinkModelPicker {
        let payload: [String: Any] = [
            "version": 1,
            "type": "picker.model",
            "pickerId": "picker_shortcut_model_0001",
            "sessionId": sessionID,
            "currentModel": "Hermes-4-405B",
            "currentProvider": "nous",
            "providers": [
                [
                    "id": "nous",
                    "name": "Nous Research",
                    "isCurrent": true,
                    "isCustom": false,
                    "models": ["Hermes-4-405B"],
                ],
                [
                    "id": "openai",
                    "name": "OpenAI",
                    "isCurrent": false,
                    "isCustom": false,
                    "models": ["gpt-5.6"],
                ],
            ],
            "sentAt": 1_788_000_010,
        ]
        return try JSONDecoder().decode(
            LoopdyLinkModelPicker.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    private func decodeReasoningPicker(sessionID: String) throws -> LoopdyLinkChoicePicker {
        let payload: [String: Any] = [
            "version": 1,
            "type": "picker.choice",
            "pickerId": "picker_shortcut_reason_0001",
            "sessionId": sessionID,
            "kind": "reasoning",
            "title": "Reasoning effort",
            "choices": [
                ["value": "reset", "label": "Use default", "isCurrent": true],
                ["value": "high", "label": "High", "isCurrent": false],
            ],
            "sentAt": 1_788_000_010,
        ]
        return try JSONDecoder().decode(
            LoopdyLinkChoicePicker.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }
}
