import PhotosUI
import SwiftUI
import UIKit

extension SettingsView {
    var localIdentity: some View {
        let avatarTitle = isImportingAvatar ? "Saving avatar…" : "Choose avatar"
        return Section {
            HStack(spacing: BighelpTokens.space12) {
                AvatarView(
                    stableID: UserIdentity.stableID,
                    displayName: userIdentity.identity.name,
                    imageURL: userIdentity.avatarURL(),
                    size: 52,
                    kind: .person
                )
                .accessibilityHidden(true)
                TextField("Display name", text: $displayNameDraft)
                    .textContentType(.name)
                    .focused($isDisplayNameFocused)
                    .submitLabel(.done)
                    .onSubmit(saveDisplayName)
                    .accessibilityIdentifier("profile.display-name")
            }
            if canSaveDisplayName || isSavingName {
                Button(action: saveDisplayName) {
                    HStack(spacing: BighelpTokens.space8) {
                        Text(isSavingName ? "Saving name…" : "Save name")
                        if isSavingName {
                            ProgressView()
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                }
                .disabled(!canSaveDisplayName)
                .accessibilityLabel("Save name")
                .accessibilityValue(isSavingName ? "Saving" : "")
                .accessibilityIdentifier("profile.save-name")
            }
            if let nameSaveError {
                Text(nameSaveError)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("profile.name-save-error")
            } else if let nameSaveStatus {
                Text(nameSaveStatus)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("profile.name-save-status")
            }
            PhotosPicker(selection: $photoSelection, matching: .images) {
                Label(avatarTitle, systemImage: "photo")
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            }
            .disabled(isSavingName || isImportingAvatar)
            .accessibilityIdentifier("profile.choose-avatar")
            if let avatarError {
                Text(avatarError)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Your profile")
        } footer: {
            Text("Your name and photo appear on your messages.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
        .onChange(of: userIdentity.identity.name, initial: true) { _, name in
            if displayNameDraft == displayNameBaseline {
                displayNameDraft = name
            }
            displayNameBaseline = name
        }
        .onChange(of: linkAccount?.accountGeneration) { _, _ in
            displayNameDraft = userIdentity.identity.name
            displayNameBaseline = userIdentity.identity.name
            nameSaveError = nil
            nameSaveStatus = nil
            avatarError = nil
        }
        .onChange(of: displayNameDraft) { _, name in
            if name != displayNameBaseline {
                nameSaveError = nil
                nameSaveStatus = nil
            }
        }
        .onChange(of: photoSelection) { _, selection in
            guard let selection else { return }
            importAvatar(selection)
        }
    }

    private var canSaveDisplayName: Bool {
        !isSavingName && !isImportingAvatar
            && !displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && displayNameDraft != userIdentity.identity.name
    }

    private func saveDisplayName() {
        guard canSaveDisplayName else { return }
        isDisplayNameFocused = false
        let submittedName = displayNameDraft
        let mutation = userIdentity.mutationGeneration
        let accountGeneration = linkAccount?.accountGeneration
        let credentials = linkAccount?.credentials
        isSavingName = true
        nameSaveError = nil
        nameSaveStatus = nil
        Task {
            defer { isSavingName = false }
            do {
                guard userIdentity.mutationGeneration == mutation,
                      linkAccount?.accountGeneration == accountGeneration,
                      linkAccount?.credentials == credentials else { throw CancellationError() }
                try await userIdentity.saveDisplayName(submittedName, to: linkAccount)
                guard linkAccount?.accountGeneration == accountGeneration,
                      linkAccount?.credentials == credentials else { return }
                displayNameBaseline = userIdentity.identity.name
                if displayNameDraft == submittedName {
                    displayNameDraft = displayNameBaseline
                }
                nameSaveStatus = displayNameDraft == displayNameBaseline
                    ? "Name saved."
                    : "Name saved. You have unsaved changes."
            } catch {
                guard linkAccount?.accountGeneration == accountGeneration,
                      linkAccount?.credentials == credentials else { return }
                nameSaveError = "We couldn’t save your name. Your draft is still here. Try again."
            }
        }
    }

    private func importAvatar(_ selection: PhotosPickerItem) {
        guard !isSavingName, !isImportingAvatar else { return }
        let mutation = userIdentity.mutationGeneration
        let accountGeneration = linkAccount?.accountGeneration
        let credentials = linkAccount?.credentials
        isImportingAvatar = true
        avatarError = nil
        Task {
            defer {
                isImportingAvatar = false
                photoSelection = nil
            }
            do {
                guard let data = try await selection.loadTransferable(type: Data.self) else {
                    avatarError = "We couldn’t read that photo. Choose a PNG, JPEG, or HEIF image and try again."
                    return
                }
                try Task.checkCancellation()
                guard userIdentity.mutationGeneration == mutation,
                      linkAccount?.accountGeneration == accountGeneration,
                      linkAccount?.credentials == credentials else { throw CancellationError() }
                let avatar = try AvatarImageProcessor().prepare(data: data)
                try await userIdentity.saveAvatar(avatar, to: linkAccount)
            } catch {
                guard linkAccount?.accountGeneration == accountGeneration,
                      linkAccount?.credentials == credentials else { return }
                avatarError = "We couldn’t save that photo. Choose a PNG, JPEG, or HEIF image and try again."
            }
        }
    }

    func loadAccountProfileIfAvailable() async {
        guard let linkAccount else { return }
        await userIdentity.hydrateAccountProfile(from: linkAccount)
    }
}
