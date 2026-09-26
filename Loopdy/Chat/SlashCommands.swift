import Foundation
import Observation

enum SlashCommandArgumentMode: String, Codable, Equatable, Sendable {
    case none
    case text
    case options
    case mixed
}

enum SlashCommandSource: String, Codable, Equatable, Sendable {
    case core
    case plugin
    case skill
    case user
}

struct SlashCommandDescriptor: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }

    let name: String
    let description: String
    let category: String
    let argsHint: String
    let aliases: [String]
    let argumentMode: SlashCommandArgumentMode
    let source: SlashCommandSource
    let requiresArguments: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case description
        case category
        case argsHint
        case aliases
        case argumentMode
        case source
        case requiresArguments
    }

    init(
        name: String,
        description: String,
        category: String,
        argsHint: String,
        aliases: [String],
        argumentMode: SlashCommandArgumentMode,
        source: SlashCommandSource,
        requiresArguments: Bool
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.argsHint = argsHint
        self.aliases = aliases
        self.argumentMode = argumentMode
        self.source = source
        self.requiresArguments = requiresArguments
    }

    init(from decoder: any Decoder) throws {
        let keys = try LoopdyLinkPickerValidation.keys(from: decoder)
        guard keys == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw LoopdyLinkWireError.invalidValue
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        category = try container.decode(String.self, forKey: .category)
        argsHint = try container.decode(String.self, forKey: .argsHint)
        aliases = try container.decode([String].self, forKey: .aliases)
        argumentMode = try container.decode(SlashCommandArgumentMode.self, forKey: .argumentMode)
        source = try container.decode(SlashCommandSource.self, forKey: .source)
        requiresArguments = try container.decode(Bool.self, forKey: .requiresArguments)
        guard
            Self.isCommandName(name),
            (1...240).contains(description.count),
            !description.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            LoopdyLinkPickerValidation.label(category, maximum: 80) != nil,
            argsHint.count <= 240,
            !argsHint.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            aliases.count <= 32,
            Set(aliases).count == aliases.count,
            aliases.allSatisfy(Self.isCommandName),
            !aliases.contains(name)
        else { throw LoopdyLinkWireError.invalidValue }
    }

    private static func isCommandName(_ value: String) -> Bool {
        (1...96).contains(value.count) && value.allSatisfy {
            $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }
}

struct SlashCommandSelection: Equatable, Sendable {
    let command: SlashCommandDescriptor
    let invocation: String
    let arguments: String
}

struct SlashCommandIndex: Equatable, Sendable {
    let commands: [SlashCommandDescriptor]

    init(commands: [SlashCommandDescriptor]) {
        var seen = Set<String>()
        self.commands = commands.filter { command in
            seen.insert(command.name).inserted
        }
    }

    func suggestions(for draft: String) -> [SlashCommandDescriptor] {
        guard draft.hasPrefix("/"), !draft.dropFirst().contains(where: \Character.isWhitespace) else {
            return []
        }
        let query = String(draft.dropFirst()).lowercased()
        guard selection(for: draft) == nil else { return [] }
        guard !query.isEmpty else { return commands }
        return commands.filter { command in
            command.name.localizedCaseInsensitiveContains(query)
                || command.aliases.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                || command.description.localizedCaseInsensitiveContains(query)
        }
    }

    func selection(for draft: String) -> SlashCommandSelection? {
        guard draft.hasPrefix("/") else { return nil }
        let slashless = draft.dropFirst()
        let tokenEnd = slashless.firstIndex(where: \Character.isWhitespace) ?? slashless.endIndex
        let token = String(slashless[..<tokenEnd]).lowercased()
        guard !token.isEmpty,
              let command = commands.first(where: {
                  $0.name.lowercased() == token
                      || $0.aliases.contains(where: { $0.lowercased() == token })
              })
        else { return nil }
        let remainder = slashless[tokenEnd...]
            .drop(while: \Character.isWhitespace)
        return SlashCommandSelection(
            command: command,
            invocation: "/\(token)",
            arguments: String(remainder)
        )
    }

    func draft(selecting command: SlashCommandDescriptor) -> String {
        "/\(command.name) "
    }

    func replacingArguments(
        in selection: SlashCommandSelection,
        with arguments: String
    ) -> String {
        selection.invocation + " " + arguments
    }
}

