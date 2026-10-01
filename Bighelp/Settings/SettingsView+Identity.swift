import PhotosUI
import SwiftUI
import UIKit

extension SettingsView {
    var localIdentity: some View {
        Section {
            HStack(spacing: BighelpTokens.space12) {
                // Your photo is the button that changes it.
                PhotosPicker(selection: $photoSelection, matching: .images) {
                    AvatarView(
                        stableID: UserIdentity.stableID,
                        displayName: userIdentity.identity.displayName,
                        imageURL: userIdentity.avatarURL(),
                        size: 52,
                        kind: .person
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: isImportingAvatar ? "hourglass" : "camera.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.actionForeground)
                            .frame(width: 20, height: 20)
                            .background(theme.action, in: .circle)
                            .overlay(Circle().strokeBorder(theme.surface, lineWidth: 2))
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSavingName || isImportingAvatar)
                .accessibilityLabel(isImportingAvatar ? "Saving photo" : "Change your photo")
                .accessibilityIdentifier("profile.choose-avatar")
                TextField("Your name", text: $displayNameDraft)
                    .textContentType(.name)
                    .focused($isDisplayNameFocused)
                    .submitLabel(.done)
                    .onSubmit(saveDisplayName)
                    .accessibilityIdentifier("profile.display-name")
            }
            if canSaveDisplayName || isSavingName {
                Button(action: saveDisplayName) {
                    HStack(spacing: BighelpTokens.space8) {
                        Text(isSavingName ? "Saving name…" : (isRemovingName ? "Remove name" : "Save name"))
                        if isSavingName {
                            ProgressView()
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                }
                .disabled(!canSaveDisplayName)
                .accessibilityLabel(isRemovingName ? "Remove name" : "Save name")
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
            if let avatarError {
                Text(avatarError)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("Your name and photo show on your messages. Your agents see your name, so they know who they're talking with.")
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
            // Counts what you see, so accented and emoji names get the full length.
            if name.count > UserIdentity.maximumNameLength {
                displayNameDraft = String(name.prefix(UserIdentity.maximumNameLength))
                return
            }
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
        let draft = UserIdentity.savedName(displayNameDraft)
        return !isSavingName && !isImportingAvatar && draft != userIdentity.identity.name
            && (!draft.isEmpty || linkAccount?.credentials == nil)
    }

    /// Clearing the field and saving removes your name, so agents no longer get one.
    private var isRemovingName: Bool {
        UserIdentity.savedName(displayNameDraft).isEmpty && !userIdentity.identity.name.isEmpty
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
                let removed = userIdentity.identity.name.isEmpty
                nameSaveStatus = displayNameDraft == displayNameBaseline
                    ? (removed ? "Name removed." : "Name saved.")
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
