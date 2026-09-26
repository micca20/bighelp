import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ProfileLifecycleStoreTests {
    enum Operation: CaseIterable {
        case renameReview, deleteReview, activationReview, export, importArchive, description, setup, onboarding

        func run(_ store: ProfileLifecycleStore) async {
            switch self {
            case .renameReview: await store.prepareRename(newName: "renamed")
            case .deleteReview: await store.prepareDelete()
            case .activationReview: await store.prepareDefaultActivation()
            case .export: await store.exportProfile(outputPath: "/fixture/archive.tar.gz")
            case .importArchive: await store.importReviewedProfile()
            case .description: await store.describeAutomatically(overwrite: true)
            case .setup: await store.loadSetupCommand()
            case .onboarding: await store.saveOnboardingFacts()
            }
        }
    }
    enum Failure: CaseIterable {
        case ordinary, localized, cancellation
        var error: any Error {
            switch self {
            case .ordinary: LifecycleProbeError.failed
            case .localized: HermesProfileLifecycleError.rejected("Host rejected the exact request")
            case .cancellation: CancellationError()
            }
        }
        var message: String? {
            switch self {
            case .ordinary: "Hermes could not confirm this profile operation. Refresh before trying it again."
            case .localized: "Host rejected the exact request"
            case .cancellation: nil
            }
        }
    }

    @Test(arguments: Operation.allCases, Failure.allCases)
    func operationErrorsKeepTheirPolicyAndReleaseBusy(operation: Operation, failure: Failure) async {
        let fixture = ProfileLifecycleFixture()
        let store = makeStore(fixture)
        store.prepareImport(archivePath: "/fixture/archive.tar.gz", requestedProfileID: "imported")
        fixture.failure = failure.error
        await operation.run(store)
        #expect(store.errorMessage == failure.message)
        #expect(store.successMessage == nil)
        #expect(store.operationTitle == nil && !store.isBusy)
        #expect(fixture.calls.count == 1)
    }

    @Test func reviewedOperationPreconditionsDoNotClearAnExistingFailure() async {
        let fixture = ProfileLifecycleFixture()
        let store = makeStore(fixture)
        fixture.failure = LifecycleProbeError.failed
        await store.loadSetupCommand()
        let failure = store.errorMessage
        await store.renameReviewedProfile()
        await store.deleteReviewedProfile()
        await store.activateReviewedDefault()
        await store.importReviewedProfile()
        #expect(store.errorMessage == failure)
        #expect(fixture.calls == ["setup"])
        #expect(!store.isBusy)
    }

    @Test func busyOperationRejectsASecondRequestAndKeepsItsTitle() async throws {
        let fixture = ProfileLifecycleFixture()
        let store = makeStore(fixture)
        let gate = AsyncOperationTestGate()
        fixture.beforeRequest = { try await gate.wait() }
        let task = Task { await store.exportProfile(outputPath: "/fixture/archive.tar.gz") }
        defer { gate.finish(); task.cancel() }
        for _ in 0..<100 where !gate.entered { await Task.yield() }
        try #require(gate.entered)
        #expect(store.operationTitle == "Exporting profile archive")
        await store.loadSetupCommand()
        #expect(fixture.calls == ["export"])
        #expect(store.operationTitle == "Exporting profile archive")
        gate.finish()
        await task.value
        #expect(store.archiveExport?.archivePath == "/fixture/archive.tar.gz")
        #expect(store.operationTitle == nil && !store.isBusy)
    }

    @Test(arguments: [false, true], [false, true])
    func retiredOrReownedOperationCannotPublishItsLateResult(retire: Bool, fail: Bool) async throws {
        let fixture = ProfileLifecycleFixture()
        let store = makeStore(fixture)
        let gate = AsyncOperationTestGate()
        fixture.beforeRequest = { try await gate.wait() }
        let task = Task { await store.exportProfile(outputPath: "/fixture/archive.tar.gz") }
        defer { gate.finish(); task.cancel() }
        for _ in 0..<100 where !gate.entered { await Task.yield() }
        try #require(gate.entered)
        if retire { store.retire() } else { fixture.ownsScope = false }
        gate.finish(error: fail ? LifecycleProbeError.failed : nil)
        await task.value
        #expect(store.archiveExport == nil)
        #expect(store.errorMessage == nil && store.successMessage == nil)
        #expect(store.operationTitle == nil && !store.isBusy)
        #expect(fixture.calls == ["export"])
    }

    @Test(arguments: [Operation.importArchive, .description, .onboarding])
    func acceptedWriteKeepsReadbackWhenSharedRefreshFails(operation: Operation) async {
        let fixture = ProfileLifecycleFixture()
        var refreshCalls = 0
        let store = makeStore(fixture) { _ in
            refreshCalls += 1
            throw LifecycleProbeError.failed
        }
        store.prepareImport(archivePath: "/fixture/archive.tar.gz", requestedProfileID: "imported")
        await operation.run(store)
        #expect(refreshCalls == 1)
        #expect(store.catalog == fixture.catalogValue)
        #expect(store.successMessage == nil)
        #expect(store.errorMessage?.contains("Hermes confirmed") == true)
        #expect(store.errorMessage?.contains("but shared app state did not refresh") == true)
        #expect(!store.isBusy)
        if operation == .importArchive {
            #expect(store.importReview == nil)
            let calls = fixture.calls
            await store.importReviewedProfile()
            #expect(fixture.calls == calls)
        } else {
            #expect(fixture.calls.last == "catalog")
        }
    }

    private func makeStore(
        _ fixture: ProfileLifecycleFixture,
        changed: @escaping @MainActor (HermesProfileLifecycleResult) async throws -> Void = { _ in }
    ) -> ProfileLifecycleStore {
        ProfileLifecycleStore(hostName: "Fixture", selectedProfileID: "default", client: fixture,
                              retireProfileOwnership: { _ in }, onProfileChanged: changed)
    }
}

