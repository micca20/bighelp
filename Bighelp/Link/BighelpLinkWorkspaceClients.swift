import Foundation

// Injected compatibility requests only. No production socket is composed.
@MainActor
final class BighelpLinkWorkspaceClient {
    private let messaging: any BighelpLinkWorkspaceMessaging
    private let requestID: () -> String
    private let now: () -> Date

    init(
        messaging: any BighelpLinkWorkspaceMessaging,
        requestID: @escaping () -> String = { "workspace_\(UUID().uuidString)" },
        now: @escaping () -> Date = Date.init
    ) {
        self.messaging = messaging
        self.requestID = requestID
        self.now = now
    }

    var ownerIdentity: String { messaging.workspaceOwnerIdentity }
    func supportsSessionState() async throws -> Bool { try await messaging.prepareSessionStateSupport() }

    func perform(
        _ operation: BighelpLinkWorkspaceOperation,
        payload: [String: BighelpJSONValue]
    ) async throws -> [String: BighelpJSONValue] {
        let request = try BighelpLinkWorkspaceRequest(
            requestID: requestID(),
            operation: operation,
            payload: payload,
            sentAt: Int(now().timeIntervalSince1970)
        )
        let result = try await messaging.performPreparedWorkspaceRequest(request)
        guard
            result.requestID == request.requestID,
            result.operation == operation
        else { throw BighelpLinkWorkspaceClientError.invalidResponse }
        guard result.status == .completed else {
            throw BighelpLinkWorkspaceClientError.remote(
                status: result.status,
                code: result.code,
                message: result.message
            )
        }
        return result.payload
    }
}

@MainActor
final class BighelpLinkHermesWorkspaceClient: HermesWorkspaceCatalogClient {
    private let workspace: BighelpLinkWorkspaceClient

    init(messaging: any BighelpLinkWorkspaceMessaging) {
        workspace = BighelpLinkWorkspaceClient(messaging: messaging)
    }

    init(workspace: BighelpLinkWorkspaceClient) {
        self.workspace = workspace
    }

    func load(agentID: String) async throws -> HermesWorkspaceCatalog {
        try await load(agentID: agentID, sessionID: nil)
    }

    func load(agentID: String, sessionID: String?) async throws -> HermesWorkspaceCatalog {
        let agentID = try Self.text(agentID, maximum: 64, allowsEmpty: false)
        var payload: [String: BighelpJSONValue] = [
            "agentId": .string(agentID),
        ]
        if let sessionID {
            payload["sessionId"] = .string(
                try Self.text(sessionID, maximum: 128, allowsEmpty: false)
            )
        }
        return try Self.catalog(
            await workspace.perform(.projectsList, payload: payload),
            expectsSessionWorkspace: sessionID != nil
        )
    }

    func select(
        id: String,
        agentID: String,
        sessionID: String?
    ) async throws -> HermesWorkspaceCatalog {
        let id = try Self.text(id, maximum: 160, allowsEmpty: false)
        let agentID = try Self.text(agentID, maximum: 64, allowsEmpty: false)
        var payload: [String: BighelpJSONValue] = [
            "agentId": .string(agentID),
            "workspaceId": .string(id),
        ]
        if let sessionID {
            payload["sessionId"] = .string(
                try Self.text(sessionID, maximum: 128, allowsEmpty: false)
            )
        }
        return try Self.catalog(await workspace.perform(
            .projectsSetActive,
            payload: payload
        ))
    }

    func create(
        name: String,
        folderPath: String,
        agentID: String
    ) async throws -> HermesWorkspaceCatalog {
        let name = try Self.text(name, maximum: 160, allowsEmpty: false)
        let folderPath = try Self.text(folderPath, maximum: 4_096, allowsEmpty: false)
        let agentID = try Self.text(agentID, maximum: 64, allowsEmpty: false)
        return try Self.catalog(await workspace.perform(.projectsCreate, payload: [
            "agentId": .string(agentID),
            "name": .string(name),
            "folderPath": .string(folderPath),
        ]))
    }

    func archive(id: String, agentID: String) async throws -> HermesWorkspaceCatalog {
        let id = try Self.text(id, maximum: 160, allowsEmpty: false)
        let agentID = try Self.text(agentID, maximum: 64, allowsEmpty: false)
        return try Self.catalog(await workspace.perform(.projectsArchive, payload: [
            "agentId": .string(agentID),
            "workspaceId": .string(id),
        ]))
    }

