import Foundation
import Observation

@MainActor @Observable
final class ProfileLifecycleStore {
    let hostName: String
    private(set) var selectedProfileID: String
    private(set) var catalog: HermesProfileLifecycleCatalog?
    private(set) var renameReview: HermesProfileRenameReview?
    private(set) var deleteReview: HermesProfileDeleteReview?
    private(set) var activationReview: HermesProfileActivationReview?
    private(set) var importReview: HermesProfileArchiveImportReview?
    private(set) var archiveExport: HermesProfileArchiveExport?
    private(set) var setupCommand: HermesProfileSetupCommand?
    private(set) var isLoading = false
    private(set) var operationTitle: String?
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    private(set) var isRetired = false

    var onboardingFacts = HermesOnboardingFacts()

    @ObservationIgnored private let client: any HermesProfileLifecycleManaging
    @ObservationIgnored private let retireProfileOwnership: @MainActor (HermesProfileLifecycleChange) async throws -> Void
    @ObservationIgnored private let onProfileChanged: @MainActor (HermesProfileLifecycleResult) async throws -> Void
    @ObservationIgnored private var generation = UUID()

    init(
        hostName: String,
        selectedProfileID: String,
        client: any HermesProfileLifecycleManaging,
        retireProfileOwnership: @escaping @MainActor (HermesProfileLifecycleChange) async throws -> Void,
        onProfileChanged: @escaping @MainActor (HermesProfileLifecycleResult) async throws -> Void
    ) {
        self.hostName = hostName
        self.selectedProfileID = selectedProfileID
        self.client = client
        self.retireProfileOwnership = retireProfileOwnership
        self.onProfileChanged = onProfileChanged
    }

    var ownsScope: Bool { !isRetired && client.ownsScope }
    var isBusy: Bool { isLoading || operationTitle != nil }
    var selectedProfile: HermesProfileLifecycleItem? {
        catalog?.profiles.first { $0.id.utf8.elementsEqual(selectedProfileID.utf8) }
    }

    func load() async {
        guard ownsScope, !isBusy else { return }
        let request = UUID()
        generation = request
        isLoading = true
        errorMessage = nil
        successMessage = nil
        clearReviews()
        defer { if generation == request { isLoading = false } }
        do {
            let value = try await client.catalog(selectedProfileID: selectedProfileID)
            guard canPublish(request) else { return }
            catalog = value
        } catch is CancellationError {
        } catch {
            guard canPublish(request) else { return }
            errorMessage = Self.message(error)
        }
    }

    func refresh() async {
        guard operationTitle == nil else { return }
        isLoading = false
        await load()
    }

    func select(_ profileID: String) async {
        guard ownsScope, !isBusy else { return }
        selectedProfileID = profileID
        setupCommand = nil
        archiveExport = nil
        clearReviews()
        await load()
    }

    func prepareRename(newName: String) async {
        await performProfileRequest("Preparing rename review") {
            let review = try await client.prepareRename(profileID: selectedProfileID, newName: newName)
            guard ownsScope else { return }
            renameReview = review
        }
    }

    func renameReviewedProfile() async {
        guard let review = renameReview else { return }
        await performProfileRequest("Renaming reviewed profile") {
            let result = try await client.rename(
                reviewed: review, retireProfileOwnership: retireProfileOwnership
            )
            guard ownsScope else { return }
            selectedProfileID = result.profile?.id ?? selectedProfileID
            catalog = result.catalog
            renameReview = nil
            do { try await onProfileChanged(result) }
            catch {
                errorMessage = "Hermes confirmed the rename, but shared app state did not refresh. Reopen Profiles; do not repeat the rename."
                return
            }
            guard ownsScope else { return }
            successMessage = "Hermes renamed the profile and the app refreshed its profile/session ownership."
        }
    }

    func prepareDelete() async {
        await performProfileRequest("Preparing deletion review") {
            let review = try await client.prepareDelete(profileID: selectedProfileID)
            guard ownsScope else { return }
            deleteReview = review
        }
    }

    func deleteReviewedProfile() async {
        guard let review = deleteReview else { return }
        await performProfileRequest("Deleting reviewed profile") {
            let result = try await client.delete(
                reviewed: review, retireProfileOwnership: retireProfileOwnership
            )
            guard ownsScope else { return }
            selectedProfileID = result.catalog.profiles.first(where: \.isDefaultProfile)?.id
                ?? result.catalog.profiles.first?.id ?? "default"
            catalog = result.catalog
            deleteReview = nil
            do { try await onProfileChanged(result) }
            catch {
                errorMessage = "Hermes confirmed the deletion, but shared app state did not refresh. Reopen Profiles; do not repeat the deletion."
                return
            }
            guard ownsScope else { return }
            successMessage = "Hermes deleted the reviewed profile and exact catalog readback confirmed its absence."
        }
    }

    func prepareDefaultActivation() async {
        await performProfileRequest("Preparing default-profile review") {
            let review = try await client.prepareDefaultActivation(profileID: selectedProfileID)
            guard ownsScope else { return }
            activationReview = review
        }
    }