private enum LifecycleProbeError: Error { case failed }

@MainActor
private final class ProfileLifecycleFixture: HermesProfileLifecycleManaging {
    var ownsScope = true
    var failure: (any Error)?
    var beforeRequest: (() async throws -> Void)?
    var calls: [String] = []
    let profile = HermesProfileLifecycleItem(
        id: "default", displayName: "Default", description: "Fixture", descriptionIsAutomatic: false,
        isDefaultProfile: true, providerID: nil, modelID: nil, skillCount: 0, hasEnvironment: false,
        hasAlias: false, gatewayRunning: true, distributionName: nil, distributionVersion: nil, distributionSource: nil
    )
    var catalogValue: HermesProfileLifecycleCatalog {
        .init(selectedProfileID: "default", profiles: [profile],
              active: .init(activeProfileID: "default", currentProfileID: "default"))
    }
    private func request(_ name: String) async throws {
        calls.append(name)
        try await beforeRequest?()
        if let failure { throw failure }
    }
    func catalog(selectedProfileID: String) async throws -> HermesProfileLifecycleCatalog {
        try await request("catalog")
        return catalogValue
    }
    func prepareRename(profileID: String, newName: String) async throws -> HermesProfileRenameReview {
        try await request("renameReview")
        throw LifecycleProbeError.failed
    }
    func prepareDelete(profileID: String) async throws -> HermesProfileDeleteReview {
        try await request("deleteReview")
        throw LifecycleProbeError.failed
    }
    func prepareDefaultActivation(profileID: String) async throws -> HermesProfileActivationReview {
        try await request("activationReview")
        throw LifecycleProbeError.failed
    }
    func rename(reviewed: HermesProfileRenameReview, retireProfileOwnership: @MainActor (HermesProfileLifecycleChange) async throws -> Void) async throws -> HermesProfileLifecycleResult {
        throw LifecycleProbeError.failed
    }
    func delete(reviewed: HermesProfileDeleteReview, retireProfileOwnership: @MainActor (HermesProfileLifecycleChange) async throws -> Void) async throws -> HermesProfileLifecycleResult {
        throw LifecycleProbeError.failed
    }
    func activateDefault(reviewed: HermesProfileActivationReview, retireProfileOwnership: @MainActor (HermesProfileLifecycleChange) async throws -> Void) async throws -> HermesProfileLifecycleResult {
        throw LifecycleProbeError.failed
    }
    func exportProfile(profileID: String, outputPath: String?) async throws -> HermesProfileArchiveExport {
        try await request("export")
        return .init(profileID: profileID, archivePath: outputPath ?? "/fixture/archive.tar.gz")
    }
    func prepareImport(archivePath: String, requestedProfileID: String?) throws -> HermesProfileArchiveImportReview {
        .init(archivePath: archivePath, requestedProfileID: requestedProfileID)
    }
    func importProfile(reviewed: HermesProfileArchiveImportReview) async throws -> HermesProfileLifecycleResult {
        try await request("import")
        return .init(change: .imported(profileID: "default"), catalog: catalogValue, profile: profile)
    }
    func describeAutomatically(profileID: String, overwrite: Bool) async throws -> HermesProfileAutoDescriptionResult {
        try await request("description")
        return .init(profileID: profileID, succeeded: true, reason: "", description: "New description", profile: profile)
    }
    func setupCommand(profileID: String) async throws -> HermesProfileSetupCommand {
        try await request("setup")
        return .init(profileID: profileID, command: "hermes setup")
    }
    func rememberOnboardingFacts(_ facts: HermesOnboardingFacts, profileID: String) async throws -> HermesOnboardingFactsReceipt {
        try await request("onboarding")
        return .init(saved: true, profileID: profileID, target: "user")
    }
}
