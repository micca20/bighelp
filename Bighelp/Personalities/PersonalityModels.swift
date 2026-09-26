import Foundation
import Observation

enum PersonalityValidationError: Error, Equatable {
    case invalidName
    case invalidDescription
    case invalidPrompt
    case invalidTone
    case invalidStyle
}

struct PersonalityDefinition: Identifiable, Codable, Equatable, Sendable {
    let name: String
    let description: String
    let systemPrompt: String
    let tone: String
    let style: String
    let isBuiltIn: Bool
    let isCustomized: Bool

    var id: String { name }
    var canDelete: Bool { !isBuiltIn || isCustomized }
    var deleteLabel: String { isBuiltIn ? "Restore Built-in" : "Delete Personality" }
    var availableActions: [PersonalityAction] {
        canDelete ? [.use, .edit, .delete] : [.use, .edit]
    }

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case systemPrompt
        case tone
        case style
        case isBuiltIn = "builtIn"
        case isCustomized = "customized"
    }

    init(
        name: String,
        description: String,
        systemPrompt: String,
        tone: String,
        style: String,
        isBuiltIn: Bool,
        isCustomized: Bool
    ) {
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.tone = tone
        self.style = style
        self.isBuiltIn = isBuiltIn
        self.isCustomized = isCustomized
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let description = try container.decode(String.self, forKey: .description)
        let prompt = try container.decode(String.self, forKey: .systemPrompt)
        let tone = try container.decode(String.self, forKey: .tone)
        let style = try container.decode(String.self, forKey: .style)
        _ = try PersonalityDraft.validated(
            originalName: nil,
            name: name,
            description: description,
            systemPrompt: prompt,
            tone: tone,
            style: style
        )
        self.init(
            name: name,
            description: description,
            systemPrompt: prompt,
            tone: tone,
            style: style,
            isBuiltIn: try container.decode(Bool.self, forKey: .isBuiltIn),
            isCustomized: try container.decode(Bool.self, forKey: .isCustomized)
        )
    }
}

enum PersonalityAction: String, CaseIterable, Equatable, Sendable {
    case use
    case edit
    case delete
}

struct PersonalityDraft: Codable, Equatable, Sendable {
    let originalName: String?
    let name: String
    let description: String
    let systemPrompt: String
    let tone: String
    let style: String

    static func validated(
        originalName: String?,
        name: String,
        description: String,
        systemPrompt: String,
        tone: String,
        style: String
    ) throws -> PersonalityDraft {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let neutral = ["", "none", "default", "neutral"]
        guard
            (1...64).contains(normalizedName.count),
            !neutral.contains(normalizedName),
            normalizedName.allSatisfy({
                $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-")
            })
        else { throw PersonalityValidationError.invalidName }
        let normalizedDescription = try bounded(
            description,
            maximum: 240,
            error: .invalidDescription,
            allowsEmpty: true
        )
        let normalizedPrompt = try bounded(
            systemPrompt,
            maximum: 20_000,
            error: .invalidPrompt,
            allowsEmpty: false
        )
        let normalizedTone = try bounded(
            tone,
            maximum: 240,
            error: .invalidTone,
            allowsEmpty: true
        )
        let normalizedStyle = try bounded(
            style,
            maximum: 240,
            error: .invalidStyle,
            allowsEmpty: true
        )
        let normalizedOriginal = originalName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalizedOriginal, !normalizedOriginal.isEmpty,
           !normalizedOriginal.allSatisfy({
               $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-")
           }) {
            throw PersonalityValidationError.invalidName
        }
        return PersonalityDraft(
            originalName: normalizedOriginal,
            name: normalizedName,
            description: normalizedDescription,
            systemPrompt: normalizedPrompt,
            tone: normalizedTone,
            style: normalizedStyle
        )
    }

    private static func bounded(
        _ value: String,
        maximum: Int,
        error: PersonalityValidationError,
        allowsEmpty: Bool
    ) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            (allowsEmpty || !normalized.isEmpty),
            normalized.count <= maximum,
            !normalized.unicodeScalars.contains(where: { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    && scalar != "\n"
                    && scalar != "\r"
                    && scalar != "\t"
            })
        else { throw error }
        return normalized
    }
}

struct PersonalityCatalog: Equatable, Sendable {
    let revision: Int
    let activeName: String
    let personalities: [PersonalityDefinition]
}

struct PersonalityMutation: Equatable, Sendable {
    enum Action: String, Codable, Equatable, Sendable {
        case save
        case delete
        case activate
    }

    let action: Action
    let expectedRevision: Int
    let name: String?
    let draft: PersonalityDraft?
}