@MainActor
protocol SlashCommandCatalogClient: AnyObject {
    func catalog(sessionID: String, agentID: String) async throws -> [SlashCommandDescriptor]
}

/// Adapts Hermes' official `commands.catalog` response to the native composer
/// model. The gateway returns skill invocations in `pairs` and identifies them
/// in `skills`; keeping that key intact preserves Hermes' invocation IDs.
@MainActor
final class DirectHermesSlashCommandCatalogClient: SlashCommandCatalogClient {
    private let scope: DirectHermesCoreRequestScope

    init(
        workspace: any WorkspaceOperationPerforming,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        scope = DirectHermesCoreRequestScope(
            workspace: workspace,
            owner: owner,
            currentOwner: currentOwner
        )
    }

    func catalog(sessionID: String, agentID: String) async throws -> [SlashCommandDescriptor] {
        let profile = try DirectHermesCoreRequestScope.profile(agentID)
        let session = try DirectHermesCoreRequestScope.identifier(sessionID, maximum: 512)
        let response = try await scope.perform(.commandsCatalog, [
            "session_id": .string(session),
            "profile": .string(profile),
        ])
        return try Self.decode(response)
    }

    private static func decode(_ response: [String: LoopdyJSONValue]) throws -> [SlashCommandDescriptor] {
        guard let pairs = response["pairs"]?.array, pairs.count <= 2_048 else {
            throw WorkspaceClientError.invalidResponse
        }
        let categories = categoryByKey(response["categories"]?.array)
        let canonical = response["canon"]?.object ?? [:]
        let metadata = response["commands"]?.object ?? [:]
        let skills = response["skills"]?.object ?? [:]

        return try pairs.map { pair in
            guard let values = pair.array, values.count == 2,
                  let rawKey = values[0].string,
                  let description = values[1].string else {
                throw WorkspaceClientError.invalidResponse
            }
            let name = try commandName(rawKey)
            guard (1...240).contains(description.count),
                  !description.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw WorkspaceClientError.invalidResponse
            }

            let isSkill = containsKey(skills, rawKey)
            let source: SlashCommandSource
            if isSkill {
                source = .skill
            } else {
                switch categories[rawKey.lowercased()]?.lowercased() {
                case "plugin commands": source = .plugin
                case "user commands": source = .user
                default: source = .core
                }
            }
            let category = categories[rawKey.lowercased()]
                ?? (source == .skill ? "Skills" : "Commands")
            let aliases = try aliases(for: rawKey, canonical: canonical)
            let argumentMode = metadataValue(metadata, for: rawKey)?["argument_mode"]?.string
                .flatMap(SlashCommandArgumentMode.init(rawValue:)) ?? .none

            return SlashCommandDescriptor(
                name: name,
                description: description,
                category: category,
                argsHint: "",
                aliases: aliases,
                argumentMode: argumentMode,
                source: source,
                requiresArguments: false
            )
        }
    }

    private static func commandName(_ rawKey: String) throws -> String {
        guard rawKey.first == "/" else { throw WorkspaceClientError.invalidResponse }
        let name = String(rawKey.dropFirst())
        guard (1...96).contains(name.utf8.count), name.unicodeScalars.allSatisfy({ scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-" || scalar == "_" || scalar == "."
        }) else {
            throw WorkspaceClientError.invalidResponse
        }
        return name
    }

    private static func aliases(
        for rawKey: String,
        canonical: [String: LoopdyJSONValue]
    ) throws -> [String] {
        var result: [String] = []
        for (aliasKey, value) in canonical {
            guard aliasKey.lowercased() != rawKey.lowercased(),
                  value.string?.lowercased() == rawKey.lowercased() else { continue }
            let alias = try commandName(aliasKey)
            guard !result.contains(alias) else { continue }
            result.append(alias)
            guard result.count <= 32 else { throw WorkspaceClientError.invalidResponse }
        }
        return result.sorted()
    }

    private static func containsKey(_ object: [String: LoopdyJSONValue], _ key: String) -> Bool {
        object.keys.contains { candidate in
            candidate.lowercased() == key.lowercased()
                || candidate.lowercased() == String(key.dropFirst()).lowercased()
        }
    }

    private static func metadataValue(
        _ object: [String: LoopdyJSONValue],
        for key: String
    ) -> [String: LoopdyJSONValue]? {
        object.first(where: { entry in
            entry.key.lowercased() == key.lowercased()
                || entry.key.lowercased() == String(key.dropFirst()).lowercased()
        })?.value.object
    }

    private static func categoryByKey(_ values: [LoopdyJSONValue]?) -> [String: String] {
        guard let values else { return [:] }
        var result: [String: String] = [:]
        for value in values {
            guard let category = value.object?["name"]?.string,
                  (1...80).contains(category.count),
                  !category.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let pairs = value.object?["pairs"]?.array else { continue }
            for pair in pairs {
                guard let fields = pair.array, fields.count == 2,
                      let key = fields[0].string, key.first == "/" else { continue }
                result[key.lowercased()] = category
            }
        }
        return result
    }
}

