import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class AgentEditorModel: Identifiable {
    enum Field: Hashable, Sendable {
        case name
        case role
        case summary
        case instructions
        case cloning
    }

    enum ValidationError: Swift.Error, Equatable {
        case requiredFields
        case saveInProgress
    }

    var draft: AgentDraft
    private(set) var fieldErrors: [Field: String] = [:]
    private(set) var avatarError: String?
    private(set) var saveError: String?
    private(set) var isSaving = false
    private(set) var hasUnconfirmedSave = false
    private(set) var pendingAvatar: PreparedAvatar?
    /// The avatar-creator look behind a pending companion avatar. Saving an
    /// agent with one also makes it that agent's animated chat companion.
    private(set) var selectedCompanionAppearance: CompanionAppearance?
    var selectedCompanionCharacter: CompanionCharacter? { selectedCompanionAppearance?.character }

    let id = UUID()

    let store: AgentDirectoryStore
    let profileCloneSupport: AgentProfileCreationCloneSupport
    private let processor: AvatarImageProcessor
    private var editingID: String?
    private let avatarDirectory: URL?
    private var savedDraft: AgentDraft
    private let isCurrent: @MainActor () -> Bool

    private init(
        editingID: String?,
        draft: AgentDraft,
        store: AgentDirectoryStore,
        processor: AvatarImageProcessor,
        avatarDirectory: URL?,
        profileCloneSupport: AgentProfileCreationCloneSupport,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.editingID = editingID
        self.draft = draft
        savedDraft = draft
        self.store = store
        self.processor = processor
        self.avatarDirectory = avatarDirectory
        self.profileCloneSupport = profileCloneSupport
        self.isCurrent = isCurrent
    }

    static func creating(
        store: AgentDirectoryStore,
        processor: AvatarImageProcessor,
        avatarDirectory: URL? = nil,
        profileCloneSupport: AgentProfileCreationCloneSupport = .unavailable(
            "Native profile creation options are not available on this connection."
        ),
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) -> AgentEditorModel {
        var draft = AgentDraft(name: "", role: "", summary: "", instructions: "", avatarFileName: nil, isDefault: false)
        // New agents start as a copy of the default agent's setup (skills,
        // memories, settings) unless unchecked in Advanced. Name, role,
        // about and instructions still come from this editor.
        if profileCloneSupport.unavailableReason == nil {
            draft.cloneSourceProfileID = store.profiles.first(where: \.isDefault)?.id
        }
        return AgentEditorModel(
            editingID: nil,
            draft: draft,
            store: store,
            processor: processor,
            avatarDirectory: avatarDirectory ?? store.avatarDirectory,
            profileCloneSupport: profileCloneSupport,
            isCurrent: isCurrent
        )
    }

    static func editing(
        _ profile: AgentProfile,
        store: AgentDirectoryStore,
        processor: AvatarImageProcessor,
        avatarDirectory: URL? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) -> AgentEditorModel {
        AgentEditorModel(
            editingID: profile.id,
            draft: AgentDraft(
                name: profile.name,
                role: profile.role,
                summary: profile.summary,
                instructions: profile.instructions,
                avatarFileName: profile.avatarFileName,
                avatar: profile.avatar,
                isDefault: profile.isDefault
            ),
            store: store,
            processor: processor,
            avatarDirectory: avatarDirectory ?? store.avatarDirectory,
            profileCloneSupport: .unavailable("Profile cloning is available only while creating an agent."),
            isCurrent: isCurrent
        )
    }

    var isEditing: Bool { editingID != nil }
    var editingAgentID: String? { editingID }
    var isCurrentContext: Bool { isCurrent() }

    var hasUnsavedChanges: Bool {
        pendingAvatar != nil
            || draft.name != savedDraft.name
            || draft.role != savedDraft.role
            || draft.summary != savedDraft.summary
            || draft.instructions != savedDraft.instructions
            || draft.avatarFileName != savedDraft.avatarFileName
            || draft.avatar != savedDraft.avatar
            || draft.removesAvatar != savedDraft.removesAvatar
            || draft.isDefault != savedDraft.isDefault
            || draft.cloneSourceProfileID != savedDraft.cloneSourceProfileID
            || draft.skipBundledSkills != savedDraft.skipBundledSkills
    }

    var handlePreview: String {
        AgentHandle.unique(base: draft.name, excluding: editingID, profiles: store.profiles)
    }

    var cloneSources: [AgentProfile] {
        guard !isEditing else { return [] }
        return store.profiles.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Display name of the agent this new one starts as a copy of.
    var cloneSourceName: String? {
        guard !isEditing, let id = draft.cloneSourceProfileID else { return nil }
        return store.profiles.first { $0.id == id }?.name
    }

    func selectCloneSource(_ profileID: String?) {
        draft.cloneSourceProfileID = profileID
        if profileID != nil { draft.skipBundledSkills = false }
    }

    func setSkipBundledSkills(_ enabled: Bool) {
        draft.skipBundledSkills = enabled
        if enabled { draft.cloneSourceProfileID = nil }
    }

    /// The Agent Studio starter last applied to this new-agent draft.
    private(set) var appliedStarterID: String?

    /// Prefills the local draft from a starter. Fields the user already changed
    /// are kept; only empty fields or values from the previous starter are replaced.
    func applyStarter(_ starter: AgentStudioStarter) {
        guard !isEditing else { return }
        let previous = AgentStudioStarter.all.first { $0.id == appliedStarterID } ?? .blank
        func merged(_ current: String, previous: String, next: String) -> String {
            current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || current == previous ? next : current
        }
        draft.name = merged(draft.name, previous: previous.name, next: starter.name)
        draft.role = merged(draft.role, previous: previous.role, next: starter.role)
        draft.summary = merged(draft.summary, previous: previous.summary, next: starter.summary)
        draft.instructions = merged(draft.instructions, previous: previous.instructions, next: starter.instructions)
        appliedStarterID = starter.id
        let filled: [(Field, String)] = [
            (.name, draft.name), (.role, draft.role), (.summary, draft.summary), (.instructions, draft.instructions)
        ]
        for (field, value) in filled where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors[field] = nil
        }
    }

    var avatarURL: URL? {
        guard let avatarDirectory, let fileName = draft.avatarFileName, !fileName.isEmpty else {
            return nil
        }
        return avatarDirectory.appending(path: fileName, directoryHint: .notDirectory)
    }

    func importAvatar(data: Data) async throws {
        try await prepareAvatar(data: data, companionAppearance: nil)
    }

    func importCompanionAvatar(data: Data, appearance: CompanionAppearance) async throws {
        try await prepareAvatar(data: data, companionAppearance: appearance)
    }

    private func prepareAvatar(
        data: Data,
        companionAppearance: CompanionAppearance?
    ) async throws {
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        do {
            let preparedAvatar = try processor.prepare(data: data)
            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            pendingAvatar = preparedAvatar
            selectedCompanionAppearance = companionAppearance
            draft.removesAvatar = false
            avatarError = nil
        } catch let error as AvatarImageProcessor.Error {
            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            avatarError = recoveryMessage(for: error)
            throw error
        }
    }

    func cancelAvatarSelection() async {
        pendingAvatar = nil
        selectedCompanionAppearance = nil
        avatarError = nil
    }

    func removeAvatar() {
        pendingAvatar = nil
        selectedCompanionAppearance = nil
        draft.avatarFileName = nil
        draft.avatar = nil
        draft.removesAvatar = true
        avatarError = nil
    }

    func reportAvatarLoadFailure() {
        guard isCurrent() else { return }
        avatarError = "We couldn’t read that photo. Choose a PNG, JPEG, or HEIF image and try again."
    }

    func reportCompanionAvatarRenderFailure() {
        guard isCurrent() else { return }
        avatarError = "We couldn’t prepare that companion avatar. Choose it again or use a photo."
    }

    func save() async throws -> AgentProfile {
        guard !isSaving else { throw ValidationError.saveInProgress }
        guard !hasUnconfirmedSave else { throw WorkspaceClientError.outcomeUnknown }
        guard isCurrent() else {
            saveError = "The host connection changed. Your edits are still here. Reopen this agent before saving."
            throw CancellationError()
        }
        guard validate() else { throw ValidationError.requiredFields }
        isSaving = true
        saveError = nil
        let oldFileName = draft.avatarFileName
        let requestedAvatarRemoval = draft.removesAvatar
        var storedFileName: String?
        var savedDraft = draft

        do {
            if let pendingAvatar {
                guard let avatarDirectory else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let fileName = try processor.store(pendingAvatar, in: avatarDirectory)
                storedFileName = fileName
                savedDraft.avatarFileName = fileName
                savedDraft.avatar = try AgentAvatar(preparedAvatar: pendingAvatar)
                savedDraft.removesAvatar = false
            }
            let profile: AgentProfile
            if let editingID {
                profile = try await store.update(id: editingID, draft: savedDraft)
            } else {
                profile = try await store.create(savedDraft)
            }
            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            editingID = profile.id
            adopt(profile, removesAvatar: false)
            pendingAvatar = nil
            isSaving = false
            return profile
        } catch {
            if let storedFileName, let avatarDirectory {
                try? FileManager.default.removeItem(at: avatarDirectory.appending(path: storedFileName))
            }
            if !isCurrent() || error is CancellationError {
                saveError = "The host connection changed. This editor cannot confirm the save."
            } else if let partial = error as? AgentDirectoryPartialMutationError {
                editingID = partial.committedProfile.id
                adopt(
                    partial.committedProfile,
                    removesAvatar: requestedAvatarRemoval && partial.unappliedFields.contains(.avatar)
                )
                if partial.unappliedFields.contains(.name) { draft.name = savedDraft.name }
                if partial.unappliedFields.contains(.role) { draft.role = savedDraft.role }
                if partial.unappliedFields.contains(.summary) { draft.summary = savedDraft.summary }
                if partial.unappliedFields.contains(.instructions) { draft.instructions = savedDraft.instructions }
                hasUnconfirmedSave = partial.isOutcomeUncertain
                saveError = partial.isOutcomeUncertain
                    ? "The agent exists, but some changes could not be confirmed. Reopen it to review the current state before saving again."
                    : "The agent was saved, but some changes were not. Your remaining edits are still here, so you can try again."
            } else {
                draft.avatarFileName = oldFileName
                hasUnconfirmedSave = (error as? WorkspaceClientError) == .outcomeUnknown
                saveError = hasUnconfirmedSave
                    ? "Hermes may have saved this agent. Refresh Agents and review its current state before trying again."
                    : (error as? WorkspaceClientError)?.localizedDescription
                        ?? "We couldn’t save this agent. Your changes are still here, so you can try again."
            }
            isSaving = false
            throw error
        }
    }

    private func adopt(_ profile: AgentProfile, removesAvatar: Bool) {
        draft = AgentDraft(
            name: profile.name,
            role: profile.role,
            summary: profile.summary,
            instructions: profile.instructions,
            avatarFileName: profile.avatarFileName,
            avatar: profile.avatar,
            removesAvatar: removesAvatar,
            isDefault: profile.isDefault,
            cloneSourceProfileID: nil,
            skipBundledSkills: false
        )
        savedDraft = draft
        savedDraft.removesAvatar = false
    }

    private func validate() -> Bool {
        fieldErrors = [:]
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors[.name] = "Enter a display name."
        }
        if draft.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors[.role] = "Enter a role or title."
        }
        if draft.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors[.summary] = "Enter a description."
        }
        if draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors[.instructions] = "Enter instructions."
        }
        if draft.cloneSourceProfileID != nil || draft.skipBundledSkills,
           let reason = profileCloneSupport.unavailableReason {
            fieldErrors[.cloning] = reason
        } else if let source = draft.cloneSourceProfileID {
            if draft.skipBundledSkills {
                fieldErrors[.cloning] = "Cloning includes the source’s skills. Choose Start fresh to skip bundled skills."
            } else if !cloneSources.contains(where: { $0.id == source }) {
                fieldErrors[.cloning] = "That source agent is no longer available. Refresh Agents and choose again."
            }
        }
        return fieldErrors.isEmpty
    }

    private func recoveryMessage(for error: AvatarImageProcessor.Error) -> String {
        switch error {
        case .invalidData, .unsupportedFormat:
            "Choose a PNG, JPEG, or HEIF image and try again."
        case .sourceTooLarge, .outputTooLarge:
            "That image is still too large after preparation. Choose a smaller photo and try again."
        case .processingFailed:
            "We couldn’t prepare that image. Choose another photo and try again."
        }
    }
}

private extension AgentAvatar {
    init(preparedAvatar avatar: PreparedAvatar) throws {
        let mimeType: String
        switch avatar.fileExtension {
        case "png":
            mimeType = "image/png"
        case "jpg", "jpeg":
            mimeType = "image/jpeg"
        case "webp":
            mimeType = "image/webp"
        default:
            throw AvatarImageProcessor.Error.unsupportedFormat
        }
        self.init(
            mimeType: mimeType,
            byteCount: avatar.data.count,
            sha256: LoopdyLinkBase64URL.encode(Data(SHA256.hash(data: avatar.data))),
            dataURL: "data:\(mimeType);base64,\(avatar.data.base64EncodedString())"
        )
    }
}
