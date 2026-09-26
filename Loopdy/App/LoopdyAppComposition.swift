import Foundation
import SwiftUI
import UIKit

@MainActor
struct LoopdyAppComposition {
    static let loadsProductionSessionRepositoryOnInit = true

    let workspaceConnectivity: LoopdyWorkspaceConnectivity = .nativeOnly
    /// Historical fixture discriminator; never a production chat account gate.
    let requiresLinkAccount: Bool
    let appState: AppState
    let settings: SettingsStore
    let companion: CompanionStore
    let userIdentity: UserIdentityStore
    let agentDirectory: AgentDirectoryStore
    let agentRuntimeDefaults: any AgentRuntimeDefaultsClient
    let botModeRooms: BotModeRoomStore
    let linkAccount: LoopdyLinkAccountStore
    let linkDevices: LoopdyLinkDeviceStore
    let permissionCenter: PermissionCenter
    let permissionsOnboarding: PermissionsOnboardingModel
    let managedNotificationFactory: LoopdyManagedNotificationFactory
    let sessionCatalog: SessionCatalogStore
    let scheduledTasks: ScheduledTasksStore
    let personalities: PersonalityStore
    let skillsAndTools: SkillsAndToolsStore
    let hermesWorkspaces: HermesWorkspaceStore
    let projectGitClient: any ProjectGitClient
    let loopdyCardDataClient: any LoopdyCardDataFetching
    let optionalReferences: OptionalReferenceServices
    let featureStore: ShellFeatureStore
    let subagentStreamAcceptanceFixture: SubagentStreamAcceptanceFixtureController?
    let watchApprovalBridge: LoopdyWatchApprovalBridge?
    let newChatCoordinator: NewChatCoordinator
    let shortcutService: LoopdyShortcutService
    let clearLocalCache: @MainActor () async -> Bool

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaults: UserDefaults = .standard,
        credentialVault: (any LoopdyLinkCredentialVault)? = nil,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) {
        let usesFixtures = arguments.contains("-disable-demo-delays")
            || arguments.contains("-use-demo-fixtures")
        let usesCardGallery = usesFixtures && arguments.contains("-use-loopdy-card-gallery")
        #if DEBUG
        let homeWeatherFixture = usesFixtures ? HomeWeatherAcceptanceFixture(arguments: arguments) : nil
        #endif
        loopdyCardDataClient = LoopdyCardStaticDataClient()
        let timing: DemoFixtureTiming = .immediate
        let appState = AppState()
        if arguments.contains("-start-inbox") {
            appState.select(.inbox)
        }
        if usesFixtures, let index = arguments.firstIndex(of: "-initial-tab"),
           arguments.indices.contains(index + 1), let tab = AppTab(rawValue: arguments[index + 1]) {
            appState.select(tab)
        }
        let settings = SettingsStore(defaults: defaults)
        #if DEBUG
        if usesFixtures, arguments.contains("-test-root-chrome-canvas") {
            // Non-system colors make missing shared background ownership visible.
            let chromeTheme = try! CustomTheme(
                id: UUID(uuidString: "6F64BA03-2672-48A2-88B4-B78BC6323779")!,
                name: "Chrome canvas fixture", font: .system, accentHex: "6688CC",
                light: CustomThemePalette(backgroundHex: "E0E8F0", primaryTextHex: "111111",
                                          secondaryTextHex: "333333", tertiaryTextHex: "555555"),
                dark: CustomThemePalette(backgroundHex: "203040", primaryTextHex: "FFFFFF",
                                         secondaryTextHex: "D0D8E0", tertiaryTextHex: "B8C4D0")
            )
            try! settings.saveCustomTheme(chromeTheme)
            settings.themeID = chromeTheme.themeID
        }
        #endif
        let companion = CompanionStore(defaults: defaults)
        #if DEBUG
        if usesFixtures, let index = arguments.firstIndex(of: "-test-companion-adventure"),
           arguments.indices.contains(index + 1) {
            companion.isAdventurous = arguments[index + 1] == "on"
        }
        if usesFixtures, let index = arguments.firstIndex(of: "-test-companion-scale"),
           arguments.indices.contains(index + 1), let scale = Double(arguments[index + 1]) {
            companion.sizeScale = scale
        }
        if usesFixtures,
           let index = arguments.firstIndex(of: "-test-companion-character"),
           arguments.indices.contains(index + 1),
           let character = CompanionCharacter(id: arguments[index + 1]) {
            companion.defaultAppearance = CompanionAppearance(character: character, usesCharacterColors: true)
            companion.isEnabled = true
        }
        if usesFixtures, arguments.contains("-test-companion-disabled") { companion.isEnabled = false }
        // "-test-agent-companion finance:octopus": one demo agent wears a creator look.
        if usesFixtures, let index = arguments.firstIndex(of: "-test-agent-companion"),
           arguments.indices.contains(index + 1) {
            let parts = arguments[index + 1].split(separator: ":").map(String.init)
            if parts.count == 2, let character = CompanionCharacter(id: parts[1]) {
                companion.setOverride(
                    CompanionAppearance(character: character, colorHex: "#E0457B", matchesTheme: false),
                    for: CompanionStore.agentKey(agentScope: "fixture-account:fixture-host", agentID: parts[0]))
            }
        }
        #endif
        if usesFixtures, arguments.contains("-enable-project-changes") {
            settings.showProjectChanges = true
        }
        let acceptanceStorageID = LoopdyRuntimeConfiguration.nativeAcceptanceStorageID(arguments: arguments)
        let baseDirectory = LoopdyApplicationDataDirectories.active(
            fixtures: usesFixtures
        )
        let dataDirectory = acceptanceStorageID.map {
            baseDirectory.appending(path: "native-acceptance-" + $0.uuidString, directoryHint: .isDirectory)
        } ?? baseDirectory
        let protectedDataAvailability: any LoopdyProtectedDataAvailabilityProviding = usesFixtures
            ? LoopdyFixtureProtectedDataAvailability()
            : LoopdySystemProtectedDataAvailability()
        let legacySocketDataDirectories = LoopdyApplicationDataDirectories.legacySocketDirectories(
            fixtures: usesFixtures
        )
        #if DEBUG
        if arguments.contains("-reset-host-selection-fixture") {
            defaults.removeObject(forKey: "loopdy.link.selected-host-id")
            defaults.removeObject(forKey: "loopdy.link.primary-host-id")
        }
        #endif
        let hostSelection = LoopdyLinkHostSelectionStore(defaults: defaults)
        let hostRepositoryScope = LoopdyHostRepositoryScope(
            hostID: hostSelection.selectedHostID
        )
        if !usesFixtures {
            try? LoopdyMarketplaceRetirementMigration.run(
                dataDirectory: dataDirectory,
                defaults: defaults
            )
            LoopdyHostCacheMigration.discardLegacyCachesForStartup(
                in: dataDirectory,
                defaults: defaults
            )
        }
        let agentRepository = DemoRepository<[AgentProfile]>(
            directory: dataDirectory,
            name: "agents",
            seed: usesFixtures
                ? DemoAgentDirectoryClient.fixtureProfiles
                : [],
            protectedDataAvailability: protectedDataAvailability,
            scopeID: usesFixtures ? nil : { hostRepositoryScope.hostID }
        )
        var initialAgentProfiles = Self.loadInitialAgentProfiles(
            usesFixtures: usesFixtures,
            repository: agentRepository
        )
        #if DEBUG && targetEnvironment(simulator)
        if usesFixtures, arguments.contains(AgentsAcceptanceFixture.launchArgument) {
            initialAgentProfiles = AgentsAcceptanceFixture.profiles
            do { try agentRepository.save(initialAgentProfiles) }
            catch { preconditionFailure("The synthetic Agents fixture could not be saved.") }
        }
        #endif
        let userIdentity = UserIdentityStore(
            defaults: defaults,
            avatarDirectory: dataDirectory.appending(path: "user-avatars", directoryHint: .isDirectory)
        )
        // Optional notification configuration must never prevent native startup.
        let linkBaseURL = (try? LoopdyRuntimeConfiguration.nativeAcceptanceLinkOrigin(arguments: arguments))
            ?? (try? LoopdyRuntimeConfiguration.linkBaseURL(infoDictionary: infoDictionary))
        let linkAPI = LoopdyLinkAPI(baseURL: linkBaseURL)
        #if DEBUG
        let usesEphemeralCredentialVault = arguments.contains("-force-signed-out-onboarding")
            || acceptanceStorageID != nil
            || (usesFixtures && HostRuntimePreviewClient.scenario(arguments: arguments) != nil)
        #else
        let usesEphemeralCredentialVault = false
        #endif
        let linkVault: any LoopdyLinkCredentialVault = credentialVault
            ?? (usesEphemeralCredentialVault
                ? LoopdyLinkMemoryCredentialVault()
                : LoopdyLinkKeychainCredentialVault())
        let hostSelectionChangeRelay = LoopdyHostSelectionChangeRelay()
        let unavailable = NativeWorkspaceUnavailableClient()
        let unavailableCatalog = UnavailableAppCatalogClient()
        let optionalReferences = OptionalReferenceServices(
            configuration: nil // Legacy account cleanup only; provider features are retired.
        )
        let skillsAndToolsClient: any HermesSkillsAndToolsCatalogClient = usesFixtures
            ? FixtureSkillsAndToolsClient()
            : unavailable
        let hermesWorkspaceClient: any HermesWorkspaceCatalogClient = usesFixtures
            ? FixtureHermesWorkspaceClient()
            : unavailableCatalog
        let skillsAndTools = SkillsAndToolsStore(client: skillsAndToolsClient)
        let hermesWorkspaces = HermesWorkspaceStore(client: hermesWorkspaceClient)
        let projectGitClient: any ProjectGitClient = usesFixtures
            ? FixtureProjectGitClient(
                usesMarkdownPreview: arguments.contains("-use-project-changes-markdown-fixture"),
                isNonRepository: arguments.contains("-use-project-changes-non-repository-fixture")
            )
            : unavailable
        let runtimeDefaultsBase: any AgentRuntimeDefaultsClient = usesFixtures
            ? FixtureAgentRuntimeDefaultsClient()
            : unavailableCatalog
        let cachedAgentRuntimeDefaults = CachedAgentRuntimeDefaultsClient(
            base: runtimeDefaultsBase,
            connectionIdentity: usesFixtures ? "fixtures" : "no-native-workspace",
            connectionGeneration: { 0 }
        )
        let agentRuntimeDefaults: any AgentRuntimeDefaultsClient = cachedAgentRuntimeDefaults
        var agentClient: any AgentDirectoryClient = usesFixtures
            ? DemoAgentDirectoryClient(repository: agentRepository)
            : unavailableCatalog
        #if DEBUG
        if usesFixtures, let scenario = HostRuntimePreviewClient.scenario(arguments: arguments) {
            if scenario != .restart {
                agentClient = HostRuntimeAgentPreviewClient(isCapabilityMissing: scenario == .gatewayOutdated)
            }
            if arguments.contains("-host-diagnostics-empty-agents") { initialAgentProfiles = [] }
        }
        #endif
        let agentDirectory = AgentDirectoryStore(
            client: agentClient,
            defaults: defaults,
            profiles: initialAgentProfiles,
            avatarDirectory: usesFixtures ? agentRepository.avatarsDirectory : nil,
            avatarDirectoryProvider: usesFixtures ? nil : {
                try? agentRepository.scopedAvatarsDirectory()
            },
            currentHostID: { hostSelection.selectedHostID }
        )
        let usesOverflowStatusRailFixture = usesFixtures
            && arguments.contains("-use-overflow-status-rail-fixture")
        var initialSessions = AppFixtureSetup.sessions(arguments: arguments, usesFixtures: usesFixtures)
        #if DEBUG
        let homeWorkFixture: HomeWorkAcceptanceFixture? = usesFixtures && arguments.contains("-test-home-work")
            ? HomeWorkAcceptanceFixture(expires: arguments.contains("-test-home-work-expiry")) : nil
        if homeWorkFixture != nil { initialSessions = HomeWorkAcceptanceFixture.records }
        #endif
        let sessionClient: any SessionCatalogClient = usesFixtures
            ? DemoSessionCatalogClient(records: initialSessions)
            : UnavailableAppSessionCatalogClient()
        let sessionRepository = SessionContentRepository(
            directory: dataDirectory,
            name: "sessions",
            seed: usesFixtures ? DemoSessionCatalogClient.fixtureRecords : [],
            protectedDataAvailability: protectedDataAvailability,
            scopeID: usesFixtures ? nil : { hostRepositoryScope.hostID }
        )
        let forkClient: any SessionForkClient = usesFixtures
            ? LocalSessionForkClient()
            : unavailable
        let sessionCatalog = SessionCatalogStore(
            client: sessionClient,
            records: initialSessions,
            repository: { () -> (any SessionCatalogRepository)? in
                #if DEBUG
                if usesFixtures, arguments.contains("-test-tool-stream") || arguments.contains("-test-idle-replay") {
                    return DemoRepository<[SessionRecord]>(
                        directory: FileManager.default.temporaryDirectory.appendingPathComponent("tool-stream-\(UUID().uuidString)", isDirectory: true),
                        name: "sessions", seed: initialSessions,
                        protectedDataAvailability: protectedDataAvailability
                    )
                }
                #endif
                if usesFixtures, arguments.contains("-preview-ui-v3") { return nil }
                if arguments.contains("-start-chat-mid-session") { return nil }
                #if DEBUG
                if arguments.contains("-demo-collaboration") || arguments.contains("-test-session-model")
                    || arguments.contains("-test-session-organization") || arguments.contains("-test-home-work")
                    || arguments.contains(AppStoreScreenshotFixture.launchArgument) { return nil }
                #endif
                return sessionRepository
            }(),
            loadsRepositoryOnInit: Self.loadsProductionSessionRepositoryOnInit,
            forkClient: forkClient,
            defaults: defaults,
            currentHostID: { hostRepositoryScope.hostID },
            defaultActivityVisibility: { settings.chatActivityVisibility }
        )
        let botModeRepository = DemoRepository<[BotModeRoom]>(
            directory: dataDirectory,
            name: BotModeRoomCacheSchema.repositoryName,
            seed: [],
            protectedDataAvailability: protectedDataAvailability,
            migrations: BotModeRoomCacheSchema.migrations,
            scopeID: usesFixtures ? nil : { hostRepositoryScope.hostID },
            currentSchemaVersion: BotModeRoomCacheSchema.currentVersion
        )
        let botModeRooms = BotModeRoomStore(
            client: usesFixtures
                ? BotModeFixtureClient()
                : unavailable,
            repository: botModeRepository,
            executionEnabled: usesFixtures
        )
        #if DEBUG && targetEnvironment(simulator)
        if usesFixtures,
           arguments.contains(AgentsAcceptanceFixture.launchArgument) || arguments.contains("-preview-agent-groups")
            || arguments.contains(AppStoreScreenshotFixture.launchArgument) {
            botModeRooms.configureNativeClient(BotModeCatalogFixtureClient(
                previewsExistingGroup: arguments.contains("-preview-agent-groups"),
                showsStoreScreenshots: arguments.contains(AppStoreScreenshotFixture.launchArgument)
            ))
        }
        #endif
        do {
            try BotModeRoomLoadingPolicy.load(botModeRooms, for: .startup)
        } catch {
            // Startup never probes optional Bot Mode persistence. Explicit Bot
            // Mode entry owns its recoverable error state.
        }
        #if DEBUG
        let fixtureTasks = arguments.contains(AppStoreScreenshotFixture.launchArgument)
            ? AppStoreScreenshotFixture.tasks : ScheduledTasksFixtureClient.defaultTasks
        #else
        let fixtureTasks = ScheduledTasksFixtureClient.defaultTasks
        #endif
        let scheduledTasks = ScheduledTasksStore(
            client: usesFixtures
                ? ScheduledTasksFixtureClient(tasks: fixtureTasks)
                : unavailableCatalog,
            initialAgentID: agentDirectory.resolvedAgent(explicitID: nil)?.id
        )
        let passkeys: any LoopdyLinkPasskeyAuthorizing
        if #available(iOS 18.0, *) {
            passkeys = LoopdyLinkPasskeyCoordinator()
        } else {
            passkeys = LoopdyLinkUnavailablePasskeyAuthorizer()
        }
        let deviceKind: LoopdyLinkDeviceKind = UIDevice.current.userInterfaceIdiom == .pad
            ? .tablet
            : .phone
        let linkAccount = LoopdyLinkAccountStore(
            api: linkAPI,
            passkeys: passkeys,
            vault: linkVault,
            localDataEraser: ReferenceAccountDataEraser(base: LoopdyLocalAccountDataEraser(
                dataDirectory: dataDirectory,
                additionalDataDirectories: legacySocketDataDirectories + [LoopdyManagedNotificationLedger.storageRoot],
                defaults: defaults,
                secretEraser: LoopdyLocalAccountKeychainSecretEraser()
            ), references: optionalReferences),
            eraseUserPreferences: {
                AgentDirectoryStore.erasePersistedUserPreferences(defaults: defaults)
                SessionCatalogStore.erasePersistedUserPreferences(defaults: defaults)
                SettingsStore.eraseSessionSectionPreferences(defaults: defaults)
            },
            deviceName: UIDevice.current.name,
            deviceKind: deviceKind
        )
        linkAccount.restore()
        optionalReferences.bind(owner: nil, credentials: linkAccount.credentials, accountID: linkAccount.credentials?.deviceID,
                                currentOwner: { nil })
        let linkDeviceClient: any LoopdyLinkDeviceClient = usesFixtures
            ? LoopdyLinkFixtureClient(
                devices: arguments.contains("-use-multi-host-fixtures")
                    ? LoopdyLinkFixtureClient.multiHostDevices
                    : LoopdyLinkFixtureClient.defaultDevices
            )
            : LoopdyLinkProductionClient(
                api: linkAPI,
                vault: linkVault
            )
        let linkDevices = LoopdyLinkDeviceStore(
            client: linkDeviceClient,
            hostSelection: hostSelection,
            onSelectedHostChange: { hostSelectionChangeRelay.send($0) }
        )
        let appleDeviceTools = AppleDeviceToolService()
        let deviceToolPermissions = DeviceToolPermissions(
            status: { kind in usesFixtures ? .unavailable : await appleDeviceTools.status(kind) },
            request: { kind in usesFixtures ? .unavailable : await appleDeviceTools.request(kind) },
            isForeground: { !usesFixtures && UIApplication.shared.applicationState == .active },
            readGrants: { defaults.stringArray(forKey: $0) ?? [] },
            writeGrants: { defaults.set($1, forKey: $0) }
        )
        let deviceToolCoordinator = DeviceToolCoordinator(
            permissions: deviceToolPermissions,
            journal: DeviceToolFileJournal(url: dataDirectory.appending(path: "device-tool-outcomes-v1.json")),
            clock: { Int(Date().timeIntervalSince1970) },
            available: {
                !usesFixtures && UIApplication.shared.applicationState == .active
                    && UIApplication.shared.isProtectedDataAvailable
            },
            execute: { operation, arguments, authorize in
                try await appleDeviceTools.execute(operation: operation, arguments: arguments, authorize: authorize)
            }
        )
        #if DEBUG
        let permissionCenter = homeWeatherFixture?.permissions ?? PermissionCenter(deviceTools: deviceToolPermissions)
        #else
        let permissionCenter = PermissionCenter(deviceTools: deviceToolPermissions)
        #endif
        if let identifier = defaults.string(forKey: "loopdy.native-device-tools.device-id"),
           UUID(uuidString: identifier) != nil {
            permissionCenter.nativeDeviceID = identifier
        } else {
            defaults.set(permissionCenter.nativeDeviceID, forKey: "loopdy.native-device-tools.device-id")
        }
        if !usesFixtures {
            permissionCenter.nativeDeviceToolHandler = { request, owner, isCurrent in
                await deviceToolCoordinator.handle(request, owner: owner, isCurrent: isCurrent)
            }
        }
        let permissionsOnboarding = PermissionsOnboardingModel(
            center: permissionCenter,
            completion: PermissionsOnboardingCompletion(defaults: defaults)
        )
        managedNotificationFactory = LoopdyManagedNotificationFactory(vault: linkVault, api: linkAPI,
            permissions: permissionCenter, isFixture: usesFixtures)
        let personalities = PersonalityStore(
            client: usesFixtures
                ? FixturePersonalityClient()
                : unavailable
        )
        #if DEBUG
        let clarificationFixture: ClarificationFallbackFixture? = usesFixtures
            && arguments.contains("-test-clarification-fallback")
            ? ClarificationFallbackFixture(
                expired: arguments.contains("-test-clarification-expired"),
                failNextSend: arguments.contains("-test-clarification-failure")
            ) : nil
        #endif
        let conversationClient: ((SessionRecord, AgentProfile?) -> any ConversationClient)? = usesFixtures
            ? { session, agent in
                #if DEBUG
                if let clarificationFixture { return clarificationFixture }
                if arguments.contains("-test-canvas-stream") || arguments.contains("-test-tool-stream") {
                    return CanvasStreamingFixtureClient(senderID: session.agentIDs.first ?? "default")
                }
                #endif
                let agentID = session.agentIDs.first ?? "default"
                #if DEBUG
                if session.id == "demo-finance", arguments.contains("-test-live-reasoning-card") {
                    return MidSessionConversationFixtureClient(
                        canonicalAgentID: agentID,
                        agentDisplayName: agent?.name ?? "Assistant",
                        agentAvatarFileName: agent?.avatarFileName
                    )
                }
                #endif
                if session.id == "demo-finance-mid-session" {
                    return MidSessionConversationFixtureClient(
                        canonicalAgentID: agentID,
                        agentDisplayName: agent?.name ?? "Assistant",
                        agentAvatarFileName: agent?.avatarFileName
                    )
                }
                return ConversationFixtureClient(
                    canonicalAgentID: agentID,
                    agentDisplayName: agent?.name ?? "Assistant",
                    agentAvatarFileName: agent?.avatarFileName
                )
            }
            : { _, _ in unavailable }
        var dashboardSource: any DashboardDataSource = usesFixtures
            ? DashboardFixtureSource(
                loopdyCards: usesCardGallery ? LoopdyCardDemoFixtures.documents : []
            )
            : unavailable
        var dashboardWeatherLoader: (any DashboardWeatherLoading)? = usesFixtures
            ? nil
            : AppleDashboardWeatherLoader()
        #if DEBUG
        if let clarificationFixture { dashboardSource = clarificationFixture }
        if let homeWorkFixture { dashboardSource = homeWorkFixture }
        if let homeWeatherFixture {
            dashboardSource = homeWeatherFixture
            dashboardWeatherLoader = homeWeatherFixture
        }
        #endif
        let watchApprovalBridge: LoopdyWatchApprovalBridge? = usesFixtures
            ? nil
            : LoopdyWatchApprovalBridge(loader: unavailableCatalog, client: unavailableCatalog)
        let featureStore = ShellFeatureStore(
            timing: timing,
            catalog: sessionCatalog,
            agents: agentDirectory,
            agentRuntimeDefaults: agentRuntimeDefaults,
            botModeRooms: botModeRooms,
            userIdentity: userIdentity,
            scheduledTasks: scheduledTasks,
            dashboardSource: dashboardSource,
            dashboardWeatherLoader: dashboardWeatherLoader,
            dashboardVerifiedConnectionGeneration: { usesFixtures ? 0 : nil },
            conversationClient: conversationClient,
            voiceClient: usesFixtures ? nil : { _, _ in unavailable },
            voiceInputLevelSource: usesFixtures
                ? { SilentVoiceInputLevelSource() }
                : { AVAudioEngineVoiceInputLevelSource() },
            sessionControlMessaging: usesFixtures
                ? DemoSessionControlMessaging(reasoning: arguments.contains("-test-session-reasoning-high")
                    ? ["demo-finance": "high"]
                    : [:])
                : nil,
            slashCommandCatalogClient: usesFixtures
                ? FixtureSlashCommandCatalogClient()
                : nil,
            generatedMediaResolver: nil,
            recentModelHistory: RecentModelHistoryStore(
                defaults: defaults,
                scopeID: { [weak linkAccount] in
                    if usesFixtures { return "demo-models" }
                    guard let credentials = linkAccount?.credentials,
                          let hostID = hostRepositoryScope.hostID else { return nil }
                    return "\(credentials.deviceID):\(hostID)"
                }
            ),
            midSessionBehavior: { settings.midSessionChatBehavior }
        )
        #if DEBUG
        if usesFixtures, arguments.contains("-test-live-voice") {
            featureStore.configureLiveVoiceFactory { session, agent, _ in
                let owner = LiveVoiceOwner(hostID: "fixture-host", authorizationID: "inert-ui-fixture",
                    agentID: session.agentIDs.first ?? "fixture-agent", sessionID: session.id)
                let control = LiveVoiceControlClient(owner: owner, operation: { _, _ in
                    // Never reaches the peer, microphone, network or provider.
                    throw LiveVoiceControlError.unavailable
                }, isOwnerCurrent: { $0 == owner })
                return LiveVoiceModel(agentName: agent?.name ?? "Loopdy", client: control,
                    makePeer: { LoopdyRealtimeAudioPeer(captureEnabled: false) })
            }
        }
        #endif
        // Keep the paired Watch service alive with explicitly unavailable chat
        // authority. The removed socket was always stopped, never a native path.
        watchApprovalBridge?.configure(
            featureStore: featureStore, sessionCatalog: sessionCatalog, agentDirectory: agentDirectory,
            authority: { [weak linkAccount] in
                WatchPhoneAuthority(scope: nil, link: linkAccount?.credentials == nil ? .signedOut : .unavailable)
            },
            reconnect: {}, voiceClient: nil
        )
        if usesOverflowStatusRailFixture {
            featureStore.acceptExternal(
                [
                    TimelineItem(
                        id: "fixture-status-rail-goal",
                        role: .human,
                        sender: .user(snapshot: .init(name: "You")),
                        content: .message("/goal Verify the overflowing session status rail"),
                        metadata: .init(delivery: "Delivered")
                    ),
                ],
                conversationID: "demo-finance"
            )
            featureStore.acceptSessionTodos(
                SessionTodoSnapshot(
                    sessionID: "demo-finance",
                    revision: 1,
                    todos: [
                        ChatTaskItem(
                            id: "fixture-status-rail-task",
                            content: "Verify horizontal overflow",
                            status: .inProgress
                        ),
                    ],
                    updatedAt: 1
                )
            )
            featureStore.acceptSessionSubagents(
                SessionSubagentRosterSnapshot(
                    sessionID: "demo-finance",
                    subagents: [
                        SessionSubagentSnapshot(
                            id: "fixture-status-rail-subagent",
                            sessionID: "fixture-status-rail-child",
                            parentID: "demo-finance",
                            role: "Verifier",
                            goal: "Exercise horizontal status rail scrolling",
                            startedAt: 1
                        ),
                    ],
                    updatedAt: 1
                )
            )
        }
        #if DEBUG
        if usesFixtures, arguments.contains("-test-v3-session-status") {
            featureStore.acceptSessionGoal(.init(sessionID: "demo-finance", storedSessionID: "demo-finance",
                status: .active, summary: "Finish the current plan", updatedAt: 1))
            featureStore.acceptSessionTodos(.init(sessionID: "demo-finance", revision: 1, todos: [
                .init(id: "review", content: "Review the current plan", status: .completed),
                .init(id: "refine", content: "Refine the controls", status: .inProgress),
                .init(id: "verify", content: "Verify the result", status: .pending),
                .init(id: "discard", content: "Discard the old layout", status: .cancelled)
            ], updatedAt: 1))
        }
        #endif
        #if DEBUG
        homeWorkFixture?.attach(catalog: sessionCatalog, featureStore: featureStore)
        #endif
        LoopdyProactiveNotificationOpenCenter.shared.install {
            [weak appState, weak featureStore] open in
            if let sessionID = open.sessionID, !sessionID.isEmpty {
                LoopdyExternalSessionOpenCenter.shared.request(catalogSessionID: sessionID)
                return
            }
            appState?.openInbox()
            await featureStore?.dashboardModel.openNotification(
                eventID: open.eventID,
                eventType: open.eventType
            )
        }
        #if DEBUG
        if usesFixtures, arguments.contains("-test-idle-replay") {
            IdleReplayAcceptanceFixture.start(features: featureStore, catalog: sessionCatalog)
        }
        #endif
        let subagentStreamAcceptanceFixture: SubagentStreamAcceptanceFixtureController?
        if usesFixtures,
           arguments.contains(SubagentStreamAcceptanceFixtureController.launchArgument) {
            let controller = SubagentStreamAcceptanceFixtureController(
                appState: appState,
                sessionCatalog: sessionCatalog,
                featureStore: featureStore
            )
            precondition(
                controller.installBeforePresentingParentRoute(),
                "The subagent stream acceptance fixture could not establish its production path."
            )
            subagentStreamAcceptanceFixture = controller
        } else {
            subagentStreamAcceptanceFixture = nil
        }
        if usesFixtures,
           subagentStreamAcceptanceFixture == nil,
           arguments.contains("-start-chat")
               || arguments.contains("-start-chat-mid-session")
               || arguments.contains("-start-long-transcript") {
            let conversationID: String
            if arguments.contains("-start-long-transcript") {
                conversationID = "demo-long-transcript"
            } else if arguments.contains("-start-chat-mid-session") {
                conversationID = "demo-finance-mid-session"
            } else if arguments.contains("-demo-collaboration") {
                conversationID = "demo-collaboration"
            } else {
                conversationID = "demo-finance"
            }
            let route = AppRoute.chat(conversationID: conversationID)
            if featureStore.prepare(route) {
                appState.activateConversation(id: conversationID, source: .newChat)
            }
        }

        self.appState = appState
        requiresLinkAccount = !usesFixtures
        self.settings = settings
        self.companion = companion
        self.userIdentity = userIdentity
        self.agentDirectory = agentDirectory
        self.agentRuntimeDefaults = agentRuntimeDefaults
        self.botModeRooms = botModeRooms
        self.linkAccount = linkAccount
        self.linkDevices = linkDevices
        self.permissionCenter = permissionCenter
        self.permissionsOnboarding = permissionsOnboarding
        self.sessionCatalog = sessionCatalog
        self.scheduledTasks = scheduledTasks
        self.personalities = personalities
        self.skillsAndTools = skillsAndTools
        self.hermesWorkspaces = hermesWorkspaces
        self.projectGitClient = projectGitClient
        self.optionalReferences = optionalReferences
        self.featureStore = featureStore
        self.subagentStreamAcceptanceFixture = subagentStreamAcceptanceFixture
        self.watchApprovalBridge = watchApprovalBridge
        let localCacheRefreshCoordinator = LoopdyLocalCacheRefreshCoordinator(
            invalidateStaleWork: {},
            clearCurrentHostCache: {
                featureStore.resetForAccountBoundary()
                cachedAgentRuntimeDefaults.resetForAccountBoundary()
                botModeRooms.configureNativeClient(nil)
                botModeRooms.resetForAccountBoundary()
                scheduledTasks.resetForAccountBoundary()
                personalities.resetForAccountBoundary()
                skillsAndTools.resetForAccountBoundary()
                hermesWorkspaces.resetForAccountBoundary()
                agentDirectory.resetForHostChange()
                sessionCatalog.resetForAccountBoundary()
                try sessionRepository.save([])
                try botModeRepository.save([])
            },
            refreshAuthoritativeState: {
                do {
                    try await agentDirectory.load()
                    try await sessionCatalog.load(requireAuthoritativeRefresh: true)
                    await scheduledTasks.load()
                    await personalities.load()
                    let agentID = agentDirectory.resolvedAgent(explicitID: nil)?.id ?? "default"
                    await skillsAndTools.load(agentID: agentID)
                    await hermesWorkspaces.load(agentID: agentID)
                    await featureStore.dashboardModel.load()
                    return true
                } catch {
                    return false
                }
            }
        )
        clearLocalCache = {
            await localCacheRefreshCoordinator.clearAndRefresh()
        }
        let clearAccountPresentation: @MainActor () -> Void = {
            [weak watchApprovalBridge, weak featureStore,
             weak cachedAgentRuntimeDefaults, weak botModeRooms, weak scheduledTasks,
             weak personalities, weak skillsAndTools, weak hermesWorkspaces,
             weak linkDevices, weak agentDirectory, weak userIdentity,
             weak sessionCatalog, weak appState, weak hostRepositoryScope,
             weak companion, weak optionalReferences] in
            optionalReferences?.invalidate()
            watchApprovalBridge?.clear()
            featureStore?.resetForAccountBoundary()
            cachedAgentRuntimeDefaults?.resetForAccountBoundary()
            botModeRooms?.configureNativeClient(nil)
            botModeRooms?.resetForAccountBoundary()
            scheduledTasks?.resetForAccountBoundary()
            personalities?.resetForAccountBoundary()
            skillsAndTools?.resetForAccountBoundary()
            hermesWorkspaces?.resetForAccountBoundary()
            linkDevices?.resetForAccountBoundary()
            agentDirectory?.resetForAccountBoundary()
            userIdentity?.resetForAccountBoundary()
            sessionCatalog?.resetForAccountBoundary()
            companion?.clearAgentOverrides()
            appState?.resetForAccountBoundary()
            hostRepositoryScope?.hostID = nil
        }
        linkAccount.onLocalAccountCleared = clearAccountPresentation
        // Device selection belongs only to optional account management/fixtures.
        // It must not retarget, reset or start native chat.
        hostSelectionChangeRelay.willChange = { hostID in
            guard usesFixtures, linkDevices.selectedHostID == hostID else { return }
            featureStore.resetForAccountBoundary()
            sessionCatalog.resetForAccountBoundary()
            appState.resetForHostBoundary()
            hostRepositoryScope.hostID = hostID
            agentDirectory.restoreCachedProfilesForHostSwitch((try? agentRepository.load()) ?? [])
            sessionCatalog.restoreRepositoryCacheForHostSwitch()
        }
        let newChatCoordinator = NewChatCoordinator(
            appState: appState,
            agents: agentDirectory,
            catalog: sessionCatalog,
            hermesWorkspaces: hermesWorkspaces,
            prepare: { route in featureStore.prepareNewChat(route) }
        )
        self.newChatCoordinator = newChatCoordinator
        shortcutService = LoopdyShortcutService(
            appState: appState,
            agents: agentDirectory,
            runtimeDefaults: agentRuntimeDefaults,
            catalog: sessionCatalog,
            featureStore: featureStore,
            newChatCoordinator: newChatCoordinator,
            prepareConnection: {
                guard usesFixtures else { throw LoopdyShortcutServiceError.connectionUnavailable }
            }
        )
        Task { await linkAccount.resumePendingAccountDeletion() }
    }

    static func initialAgentProfiles(
        usesFixtures: Bool,
        cachedAgentProfiles: [AgentProfile]
    ) -> [AgentProfile] {
        guard !usesFixtures else { return DemoAgentDirectoryClient.fixtureProfiles }
        let canonicalProfiles = cachedAgentProfiles.filter { $0 != .loopdyLinkDefault }
        return canonicalProfiles
    }

    static func loadInitialAgentProfiles(
        usesFixtures: Bool,
        repository: DemoRepository<[AgentProfile]>
    ) -> [AgentProfile] {
        initialAgentProfiles(
            usesFixtures: usesFixtures,
            cachedAgentProfiles: (try? repository.load()) ?? []
        )
    }
}

enum LoopdyApplicationDataDirectories {
    static func active(
        fixtures: Bool,
        applicationSupport: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0],
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> URL {
        if fixtures {
            return applicationSupport.appending(
                path: "LoopdyDemo-\(processIdentifier)",
                directoryHint: .isDirectory
            )
        }
        return applicationSupport.appending(
            path: "Loopdy",
            directoryHint: .isDirectory
        )
    }

    static func legacySocketDirectories(
        fixtures: Bool,
        applicationSupport: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
    ) -> [URL] {
        guard !fixtures else { return [] }
        return [
            applicationSupport.appending(
                path: "LoopdyDemo",
                directoryHint: .isDirectory
            )
        ]
    }
}