    func folderSuggestions(
        parentPath: String,
        prefix: String,
        offset: Int,
        limit: Int,
        agentID: String
    ) async throws -> HermesWorkspaceFolderPage {
        let parentPath = try Self.text(parentPath, maximum: 4_096, allowsEmpty: false)
        let prefix = try Self.text(prefix, maximum: 255, allowsEmpty: true)
        let agentID = try Self.text(agentID, maximum: 64, allowsEmpty: false)
        guard (0...100_000).contains(offset), (1...100).contains(limit) else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        let payload = try await workspace.perform(.projectsListDirectory, payload: [
            "agentId": .string(agentID),
            "parentPath": .string(parentPath),
            "prefix": .string(prefix),
            "offset": .integer(offset),
            "limit": .integer(limit),
        ])
        return try Self.folderPage(payload, offset: offset, limit: limit)
    }

    private static func catalog(
        _ payload: [String: BighelpJSONValue],
        expectsSessionWorkspace: Bool = false
    ) throws -> HermesWorkspaceCatalog {
        let activeID: String?
        switch payload["activeWorkspaceId"] {
        case .string(let value):
            activeID = try text(value, maximum: 160, allowsEmpty: false)
        case .null:
            activeID = nil
        default:
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        let sessionWorkspaceID: String?
        switch payload["sessionWorkspaceId"] {
        case .string(let value):
            sessionWorkspaceID = try text(value, maximum: 160, allowsEmpty: false)
        case .null:
            sessionWorkspaceID = nil
        case nil where !expectsSessionWorkspace:
            sessionWorkspaceID = nil
        default:
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        guard let rows = payload["workspaces"]?.array, rows.count <= 256 else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        var seenIDs = Set<String>()
        let workspaces = try rows.map { value -> HermesWorkspaceSummary in
            guard
                let source = value.object,
                let rawID = source["id"]?.string,
                let rawName = source["name"]?.string,
                let rawDescription = source["description"]?.string,
                let folderCount = source["folderCount"]?.integer,
                (0...10_000).contains(folderCount),
                let isActive = source["isActive"]?.boolean
            else { throw BighelpLinkWorkspaceClientError.invalidResponse }
            let id = try text(rawID, maximum: 160, allowsEmpty: false)
            guard seenIDs.insert(id).inserted else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
            return HermesWorkspaceSummary(
                id: id,
                name: try text(rawName, maximum: 160, allowsEmpty: false),
                description: try text(rawDescription, maximum: 4_096, allowsEmpty: true),
                folderCount: folderCount,
                isActive: isActive
            )
        }
        guard
            workspaces.filter(\.isActive).count <= 1,
            workspaces.first(where: \.isActive)?.id == activeID
        else { throw BighelpLinkWorkspaceClientError.invalidResponse }
        guard sessionWorkspaceID == nil
                || workspaces.contains(where: { $0.id == sessionWorkspaceID })
        else { throw BighelpLinkWorkspaceClientError.invalidResponse }
        return HermesWorkspaceCatalog(
            activeWorkspaceID: activeID,
            sessionWorkspaceID: sessionWorkspaceID,
            workspaces: workspaces
        )
    }

    private static func folderPage(
        _ payload: [String: BighelpJSONValue],
        offset: Int,
        limit: Int
    ) throws -> HermesWorkspaceFolderPage {
        guard
            let rawParentPath = payload["parentPath"]?.string,
            let rows = payload["folders"]?.array,
            rows.count <= limit
        else { throw BighelpLinkWorkspaceClientError.invalidResponse }
        let parentPath = try text(rawParentPath, maximum: 4_096, allowsEmpty: false)
        var seenPaths = Set<String>()
        let folders = try rows.map { value -> HermesWorkspaceFolderSuggestion in
            guard
                let source = value.object,
                Set(source.keys) == Set(["name", "path"]),
                let rawName = source["name"]?.string,
                let rawPath = source["path"]?.string
            else { throw BighelpLinkWorkspaceClientError.invalidResponse }
            let name = try text(rawName, maximum: 255, allowsEmpty: false)
            let path = try text(rawPath, maximum: 4_096, allowsEmpty: false)
            guard seenPaths.insert(path).inserted else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
            return HermesWorkspaceFolderSuggestion(name: name, path: path)
        }
        let nextOffset: Int?
        switch payload["nextOffset"] {
        case .integer(let value)
            where value > offset && value <= 100_000 && value == offset + folders.count:
            nextOffset = value
        case .null:
            nextOffset = nil
        default:
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        return HermesWorkspaceFolderPage(
            parentPath: parentPath,
            folders: folders,
            nextOffset: nextOffset
        )
    }

    private static func text(
        _ value: String,
        maximum: Int,
        allowsEmpty: Bool
    ) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            normalized == value,
            (allowsEmpty || !value.isEmpty),
            value.utf8.count <= maximum,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw BighelpLinkWorkspaceClientError.invalidResponse }
        return value
    }
}