@MainActor
protocol PersonalityClient: AnyObject {
    func load() async throws -> PersonalityCatalog
    func mutate(_ request: PersonalityMutation) async throws -> PersonalityCatalog
}

enum PersonalityLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed
}

@MainActor
@Observable
final class PersonalityStore {
    private(set) var catalog: PersonalityCatalog?
    private(set) var loadState: PersonalityLoadState = .idle
    private(set) var errorMessage: String?
    private(set) var isSaving = false
    private let client: any PersonalityClient
    private var accountGeneration: UInt64 = 0

    var personalities: [PersonalityDefinition] {
        catalog?.personalities.sorted { lhs, rhs in
            if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        } ?? []
    }

    init(client: any PersonalityClient) {
        self.client = client
    }

    func load() async {
        let generation = accountGeneration
        loadState = .loading
        errorMessage = nil
        do {
            let loadedCatalog = try await client.load()
            guard generation == accountGeneration else { return }
            catalog = loadedCatalog
            loadState = .loaded
        } catch {
            guard generation == accountGeneration else { return }
            loadState = .failed
            errorMessage = "Personalities could not be loaded. Try again."
        }
    }

    func resetForAccountBoundary() {
        accountGeneration &+= 1
        catalog = nil
        loadState = .idle
        errorMessage = nil
        isSaving = false
    }

    func save(_ draft: PersonalityDraft) async {
        await mutate(action: .save, name: draft.name, draft: draft)
    }

    func delete(name: String) async {
        await mutate(action: .delete, name: name, draft: nil)
    }

    func activate(name: String?) async {
        await mutate(action: .activate, name: name, draft: nil)
    }

    private func mutate(
        action: PersonalityMutation.Action,
        name: String?,
        draft: PersonalityDraft?
    ) async {
        guard let revision = catalog?.revision, !isSaving else { return }
        let generation = accountGeneration
        isSaving = true
        errorMessage = nil
        defer {
            if generation == accountGeneration {
                isSaving = false
            }
        }
        do {
            let validatedDraft: PersonalityDraft?
            if let draft {
                validatedDraft = try PersonalityDraft.validated(
                    originalName: draft.originalName,
                    name: draft.name,
                    description: draft.description,
                    systemPrompt: draft.systemPrompt,
                    tone: draft.tone,
                    style: draft.style
                )
            } else {
                validatedDraft = nil
            }
            let updatedCatalog = try await client.mutate(
                PersonalityMutation(
                    action: action,
                    expectedRevision: revision,
                    name: name,
                    draft: validatedDraft
                )
            )
            guard generation == accountGeneration else { return }
            catalog = updatedCatalog
            loadState = .loaded
        } catch is PersonalityValidationError {
            guard generation == accountGeneration else { return }
            errorMessage = "Check the personality name and instructions, then try again."
        } catch {
            guard generation == accountGeneration else { return }
            errorMessage = "That personality changed elsewhere. Reload and try again."
        }
    }
}

@MainActor
final class FixturePersonalityClient: PersonalityClient {
    private var catalog = PersonalityCatalog(
        revision: 1,
        activeName: "helpful",
        personalities: [
            PersonalityDefinition(
                name: "helpful",
                description: "Friendly and useful",
                systemPrompt: "You are a helpful, friendly AI assistant.",
                tone: "Warm",
                style: "Clear",
                isBuiltIn: true,
                isCustomized: false
            ),
            PersonalityDefinition(
                name: "concise",
                description: "Brief and direct",
                systemPrompt: "Keep responses brief and to the point.",
                tone: "Direct",
                style: "Concise",
                isBuiltIn: true,
                isCustomized: false
            ),
        ]
    )

    func load() async throws -> PersonalityCatalog { catalog }

    func mutate(_ request: PersonalityMutation) async throws -> PersonalityCatalog {
        var values = catalog.personalities
        var activeName = catalog.activeName
        switch request.action {
        case .save:
            guard let draft = request.draft else { throw BighelpLinkWireError.invalidValue }
            values.removeAll { $0.name == draft.originalName || $0.name == draft.name }
            values.append(
                PersonalityDefinition(
                    name: draft.name,
                    description: draft.description,
                    systemPrompt: draft.systemPrompt,
                    tone: draft.tone,
                    style: draft.style,
                    isBuiltIn: false,
                    isCustomized: true
                )
            )
        case .delete:
            values.removeAll { $0.name == request.name && !$0.isBuiltIn }
            if activeName == request.name { activeName = "" }
        case .activate:
            activeName = request.name ?? ""
        }
        catalog = PersonalityCatalog(
            revision: catalog.revision + 1,
            activeName: activeName,
            personalities: values
        )
        return catalog
    }
}
