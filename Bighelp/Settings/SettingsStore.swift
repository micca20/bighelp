import Foundation
import Observation

private struct SessionSectionPreferenceCatalog: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var preferencesByAccount: [String: [String: SessionSectionPreferences]]

    init(preferencesByAccount: [String: [String: SessionSectionPreferences]] = [:]) {
        schemaVersion = Self.currentSchemaVersion
        self.preferencesByAccount = preferencesByAccount
    }
}

@MainActor
@Observable
final class SettingsStore {
    nonisolated static let maximumCustomThemes = 24

    private(set) var customThemes: [CustomTheme]
    private(set) var customThemePersistenceError: CustomThemePersistenceError?
    private(set) var sessionSectionPreferencesRevision = 0

    var availableCustomThemeSlots: Int {
        max(0, Self.maximumCustomThemes - customThemes.count)
    }

    var selectedCustomTheme: CustomTheme? {
        customThemes.first { $0.themeID == themeID }
    }

    var appearanceContext: BighelpAppearanceContext {
        BighelpAppearanceContext(
            appearance: appearance,
            themeID: themeID,
            customTheme: selectedCustomTheme,
            customLightLogoURL: selectedCustomTheme.flatMap {
                customLogoURL(for: $0.id, variant: .light)
            },
            customDarkLogoURL: selectedCustomTheme.flatMap {
                customLogoURL(for: $0.id, variant: .dark)
            },
            lightBackground: lightBackground,
            darkBackground: darkBackground,
            bubbleColor: bubbleColor
        )
    }

    /// Appearance studio: light and dark page colors and the bubble color.
    var lightBackground: BighelpLightBackground {
        didSet { defaults.set(lightBackground.rawValue, forKey: Keys.lightBackground) }
    }

    var darkBackground: BighelpDarkBackground {
        didSet { defaults.set(darkBackground.rawValue, forKey: Keys.darkBackground) }
    }

    /// Nil keeps the selected theme's own accent.
    var bubbleColor: BighelpBubbleColor? {
        didSet { defaults.set(bubbleColor?.rawValue, forKey: Keys.bubbleColor) }
    }

    var themeID: BighelpThemeID {
        didSet { defaults.set(themeID.rawValue, forKey: Keys.themeID) }
    }

    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    var autoSuggestionsEnabled: Bool {
        didSet { defaults.set(autoSuggestionsEnabled, forKey: Keys.autoSuggestions) }
    }

    var messageActionsEnabled: Bool {
        didSet { defaults.set(messageActionsEnabled, forKey: Keys.messageActions) }
    }

    var inlineUIEnabled: Bool {
        didSet { defaults.set(inlineUIEnabled, forKey: Keys.inlineUI) }
    }

    var voiceSpeed: VoiceSpeed {
        didSet { defaults.set(voiceSpeed.rawValue, forKey: Keys.voiceSpeed) }
    }

    var voiceMode: VoiceMode {
        didSet { defaults.set(voiceMode.rawValue, forKey: Keys.voiceMode) }
    }

    var voiceConversationMode: VoiceConversationMode {
        didSet { defaults.set(voiceConversationMode.rawValue, forKey: Keys.voiceConversationMode) }
    }

    var liveVoiceProvider: LiveVoiceProvider {
        didSet { defaults.set(liveVoiceProvider.rawValue, forKey: Keys.liveVoiceProvider) }
    }

    private(set) var codexLiveVoice: String {
        didSet { defaults.set(codexLiveVoice, forKey: Keys.codexLiveVoice) }
    }

    private(set) var apiLiveVoice: String {
        didSet { defaults.set(apiLiveVoice, forKey: Keys.apiLiveVoice) }
    }

    var offlineModeEnabled: Bool {
        didSet { defaults.set(offlineModeEnabled, forKey: Keys.offlineMode) }
    }