    func activateReviewedDefault() async {
        guard let review = activationReview else { return }
        await performProfileRequest("Changing the sticky default") {
            let result = try await client.activateDefault(
                reviewed: review, retireProfileOwnership: retireProfileOwnership
            )
            guard ownsScope else { return }
            catalog = result.catalog
            activationReview = nil
            do { try await onProfileChanged(result) }
            catch {
                errorMessage = "Hermes confirmed the sticky default, but shared app state did not refresh. Reopen Profiles; do not repeat the change."
                return
            }
            guard ownsScope else { return }
            successMessage = "Hermes confirmed the new sticky default. The currently served profile was not retargeted."
        }
    }

    func exportProfile(outputPath: String?) async {
        await performProfileRequest("Exporting profile archive") {
            let result = try await client.exportProfile(profileID: selectedProfileID, outputPath: outputPath)
            guard ownsScope else { return }
            archiveExport = result
            successMessage = "Hermes created the profile archive on the host."
        }
    }

    func prepareImport(archivePath: String, requestedProfileID: String?) {
        guard ownsScope, !isBusy else { return }
        do {
            importReview = try client.prepareImport(
                archivePath: archivePath, requestedProfileID: requestedProfileID
            )
        } catch {
            errorMessage = Self.message(error)
        }
    }

    func importReviewedProfile() async {
        guard let review = importReview else { return }
        await performProfileRequest("Importing reviewed archive") {
            let result = try await client.importProfile(reviewed: review)
            guard ownsScope else { return }
            selectedProfileID = result.profile?.id ?? selectedProfileID
            catalog = result.catalog
            importReview = nil
            do { try await onProfileChanged(result) }
            catch {
                errorMessage = "Hermes confirmed the imported profile, but shared app state did not refresh. Reopen Profiles; do not repeat the import."
                return
            }
            guard ownsScope else { return }
            successMessage = "Hermes imported the archive and the exact profile appeared in a fresh catalog."
        }
    }

    func describeAutomatically(overwrite: Bool) async {
        await performProfileRequest("Generating profile description") {
            let result = try await client.describeAutomatically(
                profileID: selectedProfileID, overwrite: overwrite
            )
            guard ownsScope else { return }
            if result.succeeded {
                let refreshed = try await client.catalog(selectedProfileID: selectedProfileID)
                let change = HermesProfileLifecycleChange.descriptionChanged(profileID: selectedProfileID)
                let lifecycle = HermesProfileLifecycleResult(
                    change: change, catalog: refreshed, profile: result.profile
                )
                catalog = refreshed
                do { try await onProfileChanged(lifecycle) }
                catch {
                    errorMessage = "Hermes confirmed the generated description, but shared app state did not refresh. Reopen Profiles; do not generate it again."
                    return
                }
                guard ownsScope else { return }
                successMessage = "Hermes generated and confirmed the profile description."
            } else {
                errorMessage = result.reason.isEmpty
                    ? "Hermes did not generate a description. The existing description was preserved."
                    : result.reason
            }
        }
    }

    func loadSetupCommand() async {
        await performProfileRequest("Loading setup command") {
            let result = try await client.setupCommand(profileID: selectedProfileID)
            guard ownsScope else { return }
            setupCommand = result
        }
    }

    func saveOnboardingFacts() async {
        guard selectedProfileID == "default" else { return }
        await performProfileRequest("Saving onboarding facts") {
            let receipt = try await client.rememberOnboardingFacts(
                onboardingFacts, profileID: selectedProfileID
            )
            guard ownsScope, receipt.saved else { return }
            let refreshed = try await client.catalog(selectedProfileID: selectedProfileID)
            let result = HermesProfileLifecycleResult(
                change: .onboardingFactsSaved(profileID: receipt.profileID),
                catalog: refreshed,
                profile: refreshed.profiles.first { $0.id == receipt.profileID }
            )
            catalog = refreshed
            do { try await onProfileChanged(result) }
            catch {
                errorMessage = "Hermes confirmed the onboarding facts, but shared app state did not refresh. Reopen Profiles; do not save them again."
                return
            }
            guard ownsScope else { return }
            successMessage = "Hermes saved the agreed onboarding facts to the default profile’s user memory and verified the write."
        }
    }

    func clearRenameReview() { renameReview = nil }
    func clearDeleteReview() { deleteReview = nil }
    func clearActivationReview() { activationReview = nil }
    func clearImportReview() { importReview = nil }
    func clearArchiveExport() { archiveExport = nil }
    func clearMessages() { errorMessage = nil; successMessage = nil }

    func retire() {
        isRetired = true
        generation = UUID()
        catalog = nil
        clearReviews()
        archiveExport = nil
        setupCommand = nil
        isLoading = false
        operationTitle = nil
        clearMessages()
    }

    private func performProfileRequest(
        _ title: String,
        operation: @MainActor () async throws -> Void
    ) async {
        guard begin(title) else { return }
        defer { finish() }
        do {
            try await operation()
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    private func begin(_ title: String) -> Bool {
        guard ownsScope, !isBusy else { return false }
        operationTitle = title
        errorMessage = nil
        successMessage = nil
        return true
    }

    private func finish() { operationTitle = nil }
    private func clearReviews() {
        renameReview = nil
        deleteReview = nil
        activationReview = nil
        importReview = nil
    }
    private func canPublish(_ request: UUID) -> Bool {
        ownsScope && generation == request && !Task.isCancelled
    }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "Hermes could not confirm this profile operation. Refresh before trying it again."
    }
}
