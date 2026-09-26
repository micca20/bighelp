import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Loopdy

@MainActor
struct SettingsStoreTests {
    @Test func everyStoredLegacyInterfaceUsesV3WithoutChangingThemeBytes() throws {
        for version in ["v1", "v2", "v3", "future-version"] {
            let name = "ui-release-migration-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(version, forKey: "loopdy.appearance.interface-version")
            defaults.set(false, forKey: "loopdy.appearance.ui-v2-enabled")
            let previous = SettingsStore(defaults: defaults)
            let custom = try makeCustomTheme(id: "00000000-0000-0000-0000-000000000180", name: "My existing theme")
            try previous.saveCustomTheme(custom)
            previous.themeID = custom.themeID
            previous.appearance = .dark
            defaults.set(version, forKey: "loopdy.appearance.interface-version")
            let before = defaults.dictionaryRepresentation().filter { $0.key.contains("appearance") && !$0.key.contains("interface") && !$0.key.contains("ui-v2") }
            let settings = SettingsStore(defaults: defaults)
            #expect(settings.interfaceVersion == .v3)
            #expect(settings.uiV2Enabled)
            #expect(settings.themeID == custom.themeID)
            #expect(settings.selectedCustomTheme == custom)
            #expect(settings.appearance == .dark)
            let after = defaults.dictionaryRepresentation().filter { $0.key.contains("appearance") && !$0.key.contains("interface") && !$0.key.contains("ui-v2") }
            #expect(NSDictionary(dictionary: before).isEqual(to: after))
        }
    }

    @Test func invalidInterfaceVersionWithoutLegacyChoiceUsesV3() {
        let name = "ui-invalid-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("future-version", forKey: "loopdy.appearance.interface-version")
        #expect(SettingsStore(defaults: defaults).interfaceVersion == .v3)
    }

    @Test func explicitLegacyV1ChoiceMigratesToV3() {
        let name = "ui-legacy-v1-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "loopdy.appearance.ui-v2-enabled")
        #expect(SettingsStore(defaults: defaults).interfaceVersion == .v3)
    }

    @Test func appCompositionUsesV3WithoutAnInterfaceOverride() {
        let name = "ui-composition-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let composition = LoopdyAppComposition(arguments: ["Loopdy", "-use-demo-fixtures"], defaults: defaults)
        #expect(composition.settings.interfaceVersion == .v3)
        #expect(composition.settings.uiV2Enabled)
        #expect(defaults.object(forKey: "loopdy.appearance.interface-version") == nil)
        #expect(defaults.object(forKey: "loopdy.appearance.ui-v2-enabled") == nil)
    }

    @Test func storedV3SelectionEnablesModernPresentation() {
        let name = "ui-v3-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("v3", forKey: "loopdy.appearance.interface-version")
        #expect(SettingsStore(defaults: defaults).uiV2Enabled)
    }