    /// Legacy app preference retained for migration compatibility. It is not
    /// presented as, or used as, writable iOS notification authorization.
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) }
    }

    var showReasoningByDefault: Bool {
        didSet { defaults.set(showReasoningByDefault, forKey: Keys.showReasoningByDefault) }
    }

    var showToolCallsByDefault: Bool {
        didSet { defaults.set(showToolCallsByDefault, forKey: Keys.showToolCallsByDefault) }
    }

    var chatActivityVisibility: ChatActivityVisibility {
        ChatActivityVisibility(
            showReasoning: showReasoningByDefault,
            showToolCalls: showToolCallsByDefault
        )
    }

    /// V3 is the only shipping interface. Legacy cases remain decodable so
    /// older preferences can be migrated without touching appearance data.
    var interfaceVersion: BighelpInterfaceVersion {
        get { .v3 }
        set {
            defaults.set(BighelpInterfaceVersion.v3.rawValue, forKey: Keys.interfaceVersion)
            defaults.set(true, forKey: Keys.uiV2Enabled)
        }
    }

    /// Compatibility projection for modern controls retained by V3.
    var uiV2Enabled: Bool {
        get { true }
        set {
            defaults.set(BighelpInterfaceVersion.v3.rawValue, forKey: Keys.interfaceVersion)
            defaults.set(true, forKey: Keys.uiV2Enabled)
        }
    }

    var reflectiveVisionEnabled: Bool {
        didSet { defaults.set(reflectiveVisionEnabled, forKey: Keys.reflectiveVision) }
    }

    var leftEdgeSwipeAction: WorkspaceSwipeAction {
        didSet { defaults.set(leftEdgeSwipeAction.rawValue, forKey: Keys.leftEdgeSwipeAction) }
    }

    var rightEdgeSwipeAction: WorkspaceSwipeAction {
        didSet { defaults.set(rightEdgeSwipeAction.rawValue, forKey: Keys.rightEdgeSwipeAction) }
    }

    var preferredBrowser: ChatBrowserPreference {
        didSet { defaults.set(preferredBrowser.rawValue, forKey: Keys.preferredBrowser) }
    }

    var midSessionChatBehavior: MidSessionChatBehavior {
        didSet { defaults.set(midSessionChatBehavior.rawValue, forKey: Keys.midSessionChatBehavior) }
    }

    var foldCompletedTurns: Bool {
        didSet { defaults.set(foldCompletedTurns, forKey: Keys.foldCompletedTurns) }
    }

    /// Reacting to an agent's message tells the agent, which may reply.
    var reactionsReachAgent: Bool {
        didSet { defaults.set(reactionsReachAgent, forKey: Keys.reactionsReachAgent) }
    }

    /// While an agent works, the Dynamic Island grows into its little stage.
    var agentIslandEnabled: Bool {
        didSet { defaults.set(agentIslandEnabled, forKey: Keys.agentIsland) }
    }

    var responseHapticsEnabled: Bool {
        didSet { defaults.set(responseHapticsEnabled, forKey: Keys.responseHaptics) }
    }

    var showProjectChanges: Bool {
        didSet { defaults.set(showProjectChanges, forKey: Keys.showProjectChanges) }
    }

    var organizeChatsByProjects: Bool {
        didSet { defaults.set(organizeChatsByProjects, forKey: Keys.organizeChatsByProjects) }
    }

    var showCronSessions: Bool {
        didSet { defaults.set(showCronSessions, forKey: Keys.showCronSessions) }
    }

    /// Reveals host administration (files, gateways, plugins, logs, ...) in Settings.
    /// Off by default so everyday use stays a simple messaging app.
    var nerdModeEnabled: Bool {
        didSet { defaults.set(nerdModeEnabled, forKey: Keys.nerdMode) }
    }

    private let defaults: UserDefaults
    private let customThemeLogoStore: CustomThemeLogoStore

    init(
        defaults: UserDefaults = .standard,
        customThemeLogoDirectory: URL? = nil
    ) {
        self.defaults = defaults
        customThemeLogoStore = CustomThemeLogoStore(
            directory: customThemeLogoDirectory ?? Self.defaultCustomThemeLogoDirectory
        )
        let persistedCustomThemes = CustomThemePersistence.load(
            defaults.data(forKey: Keys.customThemes),
            maximumThemeCount: Self.maximumCustomThemes
        )
        customThemes = persistedCustomThemes.themes
        customThemePersistenceError = persistedCustomThemes.error
        let recoveredReflectiveVisionActivation = ReflectiveVisionRecoveryMarker(
            defaults: defaults
        ).consumePendingActivation()
        let storedThemeID = BighelpThemeID(
            rawValue: defaults.string(forKey: Keys.themeID) ?? ""
        )
        let storedThemeExists = BighelpThemeRegistry.contains(storedThemeID)
            || persistedCustomThemes.themes.contains(where: { $0.themeID == storedThemeID })
        themeID = storedThemeExists ? storedThemeID : .bighelp
        appearance = AppAppearance(
            rawValue: defaults.string(forKey: Keys.appearance) ?? ""
        ) ?? .system
        autoSuggestionsEnabled = defaults.bool(
            forKey: Keys.autoSuggestions,
            default: true
        )
        messageActionsEnabled = defaults.bool(
            forKey: Keys.messageActions,
            default: true
        )
        inlineUIEnabled = defaults.bool(
            forKey: Keys.inlineUI,
            default: true
        )
        voiceSpeed = VoiceSpeed(
            rawValue: defaults.string(forKey: Keys.voiceSpeed) ?? ""
        ) ?? .normal
        voiceMode = VoiceMode(
            rawValue: defaults.string(forKey: Keys.voiceMode) ?? ""
        ) ?? .pressToTalk
        voiceConversationMode = VoiceConversationMode(
            rawValue: defaults.string(forKey: Keys.voiceConversationMode) ?? ""
        ) ?? .codexLive
        liveVoiceProvider = LiveVoiceProvider(
            rawValue: defaults.string(forKey: Keys.liveVoiceProvider) ?? ""
        ) ?? .codexSubscription
        let savedCodexVoice = defaults.string(forKey: Keys.codexLiveVoice) ?? ""
        codexLiveVoice = LiveVoiceProvider.codexSubscription.voices.contains(savedCodexVoice)
            ? savedCodexVoice : LiveVoiceProvider.codexSubscription.defaultVoice
        let savedAPIVoice = defaults.string(forKey: Keys.apiLiveVoice) ?? ""
        apiLiveVoice = LiveVoiceProvider.apiKey.voices.contains(savedAPIVoice)
            ? savedAPIVoice : LiveVoiceProvider.apiKey.defaultVoice
        offlineModeEnabled = defaults.bool(
            forKey: Keys.offlineMode,
            default: false
        )
        notificationsEnabled = defaults.bool(
            forKey: Keys.notifications,
            default: true
        )
        showReasoningByDefault = defaults.bool(
            forKey: Keys.showReasoningByDefault,
            default: ChatActivityVisibility.default.showReasoning
        )
        showToolCallsByDefault = defaults.bool(
            forKey: Keys.showToolCallsByDefault,
            default: ChatActivityVisibility.default.showToolCalls
        )
        if defaults.object(forKey: Keys.interfaceVersion) != nil
            || defaults.object(forKey: Keys.uiV2Enabled) != nil {
            defaults.set(BighelpInterfaceVersion.v3.rawValue, forKey: Keys.interfaceVersion)
            defaults.set(true, forKey: Keys.uiV2Enabled)
        }
        reflectiveVisionEnabled = defaults.bool(
            forKey: Keys.reflectiveVision,
            default: false
        )
        if recoveredReflectiveVisionActivation {
            reflectiveVisionEnabled = false
            defaults.set(false, forKey: Keys.reflectiveVision)
        }
        let storedLeftEdgeSwipeAction = WorkspaceSwipeAction(
            rawValue: defaults.string(forKey: Keys.leftEdgeSwipeAction) ?? ""
        ) ?? .sessions
        let storedRightEdgeSwipeAction = WorkspaceSwipeAction(
            rawValue: defaults.string(forKey: Keys.rightEdgeSwipeAction) ?? ""
        ) ?? .newChat
        leftEdgeSwipeAction = storedLeftEdgeSwipeAction == .inbox
            ? .home
            : storedLeftEdgeSwipeAction
        rightEdgeSwipeAction = storedRightEdgeSwipeAction == .inbox
            ? .home
            : storedRightEdgeSwipeAction
        if storedLeftEdgeSwipeAction == .inbox {
            defaults.set(WorkspaceSwipeAction.home.rawValue, forKey: Keys.leftEdgeSwipeAction)
        }
        if storedRightEdgeSwipeAction == .inbox {
            defaults.set(WorkspaceSwipeAction.home.rawValue, forKey: Keys.rightEdgeSwipeAction)
        }
        preferredBrowser = ChatBrowserPreference(
            rawValue: defaults.string(forKey: Keys.preferredBrowser) ?? ""
        ) ?? .systemDefault
        midSessionChatBehavior = MidSessionChatBehavior(
            rawValue: defaults.string(forKey: Keys.midSessionChatBehavior) ?? ""
        ) ?? .interruptAndSend
        foldCompletedTurns = defaults.bool(forKey: Keys.foldCompletedTurns, default: true)
        reactionsReachAgent = defaults.bool(forKey: Keys.reactionsReachAgent, default: true)
        lightBackground = defaults.string(forKey: Keys.lightBackground).flatMap(BighelpLightBackground.init(rawValue:)) ?? .cream
        darkBackground = defaults.string(forKey: Keys.darkBackground).flatMap(BighelpDarkBackground.init(rawValue:)) ?? .graphite
        bubbleColor = defaults.string(forKey: Keys.bubbleColor).flatMap(BighelpBubbleColor.init(rawValue:))
        agentIslandEnabled = defaults.bool(forKey: Keys.agentIsland, default: true)
        responseHapticsEnabled = defaults.bool(forKey: Keys.responseHaptics, default: true)
        showProjectChanges = defaults.bool(
            forKey: Keys.showProjectChanges,
            default: true
        )
        organizeChatsByProjects = defaults.bool(
            forKey: Keys.organizeChatsByProjects,
            default: false
        )
        showCronSessions = defaults.bool(
            forKey: Keys.showCronSessions,
            default: false
        )
        nerdModeEnabled = defaults.bool(forKey: Keys.nerdMode, default: false)

        if persistedCustomThemes.requiresMigration {
            do {
                defaults.set(
                    try CustomThemePersistence.encode(customThemes),
                    forKey: Keys.customThemes
                )
            } catch {
                customThemePersistenceError = .malformedData
            }
        }
    }

    static func eraseSessionSectionPreferences(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Keys.sessionSectionPreferences)
    }

    func sessionSectionPreferences(
        accountID: String?,
        hostID: String?
    ) -> SessionSectionPreferences {
        _ = sessionSectionPreferencesRevision
        guard let scope = sessionSectionScope(accountID: accountID, hostID: hostID) else {
            return SessionSectionPreferences()
        }
        return loadSessionSectionPreferenceCatalog()
            .preferencesByAccount[scope.accountID]?[scope.hostID]
            .map(Self.sanitized) ?? SessionSectionPreferences()
    }

    func sessionSectionLayout(
        accountID: String?,
        hostID: String?,
        availableProjectKeys: [SessionSectionKey]
    ) -> SessionSectionLayout {
        let preferences = sessionSectionPreferences(accountID: accountID, hostID: hostID)
        return SessionSectionLayout(
            projectOrder: SessionSectionLayout.orderedProjectKeys(
                savedOrder: preferences.projectOrder,
                availableKeys: availableProjectKeys
            ),
            collapsedSectionKeys: preferences.collapsedSectionKeys
        )
    }

    func setSessionSectionCollapsed(
        _ collapsed: Bool,
        sectionKey: SessionSectionKey,
        accountID: String?,
        hostID: String?
    ) {
        guard sectionKey.isReorderable else { return }
        updateSessionSectionPreferences(accountID: accountID, hostID: hostID) { preferences in
            if collapsed {
                preferences.collapsedSectionKeys.insert(sectionKey)
            } else {
                preferences.collapsedSectionKeys.remove(sectionKey)
            }
        }
    }

    func setSessionSectionOrder(
        _ reorderedKeys: [SessionSectionKey],
        accountID: String?,
        hostID: String?
    ) {
        updateSessionSectionPreferences(accountID: accountID, hostID: hostID) { preferences in
            preferences.projectOrder = SessionSectionLayout.preservingSavedKeys(
                reorderedKeys: reorderedKeys,
                savedOrder: preferences.projectOrder
            )
        }
    }

    func moveSessionSection(
        _ sectionKey: SessionSectionKey,
        direction: SessionSectionMoveDirection,
        availableProjectKeys: [SessionSectionKey],
        accountID: String?,
        hostID: String?
    ) {
        let layout = sessionSectionLayout(
            accountID: accountID,
            hostID: hostID,
            availableProjectKeys: availableProjectKeys
        )
        guard let index = layout.projectOrder.firstIndex(of: sectionKey) else { return }
        let destination = direction == .up ? index - 1 : index + 1
        guard layout.projectOrder.indices.contains(destination) else { return }
        moveSessionSection(
            sectionKey,
            to: layout.projectOrder[destination],
            availableProjectKeys: layout.projectOrder,
            accountID: accountID,
            hostID: hostID
        )
    }

    func moveSessionSection(
        _ sectionKey: SessionSectionKey,
        to targetKey: SessionSectionKey,
        availableProjectKeys: [SessionSectionKey],
        accountID: String?,
        hostID: String?
    ) {
        let layout = sessionSectionLayout(
            accountID: accountID,
            hostID: hostID,
            availableProjectKeys: availableProjectKeys
        )
        let reordered = SessionSectionLayout.moving(
            sectionKey,
            to: targetKey,
            in: layout.projectOrder
        )
        guard reordered != layout.projectOrder else { return }
        setSessionSectionOrder(
            reordered,
            accountID: accountID,
            hostID: hostID
        )
    }

    @discardableResult
    func saveCustomTheme(_ theme: CustomTheme) throws -> CustomThemeSaveOutcome {
        var candidate = customThemes
        let outcome: CustomThemeSaveOutcome
        if let index = candidate.firstIndex(where: { $0.id == theme.id }) {
            candidate[index] = theme
            outcome = .updated
        } else {
            guard candidate.count < Self.maximumCustomThemes else {
                throw CustomThemeStoreError.limitReached(maximum: Self.maximumCustomThemes)
            }
            candidate.append(theme)
            outcome = .created
        }

        do {
            defaults.set(
                try CustomThemePersistence.encode(candidate),
                forKey: Keys.customThemes
            )
        } catch {
            customThemePersistenceError = .malformedData
            throw CustomThemeStoreError.persistenceFailed
        }
        customThemes = candidate
        customThemePersistenceError = nil
        return outcome
    }

    @discardableResult
    func setCustomThemeLogo(
        data: Data,
        for themeID: UUID,
        variant: CustomThemeLogoVariant? = nil
    ) throws -> CustomThemeLogo {
        guard let theme = customThemes.first(where: { $0.id == themeID }) else {
            throw CustomThemeLogoStoreError.themeNotFound
        }
        let previousLogos = variant == nil
            ? [theme.lightLogo, theme.darkLogo]
            : [variant == .light ? theme.lightLogo : theme.darkLogo]
        let logo = try customThemeLogoStore.store(data)
        do {
            _ = try saveCustomTheme(theme.replacingLogo(logo, variant: variant))
            for previousLogo in previousLogos.compactMap({ $0 })
            where previousLogo != logo && !isLogoReferenced(previousLogo) {
                try? customThemeLogoStore.remove(previousLogo)
            }
            return logo
        } catch {
            try? customThemeLogoStore.remove(logo)
            throw error
        }
    }

    func customLogoURL(
        for themeID: UUID,
        variant: CustomThemeLogoVariant? = nil
    ) -> URL? {
        guard let theme = customThemes.first(where: { $0.id == themeID }) else {
            return nil
        }
        let logo = switch variant {
        case .light: theme.lightLogo
        case .dark: theme.darkLogo
        case nil: theme.logo
        }
        guard let logo else { return nil }
        return customThemeLogoStore.existingURL(for: logo)
    }

    func customLogoData(
        for themeID: UUID,
        variant: CustomThemeLogoVariant
    ) throws -> Data? {
        guard let theme = customThemes.first(where: { $0.id == themeID }) else {
            throw CustomThemeLogoStoreError.themeNotFound
        }
        let logo = variant == .light ? theme.lightLogo : theme.darkLogo
        guard let logo else { return nil }
        guard let url = customThemeLogoStore.existingURL(for: logo) else {
            throw CustomThemeImportTransactionError.persistenceReadbackFailed
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == logo.byteCount,
              data.count <= CustomThemeLogoStore.maximumByteCount
        else { throw CustomThemeImportTransactionError.persistenceReadbackFailed }
        return data
    }

    /// Stages a portable theme and its files, then verifies their persisted
    /// readback before exposing the imported local copy.
    /// Any failure restores the exact prior settings bytes and removes staged
    /// logos, so callers cannot observe a partial installation.
    @discardableResult
    private func importPortableCustomTheme(
        _ theme: CustomTheme,
        lightLogoData: Data?,
        darkLogoData: Data?
    ) throws -> CustomTheme {
        guard !customThemes.contains(where: { $0.id == theme.id }) else {
            throw CustomThemeImportTransactionError.identifierAlreadyExists
        }
        guard theme.lightLogo == nil, theme.darkLogo == nil else {
            throw CustomThemeImportTransactionError.invalidStagedTheme
        }

        let originalThemes = customThemes
        let originalPersistenceData = defaults.data(forKey: Keys.customThemes)
        let originalThemeID = themeID
        do {
            _ = try saveCustomTheme(theme)
            if let lightLogoData {
                _ = try setCustomThemeLogo(
                    data: lightLogoData,
                    for: theme.id,
                    variant: .light
                )
            }
            if let darkLogoData {
                _ = try setCustomThemeLogo(
                    data: darkLogoData,
                    for: theme.id,
                    variant: .dark
                )
            }
            guard let installed = customThemes.first(where: { $0.id == theme.id }) else {
                throw CustomThemeImportTransactionError.persistenceReadbackFailed
            }
            let persisted = CustomThemePersistence.load(
                defaults.data(forKey: Keys.customThemes),
                maximumThemeCount: Self.maximumCustomThemes
            )
            guard persisted.error == nil,
                  persisted.themes.first(where: { $0.id == theme.id }) == installed,
                  try customLogoData(for: theme.id, variant: .light) == lightLogoData,
                  try customLogoData(for: theme.id, variant: .dark) == darkLogoData
            else { throw CustomThemeImportTransactionError.persistenceReadbackFailed }

            return installed
        } catch {
            let stagedLogos = customThemes.first(where: { $0.id == theme.id }).map {
                [$0.lightLogo, $0.darkLogo].compactMap { $0 }
            } ?? []
            customThemes = originalThemes
            if let originalPersistenceData {
                defaults.set(originalPersistenceData, forKey: Keys.customThemes)
            } else {
                defaults.removeObject(forKey: Keys.customThemes)
            }
            themeID = originalThemeID
            for logo in stagedLogos where !isLogoReferenced(logo) {
                try? customThemeLogoStore.remove(logo)
            }
            throw error
        }
    }

    func removeCustomThemeLogo(
        for themeID: UUID,
        variant: CustomThemeLogoVariant? = nil
    ) throws {
        guard let theme = customThemes.first(where: { $0.id == themeID }) else {
            throw CustomThemeLogoStoreError.themeNotFound
        }
        let logos = variant == nil
            ? [theme.lightLogo, theme.darkLogo]
            : [variant == .light ? theme.lightLogo : theme.darkLogo]
        guard logos.contains(where: { $0 != nil }) else { return }
        _ = try saveCustomTheme(theme.replacingLogo(nil, variant: variant))
        for logo in logos.compactMap({ $0 }) where !isLogoReferenced(logo) {
            try customThemeLogoStore.remove(logo)
        }
    }

    @discardableResult
    func duplicateCustomTheme(id: UUID) throws -> CustomTheme {
        guard let source = customThemes.first(where: { $0.id == id }) else {
            throw CustomThemeLogoStoreError.themeNotFound
        }
        let suffix = " Copy"
        let availableNameLength = max(1, CustomTheme.maximumNameLength - suffix.count)
        let duplicate = try CustomTheme(
            name: String(source.name.prefix(availableNameLength)) + suffix,
            description: source.description,
            font: source.font,
            accentHex: source.accentHex,
            light: source.light,
            dark: source.dark,
            lightLogo: source.lightLogo,
            darkLogo: source.darkLogo
        )
        _ = try saveCustomTheme(duplicate)
        return duplicate
    }

    func deleteCustomTheme(id: UUID) throws {
        guard let index = customThemes.firstIndex(where: { $0.id == id }) else {
            throw CustomThemeLogoStoreError.themeNotFound
        }
        var candidate = customThemes
        let removed = candidate.remove(at: index)
        defaults.set(
            try CustomThemePersistence.encode(candidate),
            forKey: Keys.customThemes
        )
        customThemes = candidate
        customThemePersistenceError = nil
        if themeID == removed.themeID {
            themeID = .bighelp
        }
        for logo in [removed.lightLogo, removed.darkLogo].compactMap({ $0 })
        where !isLogoReferenced(logo) {
            try customThemeLogoStore.remove(logo)
        }
    }

    /// Collection exports retain their existing upsert behavior. Portable
    /// single-theme files are untrusted copies: never use their UUID to replace
    /// local work.
    func importCustomThemeFile(_ data: Data) throws {
        guard data.count <= PortableCustomThemePackage.maximumArtifactByteCount else {
            throw PortableCustomThemePackageError.packageTooLarge
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if root["kind"] != nil || root["content"] != nil {
            // A malformed portable package must not fall back to the more
            // permissive collection decoder.
            let payload = try PortableCustomThemePackage.decodeArtifact(data)
            let source = payload.theme
            let imported = try CustomTheme(
                name: source.name,
                description: source.description,
                font: source.font,
                accentHex: source.accentHex,
                light: source.light,
                dark: source.dark
            )
            _ = try importPortableCustomTheme(
                imported,
                lightLogoData: payload.lightLogoData,
                darkLogoData: payload.darkLogoData
            )
        } else {
            let catalog = try JSONDecoder().decode(CustomThemeCatalog.self, from: data)
            guard catalog.schemaVersion == CustomThemeCatalog.currentSchemaVersion else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try importCustomThemes(catalog.themes)
        }
    }

    func importCustomThemes(_ themes: [CustomTheme]) throws {
        guard Set(themes.map(\.id)).count == themes.count else {
            throw CustomThemePersistenceError.invalidCatalog
        }

        var candidate = customThemes
        for theme in themes {
            if let index = candidate.firstIndex(where: { $0.id == theme.id }) {
                candidate[index] = theme
            } else {
                candidate.append(theme)
            }
        }
        guard candidate.count <= Self.maximumCustomThemes else {
            throw CustomThemeStoreError.limitReached(maximum: Self.maximumCustomThemes)
        }

        defaults.set(
            try CustomThemePersistence.encode(candidate),
            forKey: Keys.customThemes
        )
        customThemes = candidate
        customThemePersistenceError = nil
    }

    func liveVoice(for provider: LiveVoiceProvider) -> String {
        switch provider {
        case .codexSubscription: codexLiveVoice
        case .apiKey: apiLiveVoice
        }
    }

    func setLiveVoice(_ voice: String, for provider: LiveVoiceProvider) {
        guard provider.voices.contains(voice) else { return }
        switch provider {
        case .codexSubscription: codexLiveVoice = voice
        case .apiKey: apiLiveVoice = voice
        }
    }

    private func isLogoReferenced(_ logo: CustomThemeLogo) -> Bool {
        customThemes.contains {
            $0.lightLogo == logo || $0.darkLogo == logo
        }
    }
}

private extension SettingsStore {
    static var defaultCustomThemeLogoDirectory: URL {
        let arguments = ProcessInfo.processInfo.arguments
        let usesFixtures = arguments.contains("-disable-demo-delays")
            || arguments.contains("-use-demo-fixtures")
        return BighelpApplicationDataDirectories.active(fixtures: usesFixtures)
            .appending(path: "custom-theme-logos", directoryHint: .isDirectory)
    }

    private func sessionSectionScope(
        accountID: String?,
        hostID: String?
    ) -> (accountID: String, hostID: String)? {
        guard
            let accountID,
            let hostID,
            !accountID.isEmpty,
            !hostID.isEmpty,
            accountID.count <= 256,
            hostID.count <= 256
        else { return nil }
        return (accountID, hostID)
    }

    private func loadSessionSectionPreferenceCatalog() -> SessionSectionPreferenceCatalog {
        guard
            let data = defaults.data(forKey: Keys.sessionSectionPreferences),
            let catalog = try? JSONDecoder().decode(SessionSectionPreferenceCatalog.self, from: data),
            catalog.schemaVersion == SessionSectionPreferenceCatalog.currentSchemaVersion
        else { return SessionSectionPreferenceCatalog() }
        return catalog
    }

    private func updateSessionSectionPreferences(
        accountID: String?,
        hostID: String?,
        update: (inout SessionSectionPreferences) -> Void
    ) {
        guard let scope = sessionSectionScope(accountID: accountID, hostID: hostID) else { return }
        // An older app must not replace a newer or unreadable preference format.
        if let existing = defaults.data(forKey: Keys.sessionSectionPreferences) {
            guard let decoded = try? JSONDecoder().decode(SessionSectionPreferenceCatalog.self, from: existing),
                  decoded.schemaVersion == SessionSectionPreferenceCatalog.currentSchemaVersion else { return }
        }
        var catalog = loadSessionSectionPreferenceCatalog()
        var preferences = catalog.preferencesByAccount[scope.accountID]?[scope.hostID]
            .map(Self.sanitized) ?? SessionSectionPreferences()
        update(&preferences)
        preferences = Self.sanitized(preferences)
        var accountPreferences = catalog.preferencesByAccount[scope.accountID] ?? [:]
        accountPreferences[scope.hostID] = preferences
        catalog.preferencesByAccount[scope.accountID] = accountPreferences
        guard let encoded = try? JSONEncoder().encode(catalog) else { return }
        defaults.set(encoded, forKey: Keys.sessionSectionPreferences)
        sessionSectionPreferencesRevision &+= 1
    }

    private static func sanitized(
        _ preferences: SessionSectionPreferences
    ) -> SessionSectionPreferences {
        let maximumSectionCount = SessionCatalogStore.summaryRetentionLimit + 1
        var orderSeen = Set<SessionSectionKey>()
        let projectOrder = preferences.projectOrder.filter {
            $0.isReorderable && orderSeen.insert($0).inserted
        }.prefix(maximumSectionCount)
        let collapsed = preferences.collapsedSectionKeys
            .filter(\.isReorderable)
            .prefix(maximumSectionCount)
        return SessionSectionPreferences(
            projectOrder: Array(projectOrder),
            collapsedSectionKeys: Set(collapsed)
        )
    }

    enum Keys {
        static let appearance = "loopdy.demo.appearance"
        static let themeID = "loopdy.appearance.theme"
        static let uiV2Enabled = "loopdy.appearance.ui-v2-enabled"
        static let interfaceVersion = "loopdy.appearance.interface-version"
        static let customThemes = "loopdy.appearance.customThemes"
        static let autoSuggestions = "loopdy.demo.autoSuggestions"
        static let messageActions = "loopdy.demo.messageActions"
        static let inlineUI = "loopdy.demo.inlineUI"
        static let voiceSpeed = "loopdy.demo.voiceSpeed"
        static let voiceMode = "loopdy.voice.mode"
        static let voiceConversationMode = "loopdy.voice.conversation-mode"
        static let liveVoiceProvider = "loopdy.voice.live.provider"
        static let codexLiveVoice = "loopdy.voice.live.codex-voice"
        static let apiLiveVoice = "loopdy.voice.live.api-voice"
        static let offlineMode = "loopdy.demo.offlineMode"
        static let notifications = "loopdy.demo.notifications"
        static let showReasoningByDefault = "loopdy.chat.showReasoningByDefault"
        static let showToolCallsByDefault = "loopdy.chat.showToolCallsByDefault"
        static let reflectiveVision = "loopdy.appearance.reflectiveVision"
        static let leftEdgeSwipeAction = "loopdy.workspace.leftEdgeSwipeAction"
        static let rightEdgeSwipeAction = "loopdy.workspace.rightEdgeSwipeAction"
        static let preferredBrowser = "loopdy.chat.preferredBrowser"
        static let midSessionChatBehavior = "loopdy.chat.midSessionBehavior"
        static let foldCompletedTurns = "loopdy.chat.foldCompletedTurns"
        static let reactionsReachAgent = "loopdy.chat.reactionsReachAgent"
        static let agentIsland = "loopdy.chat.agentIsland"
        static let lightBackground = "loopdy.appearance.lightBackground"
        static let darkBackground = "loopdy.appearance.darkBackground"
        static let bubbleColor = "loopdy.appearance.bubbleColor"
        static let responseHaptics = "loopdy.chat.responseHaptics"
        static let showProjectChanges = "loopdy.chat.showProjectChanges"
        static let organizeChatsByProjects = "loopdy.sessions.organizeByProjects"
        static let showCronSessions = "loopdy.sessions.showCronSessions"
        static let nerdMode = "loopdy.settings.nerd-mode"
        static let sessionSectionPreferences = "loopdy.sessions.section-preferences.v1"
    }
}

private extension UserDefaults {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) == nil ? defaultValue : bool(forKey: key)
    }
}
