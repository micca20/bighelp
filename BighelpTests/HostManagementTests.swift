import Foundation
import Testing
@testable import Bighelp

@MainActor struct HostManagementTests {
    @Test(arguments: [BighelpManagedNotificationSetupError.Stage.providerBootstrap, .providerIdentity,
                      .notificationPermission, .deviceRegistration, .providerReadiness])
    func providerFailureDoesNotClaimPluginOrHostFailure(stage: BighelpManagedNotificationSetupError.Stage) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = [fixture.plugin(enabled: true)]
        let setup = Enrollment()
        let error = BighelpManagedNotificationSetupError(stage: stage)
        setup.error = error
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management)
        await model.enable()
        #expect(model.state == .prerequisitesRequired)
        #expect(model.message == error.localizedDescription)
        #expect(management.actions == ["list"])
        setup.error = nil
        await model.enable()
        #expect(model.state == .enabled)
        #expect(model.providerFailure == nil)
    }

    @Test(arguments: [true, false])
    func openingPluginDetailsReadsInstalledStateWithoutMutation(installed: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = installed ? [fixture.plugin(enabled: true)] : []
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management, enrollNotifications: false)
        await model.refreshInstalledState()
        #expect(model.state == (installed ? .installed : .notConfigured))
        #expect(management.actions == ["list"])
        #expect(fixture.registry.hosts.first?.pluginIntent == nil)
        #expect(fixture.registry.hosts.first?.notificationState == fixture.host.notificationState)
    }

    @Test func savedNotificationOptInDoesNotPromptAgainOnReopen() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var host = fixture.host
        host.notificationState = .enabled
        try fixture.registry.update(host)
        let management = Manager(saved: fixture.saved)
        let model = HostNotificationSetupModel(host: host, registry: fixture.registry,
            pin: fixture.pin, management: management)
        #expect(model.state == .enabled)
        #expect(model.actionTitle == nil)
        #expect(management.actions.isEmpty)
    }

    @Test func unrelatedPluginStatusCannotBlockExactInstalledBighelp() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = [
            .object(["name": .string("unrelated-plugin"), "status": .string("future-status")]),
            fixture.plugin(enabled: true)
        ]
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management, enrollNotifications: false)
        await model.enable()
        #expect(model.state == .installed)
        #expect(management.actions == ["list"])
    }

    @Test func bighelpTargetReadbackStillRejectsInvalidOrDuplicateRows() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for rows in [
            [fixture.plugin(enabled: true), fixture.plugin(enabled: true)],
            [.object(["name": .string("loopdy"), "key": .string("loopdy"), "status": .string("future-status")])],
            [.object(["name": .string("loopdy"), "key": .string("loopdy"), "status": .string("enabled"), "pinned_sha": .string("invalid")])]
        ] {
            #expect(throws: DirectHermesError.self) {
                try HostInstalledPlugin.decodeList(.object(["plugins": .array(rows)]))
            }
        }
    }

    @Test(arguments: [true, false])
    func featurePluginSetupNeverEnrollsNotificationsOrChangesTheirState(alreadyInstalled: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        if alreadyInstalled { management.rows = [fixture.plugin(enabled: true)] }
        management.onInstall = { management.rows = [fixture.plugin(enabled: true)] }
        let enrollment = Enrollment()
        fixture.registry.notificationSetup = enrollment
        let previousState = fixture.host.notificationState
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management, enrollNotifications: false)
        await model.enable()
        #expect(model.state == .installed)
        #expect(enrollment.calls == 0)
        #expect(fixture.registry.hosts.first?.notificationState == previousState)
        #expect(management.actions.filter { $0 == "install" }.count == (alreadyInstalled ? 0 : 1))
    }

    @Test func featureSetupEnablesExactPinnedPluginWithoutReinstalling() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        let existingRevision = fixture.pin.revision
        func row(_ enabled: Bool) -> BighelpJSONValue {
            .object(["name": .string("loopdy"), "key": .string("loopdy"),
                     "status": .string(enabled ? "enabled" : "disabled"),
                     "pinned_sha": .string(existingRevision)])
        }
        management.rows = [row(false)]
        management.onToggle = { management.rows = [row(true)] }
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management, enrollNotifications: false)
        await model.enable()
        #expect(model.state == .installed)
        #expect(management.actions == ["list", "toggle", "list"])
        #expect(!management.actions.contains("install"))
    }

    @Test func remoteDashboardOffersItsExistingSessionTokenMode() throws {
        let endpoint = try HostAddressInput.endpoint(address: "https://hermes.example.ts.net", port: "9119", allowPrivateHTTP: false)
        let discovery = HostAuthenticationDiscovery(endpoint: endpoint, requiresAuthentication: false, nativePKCE: false, providers: [])
        #expect(discovery.supportsToken)
        #expect(discovery.endpoint.baseURL.port == 9119)
    }

    @Test func workspaceHealthDoesNotRequireAProviderLogin() throws {
        try DirectHermesReleaseContract.validateHealth([
            "ok": .boolean(true), "auth_required": .boolean(false), "version": .string("0.21.2")
        ])
    }

    @Test func dashboardBootstrapIsBoundedAndNeverTreatsALoginPageAsAnonymous() throws {
        let page = #"<html><script>window.__HERMES_SESSION_TOKEN__="fixture-token";window.__HERMES_AUTH_REQUIRED__=false;</script></html>"#
        #expect(try DirectHermesDashboardBootstrap.token(from: Data(page.utf8)) == "fixture-token")
        for invalid in [page.replacingOccurrences(of: "false", with: "true"), page + page,
                        "<html>Login required</html>", page.replacingOccurrences(of: "fixture-token", with: "") ] {
            #expect(throws: DirectHermesError.self) { try DirectHermesDashboardBootstrap.token(from: Data(invalid.utf8)) }
        }
    }

    @Test func dashboardScopeNeverClaimsAProviderUserOrChangesThePort() throws {
        let endpoint = try DirectHermesEndpoint(address: "https://hermes.example.ts.net:9119")
        let saved = DirectHermesSavedConnection(endpoint: endpoint, authentication: .dashboardSession(token: "fixture", automatic: true))
        try saved.validate()
        #expect(saved.provider == nil && saved.userID == nil)
        let authority = try #require(saved.workspaceAuthority)
        #expect(authority.providerID == nil)
        #expect(authority.endpointIdentity == endpoint.identity)
        #expect(try JSONDecoder().decode(WorkspaceAuthority.self, from: JSONEncoder().encode(authority)) == authority)
        let named = try WorkspaceAuthority.direct(endpointIdentity: endpoint.identity, providerID: "password", userID: "person")
        #expect(authority != named && authority.cacheScopeID != named.cacheScopeID)
        var changed = saved
        changed.authentication = .dashboardSession(token: "rotated-fixture", automatic: true)
        #expect(saved.identity == changed.identity)
        #expect(saved.workspaceAuthority == changed.workspaceAuthority)
    }

    @Test func hostProviderMethodsAreOfferedWithoutChangingItsConfiguration() throws {
        let endpoint = try DirectHermesEndpoint(address: "https://hermes.example.ts.net:9119")
        let discovery = HostAuthenticationDiscovery(endpoint: endpoint, requiresAuthentication: true, nativePKCE: true,
            providers: [.init(id: "basic", name: "Password", supportsPassword: true), .init(id: "oauth", name: "Dashboard", supportsPassword: false)])
        #expect(discovery.supportsToken && discovery.supportsPassword && discovery.supportsBrowser)
        #expect(!discovery.supportsDashboard)
    }

    @Test func separatePortKeepsURLPrefixAndRejectsConflictingAuthority() throws {
        let address = try HostAddressInput.endpoint(address: "https://example.com/hermes", port: "9443", allowPrivateHTTP: false)
        #expect(address.identity == "https://example.com:9443/hermes")
        #expect(throws: DirectHermesError.self) { try HostAddressInput.endpoint(address: "https://example.com:443", port: "9443", allowPrivateHTTP: false) }
        #expect(throws: DirectHermesError.self) { try HostAddressInput.endpoint(address: "https://user:secret@example.com", port: "443", allowPrivateHTTP: false) }
    }

    @Test func exactInstalledPinNeedsActualEnrollmentAndNeverReinstalls() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = [fixture.plugin(enabled: true)]
        let setup = Enrollment()
        setup.result = .backendRestartRequired
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management)
        await model.enable()
        #expect(management.actions == ["list"])
        #expect(model.state == .backendRestartRequired)
        #expect(setup.calls == 1)
    }

    @Test func lostInstallReplyReconcilesExactPinWithoutReplay() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.onInstall = { management.rows = [fixture.plugin(enabled: true)] }
        management.installError = .disconnected(outcomeUnknown: true)
        let setup = Enrollment()
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry, pin: fixture.pin, management: management)
        await model.enable()
        #expect(management.actions.filter { $0 == "install" }.count == 1)
        #expect(model.state == .enabled)
        await model.enable()
        #expect(management.actions.filter { $0 == "install" }.count == 1)
        #expect(management.requests.allSatisfy { $0["force"] != .boolean(true) && $0["profile"] == nil })
    }

    @Test(arguments: [true, false])
    func installedPluginUsesEnrollmentCompatibilityInsteadOfInstallPin(pinned: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = [.object(["name": .string("loopdy"), "key": .string("loopdy"),
            "status": .string("enabled"),
            "pinned_sha": pinned ? .string(String(repeating: "b", count: 40)) : .null])]
        let setup = Enrollment()
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management)

        await model.enable()

        #expect(model.state == .enabled)
        #expect(management.actions == ["list"])
        #expect(setup.calls == 1)
        #expect(fixture.registry.hosts.first?.pluginIntent == nil)
    }

    @Test func installedPluginCanEnrollAfterAppInstallPinChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var host = fixture.host
        host.pluginIntent = .init(identifier: fixture.pin.identifier,
            revision: String(repeating: "b", count: 40), profile: nil, phase: .verified)
        try fixture.registry.update(host)
        let management = Manager(saved: fixture.saved)
        management.rows = [fixture.plugin(enabled: true)]
        let setup = Enrollment()
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: host, registry: fixture.registry,
            pin: fixture.pin, management: management)

        await model.enable()

        #expect(model.state == .enabled)
        #expect(management.actions == ["list"])
        #expect(setup.calls == 1)
    }

    @Test func existingPluginDoesNotNeedANewInstallationPinOrInventReadiness() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = [fixture.plugin(enabled: true)]
        let setup = Enrollment()
        setup.result = .prerequisitesRequired
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: nil, management: management)

        await model.enable()

        #expect(model.state == .prerequisitesRequired)
        #expect(management.actions == ["list"])
        #expect(setup.calls == 1)
    }

    @Test func unavailableOptionalNotificationRouteIsReportedAsPrerequisites() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.rows = [fixture.plugin(enabled: true)]
        let setup = Enrollment()
        setup.error = BighelpLinkAPIError.requestFailed(status: 404, code: "not_found")
        fixture.registry.notificationSetup = setup
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry,
            pin: fixture.pin, management: management)

        await model.enable()

        #expect(model.state == .prerequisitesRequired)
        #expect(management.actions == ["list"])
        #expect(setup.calls == 1)
    }

    @Test func unknownAbsentInstallNeverRetriesAndObservedPluginIsReused() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let management = Manager(saved: fixture.saved)
        management.installError = .disconnected(outcomeUnknown: true)
        let model = HostNotificationSetupModel(host: fixture.host, registry: fixture.registry, pin: fixture.pin, management: management)
        await model.enable()
        await model.enable()
        #expect(management.actions.filter { $0 == "install" }.count == 1)
        #expect(model.state == .outcomeUnknown)
        management.rows = [.object(["name": .string("loopdy"), "key": .string("loopdy"), "status": .string("enabled"), "pinned_sha": .string(String(repeating: "b", count: 40))])]
        await model.enable()
        #expect(model.state == .prerequisitesRequired)
        #expect(management.actions.filter { $0 == "install" }.count == 1)
    }

    @Test func accountSwitchKeepsLegacyHostMetadataPrivateUntilExplicitMigration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        #expect(fixture.registry.hosts.count == 1)
        #expect(fixture.registry.selectedWorkspace?.isConnected == false)
        fixture.registry.bind(deviceID: "other-account", authorizationEpoch: 1)
        #expect(fixture.registry.hosts.isEmpty)
        fixture.registry.bind(deviceID: "test-account", authorizationEpoch: 1)
        #expect(fixture.registry.hosts == [fixture.host])
    }

    private final class Enrollment: HostNotificationSetupServing {
        var calls = 0
        var result: HostNotificationSetupResult = .enabled
        var error: (any Error)?
        func enroll(host: BighelpConfiguredHost, connection: DirectHermesSavedConnection,
                    isCurrent: @escaping @MainActor () -> Bool) async throws -> HostNotificationSetupResult {
            guard isCurrent() else { throw DirectHermesError.secureStorageChanged }
            calls += 1
            if let error { throw error }
            return result
        }
        func removeLocalEnrollment(host: BighelpConfiguredHost) throws {}
    }
    private final class Manager: HostPluginManagementServing {
        var isConnected = true
        var savedConnection: DirectHermesSavedConnection?
        var rows: [BighelpJSONValue] = []
        var actions: [String] = []
        var requests: [[String: BighelpJSONValue]] = []
        var installError: DirectHermesError?
        var onInstall: (() -> Void)?
        var onToggle: (() -> Void)?
        init(saved: DirectHermesSavedConnection) { savedConnection = saved }
        func reconnect() async {}
        func managePlugins(_ params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
            requests.append(params)
            let action = params["action"]?.string ?? ""
            actions.append(action)
            if action == "install" { onInstall?(); if let installError { throw installError } }
            if action == "toggle" { onToggle?() }
            return .object(["plugins": .array(rows)])
        }
    }
    @MainActor private struct Fixture {
        let registry: BighelpHostRegistry
        let host: BighelpConfiguredHost
        let saved: DirectHermesSavedConnection
        let pin: HostPluginPin
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            registry = BighelpHostRegistry(root: root, keychainService: "app.loopdy.test.host-management." + UUID().uuidString)
            registry.bind(deviceID: "test-account", authorizationEpoch: 1)
            let scope = try #require(registry.accountScope)
            let endpoint = try DirectHermesEndpoint(address: "https://host.example")
            saved = DirectHermesSavedConnection(endpoint: endpoint, authentication: .bearer(accessToken: UUID().uuidString, refreshToken: nil, expiresAt: nil), provider: "basic", userID: "fixture")
            host = BighelpConfiguredHost(id: UUID(), accountScope: scope, accountID: "test-account", endpoint: endpoint, principalIdentity: saved.identity, name: "Fixture host")
            struct Snapshot: Encodable { let version = 1; let hosts: [BighelpConfiguredHost]; let selected: UUID? }
            try JSONEncoder().encode(Snapshot(hosts: [host], selected: host.id)).write(to: root.appending(path: scope + ".json"))
            registry.bind(deviceID: "test-account", authorizationEpoch: 1, forceReload: true)
            pin = try HostPluginPin(revision: String(repeating: "a", count: 40))
        }
        func plugin(enabled: Bool) -> BighelpJSONValue {
            .object(["name": .string("loopdy"), "key": .string("loopdy"), "status": .string(enabled ? "enabled" : "disabled"), "pinned_sha": .string(pin.revision)])
        }
        func cleanup() { registry.bind(deviceID: nil, authorizationEpoch: nil); try? FileManager.default.removeItem(at: root) }
    }
}