    @Test func interfaceVersionsPersistAndMigrateWithoutChangingTheme() {
        let name = "ui-versions-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(SettingsStore(defaults: defaults).interfaceVersion == .v3)
        defaults.set(true, forKey: "loopdy.appearance.ui-v2-enabled")
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.interfaceVersion == .v3)
        let appearance = settings.appearanceContext
        for version in LoopdyInterfaceVersion.allCases {
            settings.interfaceVersion = version
            let restored = SettingsStore(defaults: defaults)
            #expect(restored.interfaceVersion == .v3)
            #expect(restored.uiV2Enabled)
            #expect(restored.appearanceContext == appearance)
        }
        settings.uiV2Enabled = false
        #expect(settings.interfaceVersion == .v3)
        settings.uiV2Enabled = true
        #expect(settings.interfaceVersion == .v3)
    }

    @Test func invalidInterfaceVersionWithLegacyPreferenceUsesV3() {
        let name = "ui-invalid-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("future-version", forKey: "loopdy.appearance.interface-version")
        defaults.set(true, forKey: "loopdy.appearance.ui-v2-enabled")
        #expect(SettingsStore(defaults: defaults).interfaceVersion == .v3)
    }

    @Test func modernUIStaysEnabledAfterLegacySetters() {
        let name = "ui-v2-opt-in-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let original = SettingsStore(defaults: defaults)
        #expect(original.interfaceVersion == .v3)
        #expect(original.uiV2Enabled)
        original.uiV2Enabled = true
        #expect(SettingsStore(defaults: defaults).uiV2Enabled)
        original.uiV2Enabled = false
        #expect(SettingsStore(defaults: defaults).uiV2Enabled)
    }

    @Test func changingUIVersionPreservesThemeAndPreparedChatIdentity() {
        let name = "ui-v2-route-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let composition = LoopdyAppComposition(arguments: ["Loopdy", "-disable-demo-delays"], defaults: defaults)
        let route = AppRoute.chat(conversationID: "demo-finance")
        #expect(composition.featureStore.prepare(route))
        guard case .chat(let original) = composition.featureStore.preparedModel(for: route) else {
            Issue.record("Expected prepared chat"); return
        }
        let appearance = composition.settings.appearanceContext
        original.draft = "Keep this draft across interface changes."
        for version in LoopdyInterfaceVersion.allCases {
            composition.settings.interfaceVersion = version
            guard case .chat(let current) = composition.featureStore.preparedModel(for: route) else {
                Issue.record("Interface switch discarded the active chat"); return
            }
            #expect(original === current)
            #expect(current.draft == "Keep this draft across interface changes.")
            #expect(composition.settings.appearanceContext == appearance)
        }
    }
    @Test func accountBoundaryClearsEveryInMemoryAccountScopedWorkspaceStore() async {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let composition = LoopdyAppComposition(
            arguments: ["Loopdy", "-disable-demo-delays"],
            defaults: defaults,
            credentialVault: LoopdyLinkMemoryCredentialVault()
        )
        let route = AppRoute.chat(conversationID: "demo-finance")
        composition.userIdentity.identity = UserIdentity(
            name: "Previous account",
            avatarFileName: "private-avatar.jpg"
        )
        composition.agentDirectory.select("avery")
        #expect(composition.featureStore.prepare(route))
        composition.appState.activateConversation(id: "demo-finance", source: .quickSwitch)

        composition.linkAccount.onLocalAccountCleared()

        #expect(!composition.requiresLinkAccount)
        #expect(composition.appState.path.isEmpty)
        #expect(composition.agentDirectory.profiles.isEmpty)
        #expect(composition.agentDirectory.selectedAgentID == nil)
        #expect(composition.sessionCatalog.records.isEmpty)
        #expect(composition.botModeRooms.rooms.isEmpty)
        #expect(composition.scheduledTasks.tasks.isEmpty)
        #expect(composition.personalities.catalog == nil)
        #expect(composition.linkDevices.devices.isEmpty)
        #expect(composition.userIdentity.identity == UserIdentity(name: "You", avatarFileName: nil))
        #expect(composition.featureStore.preparedModel(for: route) == nil)
    }

    @Test func appCompositionDeclaresDirectFirstConnectivity() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let composition = LoopdyAppComposition(
            arguments: ["Loopdy", "-disable-demo-delays"],
            defaults: defaults
        )

        #expect(composition.workspaceConnectivity == .nativeOnly)
    }

    @Test func forcedSignedOutOnboardingDoesNotDeleteTheSharedCredentialVault() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let vault = LoopdyLinkMemoryCredentialVault()
        let credentials = LoopdyLinkRuntimeCredentials(
            deviceID: "live-smoke-device",
            authorizationEpoch: 1,
            signingPrivateKey: P256.Signing.PrivateKey(),
            accountKey: Data(repeating: 0x5A, count: 32)
        )
        try vault.save(credentials)

        _ = LoopdyAppComposition(
            arguments: ["Loopdy", "-use-demo-fixtures", "-force-signed-out-onboarding"],
            defaults: defaults,
            credentialVault: vault
        )

        #expect(try vault.load() == credentials)
    }

    @Test func appCompositionAppearanceChangePreservesPreparedRouteIdentity() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let composition = LoopdyAppComposition(
            arguments: ["Loopdy", "-disable-demo-delays"],
            defaults: defaults
        )
        let route = AppRoute.chat(conversationID: "demo-finance")
        #expect(composition.featureStore.prepare(route))
        composition.appState.activateConversation(id: "demo-finance", source: .quickSwitch)
        guard case .chat(let chat) = composition.featureStore.preparedModel(for: route) else {
            Issue.record("Composition did not prepare its Chat route")
            return
        }
        let featureStore = composition.featureStore
        let path = composition.appState.path
        let itemIDs = chat.items.map(\.id)

        composition.settings.appearance = .dark

        #expect(composition.featureStore === featureStore)
        guard case .chat(let retainedChat) = composition.featureStore.preparedModel(for: route) else {
            Issue.record("Appearance change discarded the prepared Chat route")
            return
        }
        #expect(retainedChat === chat)
        #expect(retainedChat.items.map(\.id) == itemIDs)
        #expect(composition.appState.path == path)
    }

    @Test func appCompositionThemeChangeDoesNotRestartAccountOrWorkspaceState() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let composition = LoopdyAppComposition(
            arguments: ["Loopdy", "-use-demo-fixtures"],
            defaults: defaults
        )
        let route = AppRoute.chat(conversationID: "demo-finance")
        #expect(composition.featureStore.prepare(route))
        composition.appState.activateConversation(id: "demo-finance", source: .quickSwitch)
        let account = composition.linkAccount
        let devices = composition.linkDevices
        let featureStore = composition.featureStore
        let accountState = account.state
        let path = composition.appState.path

        composition.settings.themeID = .nous

        #expect(composition.linkAccount === account)
        #expect(composition.linkDevices === devices)
        #expect(composition.featureStore === featureStore)
        #expect(composition.linkAccount.state == accountState)
        #expect(composition.appState.path == path)
    }

    @Test func voiceModeDefaultsToPressToTalkAndPersistsWalkieTalkie() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = SettingsStore(defaults: defaults)
        #expect(initial.voiceMode == .pressToTalk)
        initial.voiceMode = .walkieTalkie

        let restored = SettingsStore(defaults: defaults)
        #expect(restored.voiceMode == .walkieTalkie)
    }

    @Test func appearancePersistsWithoutResettingRouteOrChatItemIdentities() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        let app = AppState()
        app.activateConversation(id: "demo-finance", source: .quickSwitch)
        let chat = ChatModel(
            conversationID: "demo-finance",
            client: ConversationFixtureClient()
        )
        let path = app.path
        let itemIDs = chat.items.map(\.id)

        settings.appearance = .dark

        let restored = SettingsStore(defaults: defaults)
        #expect(restored.appearance == .dark)
        #expect(app.path == path)
        #expect(chat.items.map(\.id) == itemIDs)
    }

    @Test func representativePreferencesPersistThroughInjectedDefaults() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        settings.autoSuggestionsEnabled = false
        settings.messageActionsEnabled = false
        settings.inlineUIEnabled = false
        settings.voiceSpeed = .fast
        settings.offlineModeEnabled = true
        settings.notificationsEnabled = false
        settings.showReasoningByDefault = true
        settings.showToolCallsByDefault = false
        settings.reflectiveVisionEnabled = true
        settings.themeID = .superpilot
        settings.leftEdgeSwipeAction = .sessions
        settings.rightEdgeSwipeAction = .newChat
        settings.preferredBrowser = .firefox
        settings.midSessionChatBehavior = .queued
        settings.showProjectChanges = false

        let restored = SettingsStore(defaults: defaults)
        #expect(!restored.autoSuggestionsEnabled)
        #expect(!restored.messageActionsEnabled)
        #expect(!restored.inlineUIEnabled)
        #expect(restored.voiceSpeed == .fast)
        #expect(restored.offlineModeEnabled)
        #expect(!restored.notificationsEnabled)
        #expect(restored.showReasoningByDefault)
        #expect(!restored.showToolCallsByDefault)
        #expect(restored.reflectiveVisionEnabled)
        #expect(restored.themeID == .superpilot)
        #expect(restored.leftEdgeSwipeAction == .sessions)
        #expect(restored.rightEdgeSwipeAction == .newChat)
        #expect(restored.preferredBrowser == .firefox)
        #expect(restored.midSessionChatBehavior == .queued)
        #expect(!restored.showProjectChanges)
    }

    @Test func projectChangesRailIsEnabledByDefault() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SettingsStore(defaults: defaults).showProjectChanges)
    }

    @Test func organizeChatsByProjectsIsOffByDefaultAndPersistsWhenEnabled() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        #expect(!settings.organizeChatsByProjects)

        settings.organizeChatsByProjects = true

        #expect(SettingsStore(defaults: defaults).organizeChatsByProjects)
    }

    @Test func midSessionChatBehaviorDefaultsToInterruptAndOffersEveryHermesMode() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.midSessionChatBehavior == .interruptAndSend)
        #expect(MidSessionChatBehavior.allCases == [
            .steer,
            .queued,
            .interruptAndSend,
        ])
        #expect(MidSessionChatBehavior.allCases.map(\.title) == [
            "Steer",
            "Queued",
            "Interrupt and Send",
        ])
    }

    @Test func chatLinksUseTheSystemDefaultBrowserUntilTheUserSavesAChoice() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.preferredBrowser == .systemDefault)
    }

    @Test func browserListContainsOnlySystemDefaultAndSupportedInstalledBrowsers() {
        let available = ChatBrowserPreference.available { probeURL in
            ["googlechrome", "brave"].contains(probeURL.scheme)
        }

        #expect(available == [.systemDefault, .chrome, .brave])
    }

    @Test func browserRoutesPreserveTheOriginalWebDestination() throws {
        let original = try #require(URL(
            string: "https://loopdy.app/docs?q=link%20routing#settings"
        ))

        let chrome = try #require(ChatBrowserPreference.chrome.targetURL(for: original))
        #expect(chrome.scheme == "googlechromes")
        #expect(chrome.host == "loopdy.app")
        #expect(chrome.path == "/docs")
        #expect(chrome.query == "q=link%20routing")
        #expect(chrome.fragment == "settings")

        for browser in [ChatBrowserPreference.firefox, .brave] {
            let target = try #require(browser.targetURL(for: original))
            let components = try #require(URLComponents(
                url: target,
                resolvingAgainstBaseURL: false
            ))
            #expect(components.host == "open-url")
            #expect(components.queryItems == [
                URLQueryItem(name: "url", value: original.absoluteString)
            ])
        }

        #expect(ChatBrowserPreference.systemDefault.targetURL(for: original) == original)
        #expect(ChatBrowserPreference.chrome.targetURL(
            for: try #require(URL(string: "mailto:hello@loopdy.app"))
        ) == nil)
    }

    @Test func chatActivityVisibilityDefaultsPersistAndNewSessionsInheritThem() async throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        settings.showReasoningByDefault = true
        settings.showToolCallsByDefault = false
        let client = DemoSessionCatalogClient(records: [])
        let catalog = SessionCatalogStore(
            client: client,
            defaultActivityVisibility: { settings.chatActivityVisibility }
        )

        let created = try await catalog.createDirect(agentID: "default")

        #expect(created.activityVisibility == .init(
            showReasoning: true,
            showToolCalls: false
        ))
        #expect(catalog.session(id: created.id)?.activityVisibility == created.activityVisibility)
    }

    @Test func settingsMenuUsesFocusedSubsectionsInsteadOfOneLongForm() {
        #expect(SettingsMenuSection.allCases == [
            .accountAndDevices,
            .appearance,
            .workspace,
            .agentsAndPersonalities,
            .chat,
            .notifications,
            .permissions,
            .connectivityAndNotifications,
        ])
        #expect(Set(SettingsMenuSection.allCases.map(\.title)).count == 8)
    }

    @Test func currentEdgeGestureChoicesExcludeTheLegacyInboxDestination() {
        #expect(!WorkspaceSwipeAction.allCases.contains(.inbox))
    }

    @Test func persistedLegacyInboxEdgeGesturesMigrateToVisibleHomeRouting() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("inbox", forKey: "loopdy.workspace.leftEdgeSwipeAction")
        defaults.set("inbox", forKey: "loopdy.workspace.rightEdgeSwipeAction")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.leftEdgeSwipeAction.title == "Home")
        #expect(settings.rightEdgeSwipeAction.title == "Home")
        #expect(defaults.string(forKey: "loopdy.workspace.leftEdgeSwipeAction") == "home")
        #expect(defaults.string(forKey: "loopdy.workspace.rightEdgeSwipeAction") == "home")
    }

    @Test func reflectiveVisionIsOptInAndDoesNotChangeThemePreferences() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        settings.themeID = .nous
        settings.appearance = .dark

        #expect(!settings.reflectiveVisionEnabled)

        settings.reflectiveVisionEnabled = true
        let restored = SettingsStore(defaults: defaults)

        #expect(restored.reflectiveVisionEnabled)
        #expect(restored.themeID == .nous)
        #expect(restored.appearance == .dark)
    }

    @Test func reflectiveVisionMaterialRequiresOptInAnActiveCameraAndTransparency() {
        #expect(!ReflectiveVisionPresentationResolver.shouldRenderCamera(
            enabled: false,
            cameraIsActive: true,
            reduceTransparency: false
        ))
        #expect(!ReflectiveVisionPresentationResolver.shouldRenderCamera(
            enabled: true,
            cameraIsActive: false,
            reduceTransparency: false
        ))
        #expect(!ReflectiveVisionPresentationResolver.shouldRenderCamera(
            enabled: true,
            cameraIsActive: true,
            reduceTransparency: true
        ))
        #expect(ReflectiveVisionPresentationResolver.shouldRenderCamera(
            enabled: true,
            cameraIsActive: true,
            reduceTransparency: false
        ))
    }

    @Test func reflectiveVisionCoalescesRepeatedActivationRequestsAndAllowsFreshRelaunch() {
        var policy = ReflectiveVisionActivationPolicy()

        let firstActivation = policy.shouldReconcile(enabled: true, state: .off)
        #expect(firstActivation)
        let duplicateWhilePreparing = policy.shouldReconcile(enabled: true, state: .preparing)
        #expect(!duplicateWhilePreparing)
        let duplicateWhileActive = policy.shouldReconcile(enabled: true, state: .active)
        #expect(!duplicateWhileActive)
        let duplicateAfterFailure = policy.shouldReconcile(
            enabled: true,
            state: .unavailable(.permissionDenied)
        )
        #expect(!duplicateAfterFailure)
        let deactivation = policy.shouldReconcile(enabled: false, state: .active)
        #expect(deactivation)

        var relaunchedPolicy = ReflectiveVisionActivationPolicy()
        let relaunchedActivation = relaunchedPolicy.shouldReconcile(enabled: true, state: .off)
        #expect(relaunchedActivation)
    }

    @Test func reflectiveVisionRequestsCameraOnlyFromAnExplicitSettingAction() {
        #expect(!ReflectiveVisionPermissionPolicy.shouldRequest(
            enabled: true,
            authorization: .notDetermined,
            trigger: .lifecycle
        ))
        #expect(ReflectiveVisionPermissionPolicy.shouldRequest(
            enabled: true,
            authorization: .notDetermined,
            trigger: .explicitUserAction
        ))
        #expect(!ReflectiveVisionPermissionPolicy.shouldRequest(
            enabled: true,
            authorization: .authorized,
            trigger: .explicitUserAction
        ))
    }

    @Test func reflectiveVisionUnfinishedActivationDisablesOptInOnNextLaunch() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let marker = ReflectiveVisionRecoveryMarker(defaults: defaults)
        marker.markActivationStarted()
        defaults.set(true, forKey: "loopdy.appearance.reflectiveVision")

        let relaunchedSettings = SettingsStore(defaults: defaults)

        #expect(!relaunchedSettings.reflectiveVisionEnabled)
        #expect(!defaults.bool(forKey: "loopdy.appearance.reflectiveVision"))
        #expect(!marker.hasPendingActivation)
    }

    @Test func reflectiveVisionStableActivationClearsRecoveryMarker() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let marker = ReflectiveVisionRecoveryMarker(defaults: defaults)
        marker.markActivationStarted()
        #expect(marker.hasPendingActivation)

        marker.markActivationStabilized()

        #expect(!marker.hasPendingActivation)
    }

    @Test func reflectiveVisionUsesOneLowRateSharedFrameOutput() {
        #expect(ReflectiveVisionCaptureArchitecture.usesSingleOutput)
        #expect(ReflectiveVisionCaptureArchitecture.maximumFramesPerSecond == 6)
        #expect(ReflectiveVisionCaptureArchitecture.maximumFrameDimension <= 720)

        let store = ReflectiveVisionFrameStore()
        store.publish(Data([1]))
        let first = store.latest(after: 0)
        #expect(first?.data == Data([1]))

        store.publish(Data([2]))
        let latest = store.latest(after: first?.sequence ?? 0)
        #expect(latest?.data == Data([2]))
    }

    @Test func reflectiveVisionRecoveryWaitsForStableActiveRenderingBeforeClearing() {
        let activation = ReflectiveVisionActivationStability(generation: 7, startedAt: 10)

        #expect(!activation.canClearRecoveryMarker(
            at: 11.99,
            currentGeneration: 7,
            state: .active
        ))
        #expect(!activation.canClearRecoveryMarker(
            at: 12,
            currentGeneration: 8,
            state: .active
        ))
        #expect(!activation.canClearRecoveryMarker(
            at: 12,
            currentGeneration: 7,
            state: .preparing
        ))
        #expect(activation.canClearRecoveryMarker(
            at: 12,
            currentGeneration: 7,
            state: .active
        ))
    }

    @Test func edgeSwipeDefaultsAreUsefulWithoutSurprisingTheUser() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.leftEdgeSwipeAction == .sessions)
        #expect(settings.rightEdgeSwipeAction == .newChat)
    }

    @Test func explicitlySavedEdgeSwipeChoicesAreNeverReplacedByNewDefaults() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(WorkspaceSwipeAction.none.rawValue, forKey: "loopdy.workspace.leftEdgeSwipeAction")
        defaults.set(WorkspaceSwipeAction.quickWorkspace.rawValue, forKey: "loopdy.workspace.rightEdgeSwipeAction")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.leftEdgeSwipeAction == .none)
        #expect(settings.rightEdgeSwipeAction == .quickWorkspace)
        #expect(defaults.string(forKey: "loopdy.workspace.leftEdgeSwipeAction") == "none")
        #expect(defaults.string(forKey: "loopdy.workspace.rightEdgeSwipeAction") == "quickWorkspace")
    }

    @Test func invalidStoredEnumValuesFallBackSafely() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("infrared", forKey: "loopdy.demo.appearance")
        defaults.set("warp", forKey: "loopdy.demo.voiceSpeed")
        defaults.set("teleport", forKey: "loopdy.workspace.leftEdgeSwipeAction")
        defaults.set("obliterate", forKey: "loopdy.workspace.rightEdgeSwipeAction")
        defaults.set("missing-theme", forKey: "loopdy.appearance.theme")

        let settings = SettingsStore(defaults: defaults)

        #expect(settings.appearance == .system)
        #expect(settings.voiceSpeed == .normal)
        #expect(settings.leftEdgeSwipeAction == .sessions)
        #expect(settings.rightEdgeSwipeAction == .newChat)
        #expect(settings.themeID == .loopdy)
    }

    @Test func settingsStoreKeepsGrowingCustomThemeCardsBeyondThree() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let themes = try [
            makeCustomTheme(id: "00000000-0000-0000-0000-000000000001", name: "One"),
            makeCustomTheme(id: "00000000-0000-0000-0000-000000000002", name: "Two"),
            makeCustomTheme(id: "00000000-0000-0000-0000-000000000003", name: "Three"),
            makeCustomTheme(id: "00000000-0000-0000-0000-000000000004", name: "Four"),
        ]

        #expect(try settings.saveCustomTheme(themes[0]) == .created)
        #expect(try settings.saveCustomTheme(themes[1]) == .created)
        #expect(try settings.saveCustomTheme(themes[2]) == .created)
        #expect(try settings.saveCustomTheme(themes[3]) == .created)
        #expect(settings.customThemes == themes)
        #expect(settings.availableCustomThemeSlots == SettingsStore.maximumCustomThemes - 4)
        #expect(LoopdyThemeRegistry.builtIns.count == 3)
    }

    @Test func duplicatingCustomThemeCreatesIndependentCardWithSameDesign() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let original = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000005",
            name: "Original"
        )
        try settings.saveCustomTheme(original)

        let duplicate = try settings.duplicateCustomTheme(id: original.id)

        #expect(duplicate.id != original.id)
        #expect(duplicate.name == "Original Copy")
        #expect(duplicate.font == original.font)
        #expect(duplicate.accentHex == original.accentHex)
        #expect(duplicate.light == original.light)
        #expect(duplicate.dark == original.dark)
        #expect(settings.customThemes == [original, duplicate])
    }

    @Test func updatingAnExistingCustomThemeDoesNotConsumeAnotherSlot() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let id = "00000000-0000-0000-0000-000000000011"
        let original = try makeCustomTheme(id: id, name: "Original")
        let updated = try makeCustomTheme(id: id, name: "Updated")

        #expect(try settings.saveCustomTheme(original) == .created)
        #expect(try settings.saveCustomTheme(updated) == .updated)
        #expect(settings.customThemes == [updated])
        #expect(settings.availableCustomThemeSlots == SettingsStore.maximumCustomThemes - 1)
    }

    @Test func importingCustomThemesAppendsToTheExistingCatalog() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let existing = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000012",
            name: "Existing"
        )
        let imported = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000013",
            name: "Imported"
        )
        try settings.saveCustomTheme(existing)

        try settings.importCustomThemes([imported])

        #expect(settings.customThemes == [existing, imported])
        #expect(SettingsStore(defaults: defaults).customThemes == [existing, imported])
    }

    @Test func importingAnExistingThemeIDUpdatesItWithoutReplacingOtherThemes() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let existing = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000014",
            name: "Existing"
        )
        let retained = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000015",
            name: "Retained"
        )
        let updated = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000014",
            name: "Updated"
        )
        try settings.saveCustomTheme(existing)
        try settings.saveCustomTheme(retained)

        try settings.importCustomThemes([updated])

        #expect(settings.customThemes == [updated, retained])
    }

    @Test func customThemesAndTheSelectedCustomIDPersistThroughInjectedDefaults() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let theme = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000021",
            name: "Persistent"
        )
        let settings = SettingsStore(defaults: defaults)

        try settings.saveCustomTheme(theme)
        settings.themeID = theme.themeID

        let restored = SettingsStore(defaults: defaults)
        #expect(restored.customThemes == [theme])
        #expect(restored.themeID == theme.themeID)
        #expect(restored.selectedCustomTheme == theme)
        #expect(restored.customThemePersistenceError == nil)
    }

    @Test func selectedCustomThemeBuildsAppWideAppearanceContext() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let custom = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000024",
            name: "App wide"
        )
        let settings = SettingsStore(defaults: defaults)
        try settings.saveCustomTheme(custom)
        settings.themeID = custom.themeID
        settings.appearance = .dark

        let context = settings.appearanceContext

        #expect(context.appearance == .dark)
        #expect(context.themeID == custom.themeID)
        #expect(context.customTheme == custom)
        #expect(context.customLogoURL == nil)
        let resolved = LoopdyTheme.resolve(
            appearance: context,
            colorScheme: .light,
            contrast: .standard
        )
        #expect(resolved.themeID == custom.themeID)
        #expect(resolved.typeface == .system)
        #expect(resolved.typography == .loopdy)
        #expect(resolved.action != LoopdyTheme.resolve(
            themeID: .loopdy,
            appearance: .dark,
            colorScheme: .light,
            contrast: .standard
        ).action)
    }

    @Test func customLogoIsValidatedAndCopiedIntoOwnedStorage() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let root = FileManager.default.temporaryDirectory
            .appending(path: suiteName, directoryHint: .isDirectory)
        let ownedDirectory = root.appending(path: "owned", directoryHint: .isDirectory)
        let externalURL = root.appending(path: "chosen-logo.png")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let logoData = makeLogoPNG(width: 96, height: 64)
        try logoData.write(to: externalURL)
        let custom = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000025",
            name: "Logo storage"
        )
        let settings = SettingsStore(
            defaults: defaults,
            customThemeLogoDirectory: ownedDirectory
        )
        try settings.saveCustomTheme(custom)
        settings.themeID = custom.themeID

        let logo = try settings.setCustomThemeLogo(data: logoData, for: custom.id)
        let ownedURL = try #require(settings.customLogoURL(for: custom.id))

        #expect(logo.pixelWidth == 96)
        #expect(logo.pixelHeight == 64)
        #expect(logo.byteCount == logoData.count)
        #expect(ownedURL.deletingLastPathComponent().standardizedFileURL == ownedDirectory.standardizedFileURL)
        #expect(ownedURL != externalURL)
        #expect(try Data(contentsOf: ownedURL) == logoData)
        #expect(settings.selectedCustomTheme?.logo == logo)
        #expect(settings.appearanceContext.customLogoURL == ownedURL)
    }

    @Test func customThemeStoresIndependentLightAndDarkLogos() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let root = FileManager.default.temporaryDirectory
            .appending(path: suiteName, directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let custom = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000029",
            name: "Dual logos"
        )
        let settings = SettingsStore(defaults: defaults, customThemeLogoDirectory: root)
        try settings.saveCustomTheme(custom)
        settings.themeID = custom.themeID

        let light = try settings.setCustomThemeLogo(
            data: makeLogoPNG(width: 80, height: 50),
            for: custom.id,
            variant: .light
        )
        let dark = try settings.setCustomThemeLogo(
            data: makeLogoPNG(width: 120, height: 72),
            for: custom.id,
            variant: .dark
        )

        #expect(settings.selectedCustomTheme?.lightLogo == light)
        #expect(settings.selectedCustomTheme?.darkLogo == dark)
        #expect(settings.appearanceContext.customLightLogoURL != nil)
        #expect(settings.appearanceContext.customDarkLogoURL != nil)
        #expect(settings.appearanceContext.customLightLogoURL != settings.appearanceContext.customDarkLogoURL)
    }

    @Test func replacingCustomLogoRemovesTheOldOwnedAsset() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let root = FileManager.default.temporaryDirectory
            .appending(path: suiteName, directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let custom = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000026",
            name: "Logo replacement"
        )
        let settings = SettingsStore(defaults: defaults, customThemeLogoDirectory: root)
        try settings.saveCustomTheme(custom)

        _ = try settings.setCustomThemeLogo(
            data: makeLogoPNG(width: 80, height: 50),
            for: custom.id
        )
        let oldURL = try #require(settings.customLogoURL(for: custom.id))
        _ = try settings.setCustomThemeLogo(
            data: makeLogoPNG(width: 120, height: 72),
            for: custom.id
        )
        let replacementURL = try #require(settings.customLogoURL(for: custom.id))

        #expect(oldURL != replacementURL)
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: replacementURL.path))
    }

    @Test func removingCustomLogoClearsMetadataAndOwnedAsset() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let root = FileManager.default.temporaryDirectory
            .appending(path: suiteName, directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let custom = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000027",
            name: "Logo removal"
        )
        let settings = SettingsStore(defaults: defaults, customThemeLogoDirectory: root)
        try settings.saveCustomTheme(custom)
        settings.themeID = custom.themeID
        _ = try settings.setCustomThemeLogo(
            data: makeLogoPNG(width: 80, height: 50),
            for: custom.id
        )
        let ownedURL = try #require(settings.customLogoURL(for: custom.id))

        try settings.removeCustomThemeLogo(for: custom.id)

        #expect(settings.selectedCustomTheme?.logo == nil)
        #expect(settings.customLogoURL(for: custom.id) == nil)
        #expect(settings.appearanceContext.customLogoURL == nil)
        #expect(!FileManager.default.fileExists(atPath: ownedURL.path))
    }

    @Test func deletingCustomThemeRemovesItsOwnedLogoAndRestoresBuiltInSelection() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let root = FileManager.default.temporaryDirectory
            .appending(path: suiteName, directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let custom = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000028",
            name: "Logo deletion"
        )
        let settings = SettingsStore(defaults: defaults, customThemeLogoDirectory: root)
        try settings.saveCustomTheme(custom)
        settings.themeID = custom.themeID
        _ = try settings.setCustomThemeLogo(
            data: makeLogoPNG(width: 80, height: 50),
            for: custom.id
        )
        let ownedURL = try #require(settings.customLogoURL(for: custom.id))

        try settings.deleteCustomTheme(id: custom.id)

        #expect(settings.customThemes.isEmpty)
        #expect(settings.themeID == .loopdy)
        #expect(!FileManager.default.fileExists(atPath: ownedURL.path))
    }

    @Test func legacyCustomThemeCatalogMigratesToTheCurrentVersion() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let theme = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000022",
            name: "Migrated"
        )
        let items = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode([theme])
        )
        let legacy = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 0,
            "items": items,
        ])
        defaults.set(legacy, forKey: "loopdy.appearance.customThemes")

        let restored = SettingsStore(defaults: defaults)

        #expect(restored.customThemes == [theme])
        #expect(restored.customThemePersistenceError == nil)
        let migratedData = try #require(
            defaults.data(forKey: "loopdy.appearance.customThemes")
        )
        let migratedObject = try #require(
            JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
        )
        #expect(migratedObject["schemaVersion"] as? Int == 1)
        #expect(migratedObject["themes"] != nil)
    }

    @Test func malformedAndFutureThemeCatalogsFailSafelyWithoutBeingOverwritten() throws {
        let malformedSuite = "\(#function).malformed"
        let malformedDefaults = UserDefaults(suiteName: malformedSuite)!
        malformedDefaults.removePersistentDomain(forName: malformedSuite)
        defer { malformedDefaults.removePersistentDomain(forName: malformedSuite) }
        let malformed = Data("{ definitely-not-json".utf8)
        malformedDefaults.set(malformed, forKey: "loopdy.appearance.customThemes")
        malformedDefaults.set(
            "custom.00000000-0000-0000-0000-000000000099",
            forKey: "loopdy.appearance.theme"
        )

        let malformedStore = SettingsStore(defaults: malformedDefaults)
        #expect(malformedStore.customThemes.isEmpty)
        #expect(malformedStore.themeID == .loopdy)
        #expect(malformedStore.customThemePersistenceError == .malformedData)
        #expect(malformedDefaults.data(forKey: "loopdy.appearance.customThemes") == malformed)

        let futureSuite = "\(#function).future"
        let futureDefaults = UserDefaults(suiteName: futureSuite)!
        futureDefaults.removePersistentDomain(forName: futureSuite)
        defer { futureDefaults.removePersistentDomain(forName: futureSuite) }
        let future = Data("{\"schemaVersion\":2,\"themes\":[]}".utf8)
        futureDefaults.set(future, forKey: "loopdy.appearance.customThemes")

        let futureStore = SettingsStore(defaults: futureDefaults)
        #expect(futureStore.customThemes.isEmpty)
        #expect(
            futureStore.customThemePersistenceError
                == .unsupportedSchemaVersion(found: 2, current: 1)
        )
        #expect(futureDefaults.data(forKey: "loopdy.appearance.customThemes") == future)
    }

    @Test func customThemeCatalogRoundTripsThroughVersionedJSON() throws {
        let theme = try makeCustomTheme(id: "00000000-0000-0000-0000-000000000023", name: "Round trip")
        let catalog = CustomThemeCatalog(themes: [theme])
        let data = try JSONEncoder().encode(catalog)
        let decoded = try JSONDecoder().decode(CustomThemeCatalog.self, from: data)
        #expect(decoded == catalog)
        #expect(decoded.schemaVersion == 1)
    }

    @Test func customThemeDescriptionRoundTripsAndLegacyThemesRemainValid() throws {
        let legacy = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000023",
            name: "Legacy"
        )
        let legacyData = try JSONEncoder().encode(legacy)
        let decodedLegacy = try JSONDecoder().decode(CustomTheme.self, from: legacyData)
        #expect(decodedLegacy.description == nil)
        #expect(decodedLegacy.definition.summary == "Custom theme using System.")

        let described = try CustomTheme(
            id: legacy.id,
            name: legacy.name,
            description: "  Warm   neutrals for focused work.  ",
            font: legacy.font,
            accentHex: legacy.accentHex,
            light: legacy.light,
            dark: legacy.dark
        )
        let decoded = try JSONDecoder().decode(
            CustomTheme.self,
            from: JSONEncoder().encode(described)
        )
        #expect(decoded.description == "Warm neutrals for focused work.")
        #expect(decoded.definition.summary == "Warm neutrals for focused work.")
    }

    @Test func customThemeDescriptionIsOptionalAndBounded() throws {
        let theme = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000024",
            name: "Optional"
        )
        let empty = try CustomTheme(
            id: theme.id,
            name: theme.name,
            description: " \n ",
            font: theme.font,
            accentHex: theme.accentHex,
            light: theme.light,
            dark: theme.dark
        )
        #expect(empty.description == nil)
        #expect(throws: CustomThemeValidationError.invalidDescription) {
            try CustomTheme(
                id: theme.id,
                name: theme.name,
                description: String(repeating: "a", count: CustomTheme.maximumDescriptionLength + 1),
                font: theme.font,
                accentHex: theme.accentHex,
                light: theme.light,
                dark: theme.dark
            )
        }
    }

    @Test func duplicateAndLogoReplacementPreserveCustomThemeDescription() throws {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults)
        let base = try makeCustomTheme(
            id: "00000000-0000-0000-0000-000000000025",
            name: "Described"
        )
        let theme = try CustomTheme(
            id: base.id,
            name: base.name,
            description: "Quiet colors for late-night work.",
            font: base.font,
            accentHex: base.accentHex,
            light: base.light,
            dark: base.dark
        )
        try store.saveCustomTheme(theme)

        let duplicate = try store.duplicateCustomTheme(id: theme.id)
        #expect(duplicate.description == theme.description)
        #expect(try theme.replacingLogo(nil).description == theme.description)
    }

    @Test func persistedCatalogCannotBypassTheCustomThemeLimit() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // One theme past the product limit must be rejected wholesale rather
        // than silently truncated, so a tampered catalog cannot widen the cap.
        let themes = try (0...SettingsStore.maximumCustomThemes).map { index in
            try makeCustomTheme(
                id: String(format: "00000000-0000-0000-0000-%012d", index + 31),
                name: "Theme \(index + 31)"
            )
        }
        #expect(themes.count == SettingsStore.maximumCustomThemes + 1)
        let themeObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(themes)
        )
        let persisted = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "themes": themeObject,
        ])
        defaults.set(persisted, forKey: "loopdy.appearance.customThemes")

        let restored = SettingsStore(defaults: defaults)

        #expect(restored.customThemes.isEmpty)
        #expect(restored.customThemePersistenceError == .invalidCatalog)
        #expect(defaults.data(forKey: "loopdy.appearance.customThemes") == persisted)
    }

    @Test func persistedCatalogAtTheLimitIsAccepted() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let themes = try (0..<SettingsStore.maximumCustomThemes).map { index in
            try makeCustomTheme(
                id: String(format: "00000000-0000-0000-0000-%012d", index + 31),
                name: "Theme \(index + 31)"
            )
        }
        let themeObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(themes)
        )
        defaults.set(
            try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "themes": themeObject,
            ]),
            forKey: "loopdy.appearance.customThemes"
        )

        let restored = SettingsStore(defaults: defaults)

        #expect(restored.customThemes.count == SettingsStore.maximumCustomThemes)
        #expect(restored.customThemePersistenceError == nil)
    }

    @Test func builtInThemesAreRegistryBackedAndResolveDistinctLightAndDarkPalettes() {
        #expect(LoopdyThemeRegistry.builtIns.map(\.id) == [.loopdy, .nous, .superpilot])

        let nousLight = LoopdyTheme.resolve(
            themeID: .nous,
            appearance: .light,
            colorScheme: .dark,
            contrast: .standard
        )
        let nousDark = LoopdyTheme.resolve(
            themeID: .nous,
            appearance: .dark,
            colorScheme: .light,
            contrast: .standard
        )
        let superpilotLight = LoopdyTheme.resolve(
            themeID: .superpilot,
            appearance: .light,
            colorScheme: .dark,
            contrast: .standard
        )

        #expect(nousLight.themeID == .nous)
        let nousDefinition = LoopdyThemeRegistry.definition(for: .nous)
        let superpilotDefinition = LoopdyThemeRegistry.definition(for: .superpilot)
        #expect(nousDefinition?.light.actionHex == "0071A9")
        #expect(nousDefinition?.light.typography.displayFontNames.first == "Sigurd Variable")
        #expect(nousDefinition?.light.typography.bodyFontNames.first == "Rules Variable")
        #expect(superpilotDefinition?.light.typeface == .rounded)
        #expect(superpilotDefinition?.light.typography.displayFontNames.first == "Segoe UI Semibold")
        #expect(superpilotDefinition?.light.typography.bodyFontNames.first == "Segoe UI")
        #expect(nousLight.canvasHex != nousDark.canvasHex)
        #expect(superpilotLight.themeID == .superpilot)
        #expect(superpilotLight.typeface == .system)
        #expect(superpilotLight.backgroundAccentHexes.count == 3)
        #expect(nousLight.typography == .loopdy)
        #expect(superpilotLight.typography == .loopdy)
        #expect(LoopdyTheme.light.typeface == .system)
        #expect(LoopdyTheme.light.typography.bodyFontNames.isEmpty)
        #expect(LoopdyTheme.light.typography.codeFontNames.isEmpty)
        #expect(LoopdyTheme.light.typography.brandFontNames.isEmpty)
    }

    @Test func builtInThemesUseNeutralCanvasesAndDistinctAccents() {
        let ids = LoopdyThemeRegistry.builtIns.map(\.id)
        let light = ids.map {
            LoopdyTheme.resolve(
                themeID: $0,
                appearance: .light,
                colorScheme: .dark,
                contrast: .standard
            )
        }
        let dark = ids.map {
            LoopdyTheme.resolve(
                themeID: $0,
                appearance: .dark,
                colorScheme: .light,
                contrast: .standard
            )
        }

        // Every built-in theme shares the default pages (Cream, Graphite); only the accent varies.
        #expect(light.allSatisfy { $0.canvasHex == "FFF9F5" && $0.surfaceHex == "FFFFFF" })
        #expect(dark.allSatisfy { $0.canvasHex == LoopdyTheme.graphiteDark.canvasHex
            && $0.surfaceHex == LoopdyTheme.graphiteDark.surfaceHex })
        #expect(Set(light.map(\.actionHex)).count == 3)
    }

    @Test func themeDefinitionsRoundTripForFutureImportedThemeCatalogs() throws {
        let definition = try #require(LoopdyThemeRegistry.definition(for: .superpilot))
        let encoded = try JSONEncoder().encode(definition)
        let decoded = try JSONDecoder().decode(LoopdyThemeDefinition.self, from: encoded)

        #expect(decoded == definition)
    }


    private func makeCustomTheme(id: String, name: String) throws -> CustomTheme {
        try CustomTheme(
            id: UUID(uuidString: id)!,
            name: name,
            font: .system,
            accentHex: "3366CC",
            light: CustomThemePalette(
                backgroundHex: "FFFFFF",
                primaryTextHex: "111111",
                secondaryTextHex: "333333",
                tertiaryTextHex: "555555"
            ),
            dark: CustomThemePalette(
                backgroundHex: "101010",
                primaryTextHex: "FFFFFF",
                secondaryTextHex: "E0E0E0",
                tertiaryTextHex: "B0B0B0"
            )
        )
    }

    private func makeLogoPNG(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).pngData { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}