/// Keeps the catalog model stable while the direct host connection changes.
/// `WorkspaceOwnedClientBox` fences each catalog request to its captured owner.
@MainActor
final class WorkspaceSlashCommandCatalogProxy: SlashCommandCatalogClient {
    let box: WorkspaceOwnedClientBox<any SlashCommandCatalogClient>

    init(box: WorkspaceOwnedClientBox<any SlashCommandCatalogClient>) {
        self.box = box
    }

    func catalog(sessionID: String, agentID: String) async throws -> [SlashCommandDescriptor] {
        try await box.value().catalog(sessionID: sessionID, agentID: agentID)
    }
}

@MainActor
@Observable
final class SlashCommandCatalogModel {
    private(set) var commands: [SlashCommandDescriptor] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let sessionID: String
    private let agentID: String
    private let client: any SlashCommandCatalogClient
    private var hasLoaded = false

    init(
        sessionID: String,
        agentID: String,
        client: any SlashCommandCatalogClient
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.client = client
    }

    var index: SlashCommandIndex { SlashCommandIndex(commands: commands) }

    func loadIfNeeded(for draft: String) async {
        guard draft.hasPrefix("/"), !hasLoaded, !isLoading else { return }
        await load()
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            commands = try await catalogWithTransientDisconnectRecovery()
            hasLoaded = true
            errorMessage = nil
        } catch is CancellationError {
            // Draft changes cancel the previous view task. Keep the catalog
            // retryable and avoid showing a failure for expected cancellation.
        } catch {
            errorMessage = "Commands could not be loaded from Hermes."
        }
    }

    func retry() async {
        await load()
    }

    private func catalogWithTransientDisconnectRecovery() async throws -> [SlashCommandDescriptor] {
        // The Link socket can be between its authenticated-ready states when
        // the user first types `/`. Give the durable socket loop a few bounded
        // opportunities to recover before exposing the retry UI. A timeout is
        // treated the same as a disconnect because it means the request did
        // not receive a usable Hermes response, not that the command itself
        // was invalid.
        var attempt = 0
        while true {
            do {
                return try await client.catalog(sessionID: sessionID, agentID: agentID)
            } catch let error as LoopdyLinkLiveSocketError
                where Self.isRecoverable(error) && attempt < 2 {
                attempt += 1
                try Task.checkCancellation()
            } catch {
                throw error
            }
        }
    }

    private static func isRecoverable(_ error: LoopdyLinkLiveSocketError) -> Bool {
        switch error {
        case .disconnected, .timedOut:
            true
        default:
            false
        }
    }
}

@MainActor
final class FixtureSlashCommandCatalogClient: SlashCommandCatalogClient {
    func catalog(sessionID: String, agentID: String) async throws -> [SlashCommandDescriptor] {
        [
            SlashCommandDescriptor(
                name: "help",
                description: "Show available commands",
                category: "Help",
                argsHint: "[query]",
                aliases: ["commands"],
                argumentMode: .text,
                source: .core,
                requiresArguments: false
            ),
            SlashCommandDescriptor(
                name: "model",
                description: "Show or change the model",
                category: "Configuration",
                argsHint: "[name]",
                aliases: [],
                argumentMode: .options,
                source: .core,
                requiresArguments: false
            ),
            SlashCommandDescriptor(
                name: "reasoning",
                description: "Show or change reasoning effort",
                category: "Configuration",
                argsHint: "[level]",
                aliases: [],
                argumentMode: .options,
                source: .core,
                requiresArguments: false
            ),
        ]
    }
}
